#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SRWeChatTextSendHostCompletion)(NSString *state, NSString * _Nullable messageID,
                                                NSString * _Nullable reason);

/*
 * Version-gated, single-target text construction and host submission candidate.
 * Shared for the process lifetime. Allows at most one host invocation per
 * launch; the caller must persist an attempt claim before submission.
 */
@interface SRWeChatTextSendHost : NSObject
- (instancetype)initWithVersion:(NSString *)version
                   classResolver:(Class _Nullable (^)(NSString *))resolver
                 currentAccount:(NSString * _Nullable (^)(void))currentAccount
            environmentAllowed:(BOOL (^)(void))environmentAllowed;

/* Main-thread only. Resolves the service and checks named/concrete ABIs without constructing or sending. */
- (BOOL)readyForAccount:(NSString *)account error:(NSError **)error;

/* Main-thread only. Completes after bounded observation or an earlier block/stop. No retry. */
- (void)submitRequest:(NSDictionary *)request completion:(SRWeChatTextSendHostCompletion _Nullable)completion;

/* Bounded exact-ID observation only. Neither method submits or retries. */
- (void)poll;
- (void)stopObservation;

/* Sanitized host capability and last-attempt state. */
- (NSDictionary *)diagnostics;
@end

NS_ASSUME_NONNULL_END
