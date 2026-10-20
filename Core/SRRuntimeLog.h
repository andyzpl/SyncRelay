#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface SRRuntimeLog : NSObject
+ (instancetype)shared;
- (void)enablePersistenceAtPath:(NSString *)path;
// Only fixed event names and allowlisted numeric facts are retained.
- (void)record:(NSString *)event facts:(NSDictionary *)facts;
- (NSDictionary *)snapshot;
@end
NS_ASSUME_NONNULL_END
