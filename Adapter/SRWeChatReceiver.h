#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/* Read-only, manually armed candidate. No send API and no guessed image path. */
@interface SRWeChatReceiver : NSObject
@property(nonatomic, copy, nullable) void (^trace)(NSString *event, NSDictionary *facts);
/* Main-thread preparation: nil/no error means not ready; error stops this candidate.
 * Payload must be an owned, validated snapshot. Never return host paths or XML. */
@property(nonatomic, copy, nullable) NSDictionary * _Nullable (^prepareImage)(id wrap, NSDictionary *source, NSError **error);
@property(nonatomic, copy, nullable) void (^discardImage)(NSDictionary *payload);
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class _Nullable (^)(NSString *))resolver
                currentAccount:(NSString * _Nullable (^)(void))currentAccount
                      received:(void (^)(NSDictionary *))received;
/* Main thread only. One listener per hook class. Re-arming requires stop first. */
- (BOOL)armForAccount:(NSString *)account sourceGroup:(NSString *)group error:(NSError **)error;
- (BOOL)armForAccount:(NSString *)account configuration:(NSDictionary *)configuration error:(NSError **)error;
- (void)stop;
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
