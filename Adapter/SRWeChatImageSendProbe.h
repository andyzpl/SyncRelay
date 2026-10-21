#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* Explicit, main-thread contract inspection. Allocates one unsent type-3 wrap;
 * never calls image setters, resolves a message service or submits a message. */
@interface SRWeChatImageSendProbe : NSObject
- (instancetype)initWithVersion:(NSString *)version
                  classResolver:(Class _Nullable (^)(NSString *))resolver
                 currentAccount:(NSString * _Nullable (^)(void))currentAccount
             environmentAllowed:(BOOL (^)(void))environmentAllowed;
- (BOOL)inspectForAccount:(NSString *)account error:(NSError **)error;
/* Fixed labels, scalar ABI tokens and booleans only. No native object is retained. */
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
