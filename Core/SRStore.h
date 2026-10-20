#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* A process-local serialized SQLite repository. Opening never starts a sender. */
@interface SRStore : NSObject
- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error;
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
@end
NS_ASSUME_NONNULL_END
