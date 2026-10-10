#import <Foundation/Foundation.h>

@interface DesktopKeychain : NSObject
+ (NSString * _Nullable)readForService:(NSString * _Nonnull)service account:(NSString * _Nonnull)account error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)write:(NSString * _Nonnull)value service:(NSString * _Nonnull)service account:(NSString * _Nonnull)account error:(NSError * _Nullable * _Nullable)error;
@end
