#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* Only the settings controller is extended; its original methods/delegate stay intact. */
@interface SRWeChatSettingsEntry : NSObject
@property(nonatomic, copy, nullable) void (^updated)(id controller, BOOL nativeRowPresent);
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class _Nullable (^)(NSString *name))resolver
                          open:(void (^)(id controller))open;
- (BOOL)install:(NSError **)error;
- (BOOL)refreshController:(id)controller;
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
