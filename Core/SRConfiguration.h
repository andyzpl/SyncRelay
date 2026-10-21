#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface SRConfiguration : NSObject
+ (NSMutableDictionary *)emptyDraft;
+ (BOOL)validateDraft:(NSDictionary *)draft error:(NSError **)error;
/* Stable requirement IDs for settings/coordinator; an editable draft may be
 * valid while not yet complete enough to enable operations. */
+ (NSArray<NSString *> *)operationsRequirementsForDraft:(NSDictionary *)draft;
@end
NS_ASSUME_NONNULL_END
