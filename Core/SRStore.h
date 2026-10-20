#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* A process-local serialized SQLite repository. Opening never starts a sender. */
@interface SRStore : NSObject
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
@end
NS_ASSUME_NONNULL_END
