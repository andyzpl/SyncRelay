#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/* Verified local Mikoto call site: +[CMessageWrap getMsgHdOrMiddleImg:wrap].
 * Only an existing native UIImage is read; no guessed path or download API. */
@interface SRWeChatImageSource : NSObject
- (instancetype)initWithClassResolver:(Class _Nullable (^)(NSString *))resolver;
- (nullable id)imageForWrap:(id)wrap error:(NSError **)error;
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
