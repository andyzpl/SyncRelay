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
 * running. A process-local account switch always requires explicit enabling.
 * Lifecycle reentry revokes sending permission until a new manual continuation,
 * even if deferred notifications end with the same account in the foreground.
 * Faults also revoke that permission before port callbacks; enabling again is
 * not manual continuation, even when a failed pause left the run running. */
- (BOOL)refreshForeground:(BOOL)foreground sourceTimeVerified:(BOOL)verified error:(NSError **)error;
/* Keep these identifiers from the displayed snapshot through confirmation;
 * never replace them with a newer snapshot inside a delayed UI callback. */
- (BOOL)setEnabled:(BOOL)enabled account:(NSString *)account error:(NSError **)error;
/* Configuration saves are also bound to the account shown by the editor so a
 * delayed settings callback cannot trigger account-switch safety work for the
 * wrong account. */
- (BOOL)configurationSavedForAccount:(NSString *)account error:(NSError **)error;
/* Stale capture ownership is checked before reload can perform lifecycle work.
 * The envelope must carry the account that owned the original capture token. */
- (BOOL)acceptPreparedEnvelope:(NSDictionary *)envelope generation:(uint64_t)generation
                     createdAt:(NSTimeInterval)createdAt receivedAt:(NSTimeInterval)receivedAt error:(NSError **)error;
/* Opening groups is an explicit command, not a snapshot read or confirmation
 * screen. Plan creation/linkage is transactional and repeatable. */
- (nullable NSArray<NSDictionary *> *)prepareGroupsForContent:(NSString *)content account:(NSString *)account error:(NSError **)error;
- (BOOL)startGroup:(NSString *)frozenRuleID content:(NSString *)content account:(NSString *)account error:(NSError **)error;
- (BOOL)resumeRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
/* Verified frozen content retains safety controls even if editable settings are
 * unreadable. Success requires durable state readback, not dispatch readiness. */
- (BOOL)pauseRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
/* Caller owns the single confirmation. Repeated confirmed commands are safe. */
- (BOOL)cancelRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
/* Explicit upgrade action for a drained old run exposed as snapshot.legacyRun.
 * Keeps the original plan and all attempts; never enables or resumes sending. */
- (BOOL)recoverLegacyRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
/* The most recent archived ID is repeatable after a failed projection readback.
 * An older or unknown ID can never archive a newly captured replacement. */
- (BOOL)finishContent:(NSString *)content account:(NSString *)account error:(NSError **)error;
/* Pure read; never creates, arms or resumes anything. Keys include content,
 * recent, groups, run, legacyRun and libraryTask. `libraryTask` is present while
 * a frozen message-library task's run owns this account: `occupied` is true,
 * capture is refused (`captureState` = library_occupied) while `content` stays
 * null. It is never reported as `legacyRun`, never adopted, and never
 * dispatchable in this build. */
- (NSDictionary *)snapshot;
@end
NS_ASSUME_NONNULL_END
