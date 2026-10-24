#import <Foundation/Foundation.h>
#import "SRMediaQuota.h"
@class SRImageAssetStore;

NS_ASSUME_NONNULL_BEGIN
/* A process-local serialized SQLite repository. Opening never starts a sender. */
@interface SRStore : NSObject
@property(nonatomic, strong, readonly) SRImageAssetStore *imageAssets;
/* Read back after the constructor's migration transaction commits. This is
 * the current schema, not a record of the pre-open version or migration proof. */
@property(nonatomic, readonly) NSInteger schemaVersion;
/* Bounded, numeric-only evidence from this open. It never contains IDs,
 * payloads or row contents; row counts are a consistency hint, not proof that
 * every historical value was preserved. */
@property(nonatomic, copy, readonly) NSDictionary *migrationDiagnostics;
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
/* Account business preference, independent of the legacy floating shortcut.
 * Missing rows are disabled. Enabling validates the saved configuration. */
- (nullable NSNumber *)operationsEnabledForAccount:(NSString *)account error:(NSError **)error;
- (BOOL)setOperationsEnabled:(BOOL)enabled account:(NSString *)account error:(NSError **)error;
/* Prepared source + frozen configuration commit before any captured UI. No run
 * is created. Duplicate active source returns its ID without changing content. */
- (nullable NSString *)saveOperationsContent:(NSDictionary *)envelope configuration:(NSDictionary *)configuration
                                    account:(NSString *)account capturedAt:(NSTimeInterval)capturedAt error:(NSError **)error;
/* Recent means the last archived content in durable occupancy order, not the
 * largest wall-clock timestamp. Original capture/archive dates are unchanged.
 * `libraryOccupancy` is an account-scoped projection of a frozen task's live
 * run (taskID/runID/state); it is never reported as `legacyRun`, but it does
 * mean the account is occupied and group capture must not arm. */
- (nullable NSDictionary *)operationsContentForAccount:(NSString *)account error:(NSError **)error;
/* Explicit upgrade of a drained, authorized legacy run. Reuses its original
 * plan/source/allocations; never creates a run, changes claims or resumes it.
 * Legacy capture time is unknown and is projected as null, not adoption time. */
- (nullable NSString *)adoptLegacyOperationsRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
- (nullable NSString *)planForOperationsContent:(NSString *)content account:(NSString *)account error:(NSError **)error;
- (BOOL)archiveOperationsContent:(NSString *)content account:(NSString *)account error:(NSError **)error;
/* Cancel pending only. A submitting attempt retains its callback/timeout and
 * the account's active-run slot until drained; never resumable afterwards. */
- (BOOL)cancelOperationsRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
- (nullable NSDictionary *)operationsCancellationForRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
/* Captured source claim, frozen rules and target allocations commit atomically. */
- (nullable NSString *)createPlanFromConfiguration:(NSDictionary *)configuration envelope:(NSDictionary *)envelope
                                          account:(NSString *)account error:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)rulesForPlan:(NSString *)plan error:(NSError **)error;
/* Account-scoped UI projections. Read operations never create or resume runs. */
- (nullable NSArray<NSDictionary *> *)plansForAccount:(NSString *)account limit:(NSUInteger)limit
                                             offset:(NSUInteger)offset error:(NSError **)error;
- (nullable NSDictionary *)plan:(NSString *)plan account:(NSString *)account error:(NSError **)error;
/* Run cards include creationOrder for ordering, never for displayed dates. */
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
/* Explicit device checkpoint: 1..20 targets, initial execution only. These
 * authorizations and per-delivery native claims survive process restarts. */
- (nullable NSString *)startSmallGroupRule:(NSString *)rule account:(NSString *)account error:(NSError **)error;
- (nullable NSDictionary *)smallGroupRulePreview:(NSString *)rule account:(NSString *)account error:(NSError **)error;
- (nullable NSDictionary *)smallGroupRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
- (BOOL)endSmallGroupRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
- (BOOL)claimSmallGroupDelivery:(NSDictionary *)delivery source:(NSDictionary *)source
                       account:(NSString *)account error:(NSError **)error;
/* Message library: account-scoped entries with a stable ID, independent of any
 * WeChat group, server message ID, source claim, plan, run or delivery. Saving
 * only stores bytes/payload and never sends, never creates a plan or claim. */
- (nullable NSString *)createLibraryItemForAccount:(NSString *)account kind:(NSString *)kind
                                           payload:(NSDictionary *)payload
                                        capturedAt:(NSTimeInterval)capturedAt error:(NSError **)error;
/* Editing appends an immutable version; the previous version is never updated.
 * Pass the current version ID to reject a stale editor, or nil to append blind. */
- (nullable NSString *)appendLibraryVersion:(NSString *)item account:(NSString *)account
                                    payload:(NSDictionary *)payload expectedVersion:(nullable NSString *)expectedVersion
                                 capturedAt:(NSTimeInterval)capturedAt error:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)libraryItemsForAccount:(NSString *)account limit:(NSUInteger)limit
                                                      offset:(NSUInteger)offset error:(NSError **)error;
- (nullable NSDictionary *)libraryItem:(NSString *)item account:(NSString *)account error:(NSError **)error;
/* Identical bytes within one account reuse one stored token; they never merge
 * an entry, version, plan or sending task. Other accounts never share it.
 * Failure guarantees: returns nil and sets no row, no new file and no reservation
 * behind. A refused material write reports the image-asset error unchanged
 * (domain, code and the quota userInfo keys). A database failure — a rolled-back
 * statement or a COMMIT that never landed — reports the store error and takes
 * precedence over the material error, and a file written by that call is removed
 * even though the INSERT succeeded. Bytes reused from an existing token are never
 * removed. `error` may be NULL, and success never writes to it. */
- (nullable NSDictionary *)saveLibraryImageData:(NSData *)data account:(NSString *)account error:(NSError **)error;
/* One confirmed freeze of a library version: an independent task identity with
 * its own plan, rule, frozen snapshot and target scope. confirmationID is the
 * idempotency key for the whole request: entry, resolved version (nil means the
 * current version at first confirmation), ordered targets and interval. An
 * identical retry returns the same task; any different request with the same
 * key is rejected and never resolves to another task. Nothing is dispatched, no
 * source claim is written, and the snapshot may not carry a group, sender or
 * server message ID. */
- (nullable NSString *)createLibraryTaskForAccount:(NSString *)account item:(NSString *)item
                                           version:(nullable NSString *)version confirmationID:(NSString *)confirmationID
                                           targets:(NSArray<NSString *> *)targets
                                           minimum:(double)minimum maximum:(double)maximum error:(NSError **)error;
/* Explicit start: creates the task's single run (awaiting_resume) and its
 * pending deliveries. Repeating it returns the existing run. The only update a
 * frozen task row ever accepts is this one: run_id and started_at go NULL ->
 * value together, once; everything else about the freeze is immutable. */
- (nullable NSString *)startLibraryTask:(NSString *)task account:(NSString *)account error:(NSError **)error;
/* Separate re-send entry: a new task frozen from the original bytes, never from
 * the editable entry. Its confirmation key is additionally bound to that origin
 * task and to the re-send operation, so a create key or another task's key can
 * never resolve here. Claims, the original task and its run stay untouched. */
- (nullable NSString *)resendLibraryTask:(NSString *)task account:(NSString *)account
                          confirmationID:(NSString *)confirmationID error:(NSError **)error;
/* Re-verifies the freeze against durable rows; nil on tampering or loss. */
- (nullable NSDictionary *)libraryTask:(NSString *)task account:(NSString *)account error:(NSError **)error;
/* Where captured operations content came from: group_sync or message_library. */
- (nullable NSDictionary *)sourceForOperationsContent:(NSString *)content account:(NSString *)account
                                                error:(NSError **)error;
/* Hides a library entry from the list without deleting an immutable version, a
 * frozen task, a plan, a source claim or a single media byte. Idempotent. */
- (BOOL)deleteLibraryEntry:(NSString *)item account:(NSString *)account error:(NSError **)error;
/* Which entry a future group send reads from; defaults to group_sync. Switching
 * is refused while a run is active or captured content is unended, and never
 * rewrites a frozen plan, task or claim. */
- (nullable NSString *)sourceModeForAccount:(NSString *)account error:(NSError **)error;
- (BOOL)setSourceMode:(NSString *)mode account:(NSString *)account error:(NSError **)error;
/* Account-scoped media inventory for the resource page: kind, bytes, time,
 * reference state and in-use state, keyed by a display digest. Files only another
 * account references are counted, never listed or named. */
- (nullable NSDictionary *)mediaResourcesForAccount:(NSString *)account limit:(NSUInteger)limit
                                              error:(NSError **)error;
/* One shared 256 MiB budget for every SyncRelay-owned media file, all accounts
 * included. A failed scan returns nil plus an error, never a zero that reads as
 * free space. The result carries no token, file name or body. */
- (nullable NSDictionary *)mediaUsageForAccount:(NSString *)account error:(NSError **)error;
/* @YES the first time usage reaches the warning ratio, @NO when there is nothing
 * to present, nil on failure. The flag is persisted per account (keyed by an
 * account digest) so reopening a panel or the process does not repeat it. */
- (nullable NSNumber *)claimMediaWarningForAccount:(NSString *)account error:(NSError **)error;
/* Same call with an explicit ratio policy; the reset band is adjustable. */
- (nullable NSNumber *)claimMediaWarningForAccount:(NSString *)account policy:(SRMediaPolicy)policy
                                             error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
