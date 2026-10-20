#import <Foundation/Foundation.h>
#import "Core/SRRunner.h"

NS_ASSUME_NONNULL_BEGIN

/*
 * A single-target text transport gate. The production initializer receives no
 * operation, so it can validate a host but cannot send anything. Tests may
 * inject a fake operation to exercise the runner contract without invoking a
 * private WeChat message API.
 */
typedef void (^SRTextSendOperation)(NSDictionary *request, SRSendCompletion completion);

@interface SRWeChatTextSendAdapter : NSObject <SRSendTransport>
- (instancetype)initWithVersion:(NSString *)version
                   classResolver:(Class _Nullable (^)(NSString *))resolver
                 currentAccount:(NSString * _Nullable (^)(void))currentAccount
            environmentAllowed:(BOOL (^)(void))environmentAllowed
                       operation:(SRTextSendOperation _Nullable)operation;

/* Requires an explicit UI confirmation and freezes one source snapshot. */
- (BOOL)prepareForAccount:(NSString *)account targetGroup:(NSString *)group
           sourceSnapshot:(NSDictionary *)snapshot confirmed:(BOOL)confirmed
                    error:(NSError **)error;
- (void)reset;
/* Sanitized state only; no account, group, source ID or message body. */
- (NSDictionary *)diagnostics;
@end

NS_ASSUME_NONNULL_END
