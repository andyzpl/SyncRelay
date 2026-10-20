#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface SRConfiguration : NSObject
+ (NSMutableDictionary *)emptyDraft;
+ (BOOL)validateDraft:(NSDictionary *)draft error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
