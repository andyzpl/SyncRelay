#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/* Own one bounded in-memory copy, never a host path, download or send request. */
@interface SRWeChatFileSource : NSObject
+ (nullable NSDictionary *)snapshotForWrap:(id)wrap expectedSize:(unsigned long long)size
                                    home:(NSString *)home allowed:(BOOL (^)(void))allowed
                                   state:(NSString * _Nonnull * _Nonnull)state;
@end
NS_ASSUME_NONNULL_END
