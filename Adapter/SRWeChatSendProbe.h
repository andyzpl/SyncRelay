#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/* Observes a user's normal send. Never constructs a message, calls a send API or judges delivery success. */
@interface SRWeChatSendProbe : NSObject
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class _Nullable (^)(NSString *))resolver
                currentAccount:(NSString * _Nullable (^)(void))currentAccount
                         clock:(double (^)(void))monotonicClock changed:(void (^)(void))changed;
/* One selected group, one observed outgoing text, at most 120 seconds. Main-thread controls only. */
- (BOOL)armForAccount:(NSString *)account targetGroup:(NSString *)group error:(NSError **)error;
- (void)poll;
- (void)stop;
- (void)cancelForInactivity;
/* Sanitized, bounded, in-memory report; no group/account IDs, message IDs, names, keys or body. */
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
