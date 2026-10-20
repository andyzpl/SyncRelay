#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/* Read-only, manually armed candidate. No send API and no guessed image path. */
@interface SRWeChatReceiver : NSObject
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class _Nullable (^)(NSString *))resolver
                currentAccount:(NSString * _Nullable (^)(void))currentAccount
                      received:(void (^)(NSDictionary *))received;
/* Main thread only. One listener per hook class. Re-arming requires stop first. */
- (BOOL)armForAccount:(NSString *)account sourceGroup:(NSString *)group error:(NSError **)error;
- (void)stop;
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
