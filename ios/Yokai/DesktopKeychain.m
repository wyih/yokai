#include <TargetConditionals.h>
#if TARGET_OS_MACCATALYST
#import "DesktopKeychain.h"
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>

static NSDictionary *call(NSDictionary *request, NSError **error) {
    NSData *input = [NSJSONSerialization dataWithJSONObject:request options:0 error:error];
    if (!input) return nil;
    int incoming[2], outgoing[2];
    if (pipe(incoming) != 0) return nil;
    if (pipe(outgoing) != 0) { close(incoming[0]); close(incoming[1]); return nil; }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, incoming[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outgoing[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    for (int i = 0; i < 2; i++) {
        posix_spawn_file_actions_addclose(&actions, incoming[i]);
        posix_spawn_file_actions_addclose(&actions, outgoing[i]);
    }
    NSString *path = [NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"YokaiKeychain"];
    char *arguments[] = {(char *)path.fileSystemRepresentation, NULL};
    char *environment[] = {"PATH=/usr/bin:/bin", NULL};
    // Concurrent plugin requests must not inherit each other's credential pipes.
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    pid_t child;
    int status = posix_spawn(&child, path.fileSystemRepresentation, &actions, &attributes, arguments, environment);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(incoming[0]); close(outgoing[1]);
    if (status != 0) {
        close(incoming[1]); close(outgoing[0]);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey: @"无法启动系统钥匙串组件。"}];
        return nil;
    }
    NSFileHandle *writer = [[NSFileHandle alloc] initWithFileDescriptor:incoming[1] closeOnDealloc:YES];
    NSFileHandle *reader = [[NSFileHandle alloc] initWithFileDescriptor:outgoing[0] closeOnDealloc:YES];
    BOOL sent = [writer writeData:input error:error];
    [writer closeFile];
    NSData *output = [reader readDataToEndOfFileAndReturnError:error];
    [reader closeFile];
    int exitStatus;
    while (waitpid(child, &exitStatus, 0) < 0 && errno == EINTR) {}
    if (!sent || !output) return nil;
    NSDictionary *response = [NSJSONSerialization JSONObjectWithData:output options:0 error:error];
    if (![response isKindOfClass:NSDictionary.class] || ![response[@"value"] isKindOfClass:NSString.class]) {
        if (error) *error = [NSError errorWithDomain:@"YokaiKeychain" code:1 userInfo:@{NSLocalizedDescriptionKey:
            [response[@"error"] isKindOfClass:NSString.class] ? response[@"error"] : @"系统钥匙串组件未返回有效数据。"}];
        return nil;
    }
    return response;
}

@implementation DesktopKeychain
+ (NSString *)readForService:(NSString *)service account:(NSString *)account error:(NSError **)error {
    return call(@{@"operation": @"read", @"service": service, @"account": account}, error)[@"value"];
}
+ (BOOL)write:(NSString *)value service:(NSString *)service account:(NSString *)account error:(NSError **)error {
    return call(@{@"operation": @"write", @"service": service, @"account": account, @"value": value}, error) != nil;
}
@end
#endif
