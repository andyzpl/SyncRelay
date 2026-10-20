#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface SRGroupPlanner : NSObject
+ (nullable NSDictionary *)configurationBySettingSourceGroup:(NSDictionary *)group
                                                    inDraft:(NSDictionary *)draft error:(NSError **)error;
// Recipe entries are {size: 100|200, count: non-negative integer}, in allocation order.
// The immutable preview contains a candidate configuration and actual/shortfall counts.
+ (nullable NSDictionary *)previewWithRows:(NSArray<NSDictionary *> *)rows draft:(NSDictionary *)draft
                                  recipe:(NSArray<NSDictionary *> *)recipe error:(NSError **)error;
// Changes draft targets only. Existing execution history is never edited.
+ (nullable NSDictionary *)configurationBySettingExcludedGroups:(NSArray<NSDictionary *> *)groups
                                                       inDraft:(NSDictionary *)draft error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
