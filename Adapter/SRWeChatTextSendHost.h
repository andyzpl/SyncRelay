#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SRWeChatTextSendHostCompletion)(NSString *state, NSString * _Nullable messageID,
                                                NSString * _Nullable reason);

/*
 * Version-gated, single-target text construction and host submission candidate.
 * It is deliberately not installed by the production bootstrap yet; the first
 * device check must confirm the constructed wrap and callback association.
 */
@interface SRWeChatTextSendHost : NSObject
- (instancetype)initWithVersion:(NSString *)version
                   classResolver:(Class _Nullable (^)(NSString *))resolver
                 currentAccount:(NSString * _Nullable (^)(void))currentAccount
            environmentAllowed:(BOOL (^)(void))environmentAllowed;

/* Main-thread only. This performs ABI checks but does not submit a message. */
- (BOOL)readyForAccount:(NSString *)account error:(NSError **)error;

/* Main-thread only. One request, one target, no automatic retry. */
- (void)submitRequest:(NSDictionary *)request completion:(SRWeChatTextSendHostCompletion)completion;

/* Sanitized host capability and last-attempt state. */
- (NSDictionary *)diagnostics;
@end

NS_ASSUME_NONNULL_END
