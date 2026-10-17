#import "JavaBridge.h"
#import <Security/Security.h>
#include <TargetConditionals.h>
#if TARGET_OS_MACCATALYST
#include <dlfcn.h>
#import "DesktopKeychain.h"
#endif
#include "jni.h"
#if !TARGET_OS_MACCATALYST
#include <signal.h>

static void restoreNonfatalSignalHandler(int signalNumber, struct sigaction previous) {
    // The pinned iOS Zero VM calls an unimplemented ucontext_get_pc before
    // ignoring SIGPIPE/SIGXFSZ. Preserve native handlers without entering it.
    if (previous.sa_handler == SIG_DFL) {
        previous.sa_handler = SIG_IGN;
        previous.sa_flags = 0;
        sigemptyset(&previous.sa_mask);
    }
    sigaction(signalNumber, &previous, NULL);
}
#endif

static JavaVM *runtime;
static jclass engineClass;
static jmethodID executeMethod;

static NSString *nativeString(JNIEnv *env, jstring value) {
    if (!value) return nil;
    const jchar *chars = (*env)->GetStringChars(env, value, NULL);
    NSString *result = [[NSString alloc] initWithCharacters:chars length:(NSUInteger)(*env)->GetStringLength(env, value)];
    (*env)->ReleaseStringChars(env, value, chars);
    return result;
}
static jstring javaString(JNIEnv *env, NSString *value) {
    NSUInteger length = value.length;
    unichar *chars = malloc(MAX(length, 1) * sizeof(unichar));
    [value getCharacters:chars range:NSMakeRange(0, length)];
    jstring result = (*env)->NewString(env, chars, (jsize)length);
    free(chars);
    return result;
}
static void throwIO(JNIEnv *env, NSString *message) {
    jclass cls = (*env)->FindClass(env, "java/io/IOException");
    (*env)->ThrowNew(env, cls, message.UTF8String);
}
static NSDictionary *preferenceQuery(NSString *name) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: @"com.wyih.yokai.extension-preferences",
             (__bridge id)kSecAttrAccount: name};
}
static jstring readPreferences(JNIEnv *env, jclass cls, jstring name) {
    #if TARGET_OS_MACCATALYST
    NSError *error;
    NSString *value = [DesktopKeychain readForService:@"com.wyih.yokai.extension-preferences" account:nativeString(env, name) error:&error];
    if (!value) { throwIO(env, error.localizedDescription ?: @"无法读取漫画源设置。"); return NULL; }
    return javaString(env, value.length ? value : @"{}");
    #else
    NSMutableDictionary *query = [preferenceQuery(nativeString(env, name)) mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) return javaString(env, @"{}");
    if (status != errSecSuccess) { throwIO(env, [NSString stringWithFormat:@"无法读取漫画源设置（Keychain %d）。", (int)status]); return NULL; }
    NSData *data = CFBridgingRelease(result);
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!value) { throwIO(env, @"漫画源设置数据损坏。"); return NULL; }
    return javaString(env, value);
    #endif
}
static void writePreferences(JNIEnv *env, jclass cls, jstring name, jstring json) {
    #if TARGET_OS_MACCATALYST
    NSError *error;
    if (![DesktopKeychain write:nativeString(env, json) service:@"com.wyih.yokai.extension-preferences" account:nativeString(env, name) error:&error]) {
        throwIO(env, error.localizedDescription ?: @"无法保存漫画源设置。");
    }
    #else
    NSDictionary *query = preferenceQuery(nativeString(env, name));
    NSData *value = [nativeString(env, json) dataUsingEncoding:NSUTF8StringEncoding];
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                   (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: value});
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = [query mutableCopy];
        item[(__bridge id)kSecValueData] = value;
        item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    if (status != errSecSuccess) throwIO(env, [NSString stringWithFormat:@"无法保存漫画源设置（Keychain %d）。", (int)status]);
    #endif
}
static void openWebView(JNIEnv *env, jclass cls, jstring address, jstring source) {
    NSString *url = nativeString(env, address);
    NSURL *parsed = [NSURL URLWithString:url ?: @""];
    if (!parsed.host || ![@[@"https", @"http"] containsObject:parsed.scheme.lowercaseString]) {
        throwIO(env, @"漫画源提供了无效的登录网址。"); return;
    }
    NSDictionary *info = @{@"url": url, @"source": nativeString(env, source) ?: @""};
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"YokaiSourceWebView" object:info];
    });
}
static NSError *javaError(JNIEnv *env) {
    jthrowable exception = (*env)->ExceptionOccurred(env);
    if (!exception) return nil;
    (*env)->ExceptionClear(env);
    jclass throwable = (*env)->FindClass(env, "java/lang/Throwable");
    jmethodID toString = (*env)->GetMethodID(env, throwable, "toString", "()Ljava/lang/String;");
    jstring description = (*env)->CallObjectMethod(env, exception, toString);
    NSString *message = nativeString(env, description) ?: @"漫画插件执行失败。";
    (*env)->ExceptionClear(env);
    return [NSError errorWithDomain:@"YokaiJava" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation JavaBridge
+ (void)execute:(NSString *)request completion:(void (^)(NSString *, NSError *))completion {
    static dispatch_queue_t queue;
    static dispatch_semaphore_t slots;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.wyih.yokai.java", DISPATCH_QUEUE_CONCURRENT);
        slots = dispatch_semaphore_create(10);
    });
    dispatch_async(queue, ^{
        dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
        @autoreleasepool {
            JNIEnv *env = NULL;
            NSError *failure = nil;
            @synchronized([JavaBridge class]) {
                if (!runtime) {
                    NSString *bundle = NSBundle.mainBundle.resourcePath;
#if TARGET_OS_MACCATALYST
                    NSString *javaHome = [bundle stringByAppendingPathComponent:@"JavaRuntime"];
                    static void *jvmLibrary;
                    jvmLibrary = dlopen([[javaHome stringByAppendingPathComponent:@"lib/server/libjvm.dylib"] fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
                    jint (*createVM)(JavaVM **, void **, void *) = jvmLibrary ? dlsym(jvmLibrary, "JNI_CreateJavaVM") : NULL;
                    if (!createVM) {
                        const char *detail = dlerror();
                        failure = [NSError errorWithDomain:@"YokaiJava" code:1 userInfo:@{NSLocalizedDescriptionKey:
                            [@"无法加载桌面漫画运行时：" stringByAppendingString:detail ? @(detail) : @"JNI_CreateJavaVM 不存在"]}];
                    }
#else
                    NSString *javaHome = [bundle stringByAppendingPathComponent:@"lib"];
#endif
                    NSArray<NSString *> *settings = @[
                        [NSString stringWithFormat:@"-Djava.class.path=%@/Engine.jar:%@/compat.jar", bundle, bundle],
                        [@"-Djava.home=" stringByAppendingString:javaHome],
                        [@"-Duser.home=" stringByAppendingString:NSHomeDirectory()],
                        @"-Dfile.encoding=UTF-8", @"-Xint", @"-Xmx256m"
                    ];
                    JavaVMOption options[6];
                    for (int i = 0; i < 6; i++) options[i].optionString = strdup(settings[i].UTF8String);
                    JavaVMInitArgs args = {0};
                    args.version = JNI_VERSION_1_8; args.nOptions = 6; args.options = options;
#if TARGET_OS_MACCATALYST
                    int result = createVM ? createVM(&runtime, (void **)&env, &args) : JNI_ERR;
#else
                    struct sigaction previousPipe = {0}, previousFileSize = {0};
                    sigaction(SIGPIPE, NULL, &previousPipe);
                    sigaction(SIGXFSZ, NULL, &previousFileSize);
                    int result = JNI_CreateJavaVM(&runtime, (void **)&env, &args);
                    restoreNonfatalSignalHandler(SIGPIPE, previousPipe);
                    restoreNonfatalSignalHandler(SIGXFSZ, previousFileSize);
#endif
                    for (int i = 0; i < 6; i++) free(options[i].optionString);
                    if (result != JNI_OK) {
                        runtime = NULL;
                        failure = failure ?: [NSError errorWithDomain:@"YokaiJava" code:result userInfo:@{NSLocalizedDescriptionKey: @"无法启动漫画插件运行时。"}];
                    } else {
                        jclass services = (*env)->FindClass(env, "yokai/NativeServices");
                        JNINativeMethod methods[] = {
                            {"readPreferences", "(Ljava/lang/String;)Ljava/lang/String;", readPreferences},
                            {"writePreferences", "(Ljava/lang/String;Ljava/lang/String;)V", writePreferences},
                            {"openWebView", "(Ljava/lang/String;Ljava/lang/String;)V", openWebView}
                        };
                        if (services) (*env)->RegisterNatives(env, services, methods, 3);
                        failure = javaError(env);
                        if (!failure) {
                            jclass cls = (*env)->FindClass(env, "yokai/Engine");
                            if (cls) engineClass = (*env)->NewGlobalRef(env, cls);
                            failure = javaError(env);
                            if (!failure) executeMethod = (*env)->GetStaticMethodID(env, engineClass, "execute", "(Ljava/lang/String;)Ljava/lang/String;");
                            failure = failure ?: javaError(env);
                        }
                    }
                } else {
                    if ((*runtime)->AttachCurrentThread(runtime, (void **)&env, NULL) != JNI_OK)
                        failure = [NSError errorWithDomain:@"YokaiJava" code:2 userInfo:@{NSLocalizedDescriptionKey: @"无法连接漫画插件运行时。"}];
                }
            }
            NSString *output = nil;
            if (!failure && env && engineClass && executeMethod) {
                (*env)->PushLocalFrame(env, 32);
                jstring input = javaString(env, request);
                jstring result = (*env)->CallStaticObjectMethod(env, engineClass, executeMethod, input);
                failure = javaError(env);
                if (!failure) output = nativeString(env, result);
                (*env)->PopLocalFrame(env, NULL);
            }
            if (env && runtime) (*runtime)->DetachCurrentThread(runtime);
            dispatch_semaphore_signal(slots);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(output, failure); });
        }
    });
}
@end
