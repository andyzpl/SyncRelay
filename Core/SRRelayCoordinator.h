#import <Foundation/Foundation.h>
#include <stdint.h>
@class SRStore;
NS_ASSUME_NONNULL_BEGIN

/* Shared by every future UI entry. Legacy endRun is deliberately not a cancel
 * operation: cancellation must preserve in-flight observation. */
@protocol SRRelayExecution <NSObject>
- (BOOL)startRule:(NSString *)rule account:(NSString *)account error:(NSError **)error;
- (BOOL)resumeRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
- (BOOL)pauseForAccount:(NSString *)account error:(NSError **)error;
- (BOOL)cancelRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
@end

@protocol SRRelayCaptureControl <NSObject>
/* Deliver events asynchronously after this method returns, using the supplied
 * token and the original receipt/time evidence, not preparation completion. */
- (BOOL)startForAccount:(NSString *)account configuration:(NSDictionary *)configuration
            generation:(uint64_t)generation error:(NSError **)error;
- (void)stop;
@end

/* Main-thread command owner; snapshot is a pure read. No UIKit, host sender,
 * timer or settings-page lifetime dependency. Host attachment is stage C. */
@interface SRRelayCoordinator : NSObject
- (instancetype)initWithStore:(SRStore *)store execution:(id<SRRelayExecution>)execution
                       capture:(id<SRRelayCaptureControl>)capture
                currentAccount:(NSString * _Nullable (^)(void))currentAccount
                         clock:(NSTimeInterval (^)(void))wallClock;
/* Call after store interruption recovery, not while another process owner is
 * running. A process-local account switch always requires explicit enabling. */
- (BOOL)refreshForeground:(BOOL)foreground sourceTimeVerified:(BOOL)verified error:(NSError **)error;
- (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error;
- (BOOL)configurationSaved:(NSError **)error;
- (BOOL)acceptPreparedEnvelope:(NSDictionary *)envelope generation:(uint64_t)generation
                     createdAt:(NSTimeInterval)createdAt receivedAt:(NSTimeInterval)receivedAt error:(NSError **)error;
/* Opening groups is an explicit command, not a snapshot read or confirmation
 * screen. Plan creation/linkage is transactional and repeatable. */
- (nullable NSArray<NSDictionary *> *)prepareGroups:(NSError **)error;
- (BOOL)startGroup:(NSString *)frozenRuleID error:(NSError **)error;
- (BOOL)resume:(NSError **)error;
/* Verified frozen content retains safety controls even if editable settings are
 * unreadable. Success requires durable state readback, not dispatch readiness. */
- (BOOL)pause:(NSError **)error;
/* Caller owns the single confirmation. Repeated confirmed commands are safe. */
- (BOOL)cancel:(NSError **)error;
/* Explicit upgrade action for a drained old run exposed as snapshot.legacyRun.
 * Keeps the original plan and all attempts; never enables or resumes sending. */
- (BOOL)recoverLegacyRun:(NSString *)run error:(NSError **)error;
- (BOOL)finishContent:(NSError **)error;
- (NSDictionary *)snapshot;
@end
NS_ASSUME_NONNULL_END
