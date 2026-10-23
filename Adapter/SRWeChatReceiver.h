#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/* Read-only, manually armed candidate. No send API and no guessed image path.
 * Diagnostics also expose a bounded numeric message-type probe and callback
 * sequence. Unknown codes are observed only; they are never normalized into a
 * relayable payload. Selected type-49 callbacks may additionally produce a
 * bounded, redacted appmsg structural summary; never an XML/media payload. */
@interface SRWeChatReceiver : NSObject
@property(nonatomic, copy, nullable) void (^trace)(NSString *event, NSDictionary *facts);
/* Main-thread preparation: nil/no error means not ready; error stops this candidate.
 * Payload must be an owned, validated snapshot. Never return host paths or XML. */
@property(nonatomic, copy, nullable) NSDictionary * _Nullable (^prepareImage)(id wrap, NSDictionary *source, NSError **error);
@property(nonatomic, copy, nullable) void (^discardImage)(NSDictionary *payload);
/* If set, replaces the legacy received callback. Evidence carries the original
 * hook time and generation through local-ID/image waits, never preparation time.
 * Getter availability is not proof of real-host timestamp semantics. */
@property(nonatomic, copy, nullable) void (^receivedWithTimeEvidence)(NSDictionary *message, NSDictionary *evidence);
/* Opt-in supplemental hook metadata, before ID/content/type readiness filters.
 * Main-thread delivery, at most 16 reservations per arm; no media reads.
 * Set only after an explicit probe start, clear before stopping. */
@property(nonatomic, copy, nullable) void (^observeTimeHook)(NSDictionary *observation);
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class _Nullable (^)(NSString *))resolver
                currentAccount:(NSString * _Nullable (^)(void))currentAccount
                      received:(void (^)(NSDictionary *))received;
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class _Nullable (^)(NSString *))resolver
                currentAccount:(NSString * _Nullable (^)(void))currentAccount
                      received:(void (^)(NSDictionary *))received clock:(NSTimeInterval (^)(void))clock;
/* Main thread only. One listener per hook class. Re-arming requires stop first. */
- (BOOL)armForAccount:(NSString *)account sourceGroup:(NSString *)group error:(NSError **)error;
- (BOOL)armForAccount:(NSString *)account configuration:(NSDictionary *)configuration error:(NSError **)error;
/* Opt-in strict adapter seam for operations tests/future bridge. Existing manual
 * capture remains unchanged. Requires declared epoch-second getter and callback. */
- (BOOL)armForAccount:(NSString *)account configuration:(NSDictionary *)configuration
     newMessagesOnly:(BOOL)newMessagesOnly error:(NSError **)error;
- (void)stop;
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
