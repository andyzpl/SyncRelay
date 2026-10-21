#import <Foundation/Foundation.h>
@class SRImageAssetStore;

NS_ASSUME_NONNULL_BEGIN
/* A process-local serialized SQLite repository. Opening never starts a sender. */
@interface SRStore : NSObject
@property(nonatomic, strong, readonly) SRImageAssetStore *imageAssets;
- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error;
/* Low-level constructor retained for core tests; capture uses the atomic API below. */
- (nullable NSString *)createPlanForAccount:(NSString *)account
                               sourceGroup:(NSString *)group
                                   senders:(NSArray<NSString *> *)senders
                                     types:(NSArray<NSString *> *)types
                              sourceSnapshot:(NSDictionary *)snapshot
                                     error:(NSError **)error;
- (nullable NSString *)addRuleToPlan:(NSString *)plan name:(NSString *)name
                            targets:(NSArray<NSString *> *)targets
                            minimum:(double)minimum maximum:(double)maximum
                              error:(NSError **)error;
/* replay=YES requires history and explicit caller confirmation before invocation. */
- (nullable NSString *)startRule:(NSString *)rule replay:(BOOL)replay error:(NSError **)error;
- (BOOL)pauseRun:(NSString *)run error:(NSError **)error;
/* Manual continuation sends only pending targets. Uncertain/failed attempts
 * are retained and never requeued; no per-target user review is required. */
- (BOOL)resumeRun:(NSString *)run error:(NSError **)error;
- (BOOL)recoverInterruptedRuns:(NSError **)error;
/* Claim is transactional, but pacing and adapter availability are caller gates. */
- (nullable NSDictionary *)claimNextForRun:(NSString *)run error:(NSError **)error;
- (BOOL)recordResultForDelivery:(NSString *)delivery attempt:(NSString *)attempt
                         state:(NSString *)state messageID:(nullable NSString *)messageID
                        reason:(nullable NSString *)reason error:(NSError **)error;
- (BOOL)endRun:(NSString *)run error:(NSError **)error;
- (nullable NSDictionary *)summaryForRun:(NSString *)run error:(NSError **)error;
- (nullable NSArray<NSString *> *)allocatedTargetsForPlan:(NSString *)plan error:(NSError **)error;
/* Configuration drafts do not create plans, runs or deliveries. */
- (nullable NSDictionary *)configurationForAccount:(NSString *)account error:(NSError **)error;
- (BOOL)saveConfiguration:(NSDictionary *)configuration account:(NSString *)account error:(NSError **)error;
/* Captured source claim, frozen rules and target allocations commit atomically. */
- (nullable NSString *)createPlanFromConfiguration:(NSDictionary *)configuration envelope:(NSDictionary *)envelope
                                          account:(NSString *)account error:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)rulesForPlan:(NSString *)plan error:(NSError **)error;
/* Account-scoped UI projections. Read operations never create or resume runs. */
- (nullable NSArray<NSDictionary *> *)plansForAccount:(NSString *)account limit:(NSUInteger)limit
                                             offset:(NSUInteger)offset error:(NSError **)error;
- (nullable NSDictionary *)plan:(NSString *)plan account:(NSString *)account error:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)ruleCardsForPlan:(NSString *)plan account:(NSString *)account error:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)historyForRule:(NSString *)rule account:(NSString *)account
                                            limit:(NSUInteger)limit offset:(NSUInteger)offset error:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)exceptionsForRun:(NSString *)run account:(NSString *)account
                                               limit:(NSUInteger)limit offset:(NSUInteger)offset error:(NSError **)error;
/* Persist before the experimental host call. Same source cannot be submitted
 * again after reopening a panel or process; no run/delivery is created. */
- (BOOL)claimTextExperiment:(NSDictionary *)source configuration:(NSDictionary *)configuration
                   account:(NSString *)account target:(NSString *)target error:(NSError **)error;
- (nullable NSDictionary *)textExperimentSummaryForAccount:(NSString *)account error:(NSError **)error;
/* Independent image ledger; both experiment ledgers reject a source already claimed by either type. */
- (BOOL)claimImageExperiment:(NSDictionary *)source configuration:(NSDictionary *)configuration
                    account:(NSString *)account target:(NSString *)target error:(NSError **)error;
- (nullable NSDictionary *)imageExperimentSummaryForAccount:(NSString *)account error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
