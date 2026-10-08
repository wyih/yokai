#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface JavaBridge : NSObject
+ (void)execute:(NSString *)request completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
