#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* Only the settings controller is extended; its original reload/delegate stay intact. */
@interface SRWeChatSettingsEntry : NSObject
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class _Nullable (^)(NSString *name))resolver
                          open:(void (^)(id controller))open;
- (BOOL)install:(NSError **)error;
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
