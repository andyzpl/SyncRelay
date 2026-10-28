#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/* Two different user intents, kept apart in Core rather than in UI copy:
 *
 * - SRGroupingIntentAutomatic: the automatic entry. Automatic rules below their
 *   capacity are topped up from the pool first; the remaining rows then become
 *   new automatic rules.
 * - SRGroupingIntentCustom: the hand-picked entry. The rows are exactly the
 *   composition the user chose: they are never consumed by an earlier top-up,
 *   and the rules created here are marked custom so a later automatic pass
 *   leaves them alone.
 */
typedef NS_ENUM(NSUInteger, SRGroupingIntent) {
    SRGroupingIntentAutomatic = 0,
    SRGroupingIntentCustom = 1
};

@interface SRGroupPlanner : NSObject
+ (nullable NSDictionary *)configurationBySettingSourceGroup:(NSDictionary *)group
                                                    inDraft:(NSDictionary *)draft error:(NSError **)error;
// Recipe entries are {size: 100|200, count: non-negative integer}, in allocation order.
// The immutable preview contains a candidate configuration and actual/shortfall counts.
// A top-up pass runs only for the automatic intent; `executionLimit` is the
// caller's per-rule executable range (0 means no clamp). The planner never
// hardcodes that limit.
+ (nullable NSDictionary *)previewWithRows:(NSArray<NSDictionary *> *)rows draft:(NSDictionary *)draft
                                  recipe:(NSArray<NSDictionary *> *)recipe
                                  intent:(SRGroupingIntent)intent
                          executionLimit:(NSUInteger)executionLimit
                                   error:(NSError **)error;
// Automatic intent, with and without the executable-range clamp.
+ (nullable NSDictionary *)previewWithRows:(NSArray<NSDictionary *> *)rows draft:(NSDictionary *)draft
                                  recipe:(NSArray<NSDictionary *> *)recipe
                          executionLimit:(NSUInteger)executionLimit
                                   error:(NSError **)error;
+ (nullable NSDictionary *)previewWithRows:(NSArray<NSDictionary *> *)rows draft:(NSDictionary *)draft
                                  recipe:(NSArray<NSDictionary *> *)recipe error:(NSError **)error;
// The grouping spec of one rule: its stored capacity, or the default for a rule
// saved before the field existed. Never the execution limit.
+ (NSUInteger)capacityForRule:(NSDictionary *)rule;
// Changes draft targets only. Existing execution history is never edited.
+ (nullable NSDictionary *)configurationBySettingExcludedGroups:(NSArray<NSDictionary *> *)groups
                                                       inDraft:(NSDictionary *)draft error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
