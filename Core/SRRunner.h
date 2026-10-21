#import <Foundation/Foundation.h>
@class SRStore;
NS_ASSUME_NONNULL_BEGIN
typedef void (^SRSendCompletion)(NSString *state, NSString * _Nullable messageID, NSString * _Nullable reason);
@protocol SRSendTransport <NSObject>
/* Must verify both adapter readiness and the current logged-in account. */
- (BOOL)canSendForAccount:(NSString *)account;
/* Nonblocking. "submitted" records a checked host invocation, NOT delivery.
 * "confirmed" needs a reliable receipt and correlated ID. A target-local
 * "failed" is skipped; account/service/platform problems must be "uncertain"
 * so the runner pauses. No callback means unknown, never safe to retry. */
- (void)submitDelivery:(NSDictionary *)delivery snapshot:(NSDictionary *)snapshot completion:(SRSendCompletion)completion;
@end

/* No autonomous timer. The future app lifecycle driver calls tick; constructing never sends. */
@interface SRRunner : NSObject
- (instancetype)initWithStore:(SRStore *)store transport:(id<SRSendTransport>)transport
                        clock:(double (^)(void))monotonicClock random:(double (^)(void))unitRandom
           environmentAllowed:(BOOL (^)(void))environmentAllowed;
/* Caller explicitly starts a rule in SRStore first. Resume is always a manual call. */
- (BOOL)activateRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
- (BOOL)tick;
- (BOOL)pause:(NSError **)error;
- (BOOL)end:(NSError **)error;
/* Also acts as a queue barrier for all previously delivered callbacks. */
- (NSDictionary *)status;
@end
NS_ASSUME_NONNULL_END
