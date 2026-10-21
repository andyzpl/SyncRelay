#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NSDictionary * _Nullable (^SRImageMaterialLoader)(NSDictionary *source, NSError **error);
typedef void (^SRWeChatImageSendHostCompletion)(NSString *state, NSString * _Nullable messageID, NSString * _Nullable reason);

/* A process-lifetime, single-target experiment, not a runner transport.
 * Caller must persist the source reservation before submitRequest. The loader
 * validates owned media; the native setter may write host files. No retries. */
@interface SRWeChatImageSendHost : NSObject
- (instancetype)initWithVersion:(NSString *)version
                  classResolver:(Class _Nullable (^)(NSString *))resolver
                 currentAccount:(NSString * _Nullable (^)(void))currentAccount
             environmentAllowed:(BOOL (^)(void))environmentAllowed
                 materialLoader:(SRImageMaterialLoader)materialLoader;
/* Main-thread only; no image loading, construction or setter call. */
- (BOOL)readyForAccount:(NSString *)account error:(NSError **)error;
- (void)submitRequest:(NSDictionary *)request completion:(SRWeChatImageSendHostCompletion _Nullable)completion;
- (void)poll;
- (void)stopObservation;
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
