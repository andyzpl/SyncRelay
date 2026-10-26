#import <Foundation/Foundation.h>
#import "Core/SRRelayCoordinator.h"
#import "Core/SROperationsState.h"
#import "Core/SRConfiguration.h"
#import "Core/SRStore.h"
#import "Core/SRRuntimeLog.h"
#import <sqlite3.h>
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

@interface CapturePort : NSObject <SRRelayCaptureControl>
@property(nonatomic) NSUInteger starts;
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL throwArm;
@property(nonatomic) BOOL throwStop;
@property(nonatomic, copy) void (^duringArm)(void);
@end
@implementation CapturePort
- (BOOL)startForAccount:(__unused NSString *)account configuration:(__unused NSDictionary *)configuration
            generation:(uint64_t)generation error:(__unused NSError **)error {
    self.starts++; self.generation = generation; self.active = YES;
    if (self.duringArm) self.duringArm();
    if (self.throwArm) @throw @"private capture details";
    return YES;
}
- (void)stop { if (self.throwStop) @throw @"private stop details"; self.active = NO; }
@end

@interface ReadFaultStore : SRStore
@property(nonatomic) BOOL failContentRead;
@property(nonatomic) NSUInteger contentReads;
@property(nonatomic) NSUInteger archives;
@property(nonatomic, copy) void (^afterArchive)(void);
@end
@implementation ReadFaultStore
- (NSDictionary *)operationsContentForAccount:(NSString *)account error:(NSError **)error {
    self.contentReads++;
    if (!self.failContentRead) return [super operationsContentForAccount:account error:error];
    if (error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey: @"injected content read failure"}];
    return nil;
}
- (BOOL)archiveOperationsContent:(NSString *)content account:(NSString *)account error:(NSError **)error {
    self.archives++;
    BOOL result = [super archiveOperationsContent:content account:account error:error];
    if (result && self.afterArchive) self.afterArchive();
    return result;
}
@end

@interface ExecutionPort : NSObject <SRRelayExecution>
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, copy) NSString *run;
@property(nonatomic) NSUInteger starts;
@property(nonatomic) NSUInteger resumes;
@property(nonatomic) BOOL failAttach;
@property(nonatomic) BOOL silentStartFailure;
@property(nonatomic) BOOL throwAfterStart;
@property(nonatomic) BOOL liePause;
@property(nonatomic) BOOL rejectPause;
@property(nonatomic) NSUInteger pauses;
@property(nonatomic) NSUInteger cancels;
@property(nonatomic, copy) void (^duringStart)(void);
@property(nonatomic, copy) void (^duringResume)(void);
@property(nonatomic, copy) void (^afterCancel)(void);
@end
@implementation ExecutionPort
- (BOOL)startRule:(NSString *)rule account:(NSString *)account error:(NSError **)error {
    self.starts++;
    if (self.duringStart) self.duringStart();
    if (self.silentStartFailure) return NO;
    self.run = [self.store startSmallGroupRule:rule account:account error:error];
    if (!self.run) return NO;
    if (self.throwAfterStart) @throw @"private execution details";
    if (self.failAttach) {
        CHECK([self.store pauseRun:self.run error:NULL]);
        if (error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey: @"fake attach failure"}];
        return NO;
    }
    return YES;
}
- (BOOL)resumeRun:(NSString *)run account:(__unused NSString *)account error:(NSError **)error {
    self.resumes++; self.run = run;
    if (self.duringResume) self.duringResume();
    return [self.store resumeRun:run error:error];
}
- (BOOL)pauseForAccount:(NSString *)account error:(NSError **)error {
    self.pauses++;
    if (self.liePause) return YES;
    if (self.rejectPause) {
        if (error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey: @"injected pause rejection"}];
        return NO;
    }
    NSDictionary *row = self.run ? [self.store summaryForRun:self.run error:NULL] : nil;
    if (![row[@"account"] isEqual:account]) return NO;
    if ([row[@"state"] isEqual:@"paused"] || [row[@"state"] isEqual:@"awaiting_resume"]) return YES;
    return [row[@"state"] isEqual:@"running"] && [self.store pauseRun:self.run error:error];
}
- (BOOL)cancelRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    self.cancels++;
    if ([[self.store summaryForRun:run error:NULL][@"state"] isEqual:@"running"]) CHECK([self.store pauseRun:run error:NULL]);
    BOOL result = [self.store cancelOperationsRun:run account:account error:error];
    if (result && self.afterCancel) self.afterCancel();
    return result;
}
@end

static NSMutableDictionary *configuration(void) {
    NSMutableDictionary *draft = [SRConfiguration emptyDraft];
    draft[@"sourceGroup"] = @{@"id": @"mother@chatroom", @"name": @"Mother"};
    draft[@"senders"] = @[@{@"id": @"sender", @"name": @"Sender"}];
    draft[@"rules"] = @[@{@"id": @"one", @"name": @"One", @"targets": @[
        @{@"id": @"a@chatroom", @"name": @"A"}, @{@"id": @"b@chatroom", @"name": @"B"}]},
        @{@"id": @"two", @"name": @"Two", @"targets": @[@{@"id": @"c@chatroom", @"name": @"C"}]}];
    return draft;
}
static NSDictionary *source(NSString *identifier) {
    return @{@"account": @"account", @"group": @"mother@chatroom", @"sender": @"sender", @"messageID": identifier,
        @"type": @"text", @"generatedByRelay": @NO, @"payload": @{@"text": @"original"}};
}
static NSUInteger count(SRStore *store, NSString *run, NSString *state) {
    for (NSDictionary *row in [store summaryForRun:run error:NULL][@"counts"])
        if ([row[@"state"] isEqual:state]) return [row[@"count"] unsignedIntegerValue];
    return 0;
}

// Synchronous simulated actions only. Delayed-confirmation tests retain the
// original identifiers explicitly instead of consulting a newer snapshot.
static NSString *displayedAccount(SRRelayCoordinator *coordinator) {
    id account = coordinator.snapshot[@"account"];
    return [account isKindOfClass:NSString.class] ? account : @"";
}
static NSString *displayedRecordID(id record) {
    return [record isKindOfClass:NSDictionary.class] ? record[@"id"] : @"";
}
static NSString *displayedContent(SRRelayCoordinator *coordinator) { return displayedRecordID(coordinator.snapshot[@"content"]); }
static NSString *displayedRun(SRRelayCoordinator *coordinator) { return displayedRecordID(coordinator.snapshot[@"run"]); }

static void checkUnreadableConfigurationControls(NSString *root) {
    NSString *path = [root stringByAppendingPathComponent:@"unreadable-configuration.sqlite3"];
    SRStore *store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
    CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
    CHECK([store setOperationsEnabled:YES account:@"account" error:NULL]);
    ExecutionPort *execution = [ExecutionPort new]; execution.store = store;
    CapturePort *capture = [CapturePort new]; __block double now = 300.2;
    SRRelayCoordinator *coordinator = [[SRRelayCoordinator alloc] initWithStore:store execution:execution capture:capture
        currentAccount:^NSString *{ return @"account"; } clock:^double { return now; }];
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]); now = 302;
    CHECK([coordinator acceptPreparedEnvelope:source(@"unreadable-settings") generation:capture.generation createdAt:301 receivedAt:302 error:NULL]);
    NSArray *groups = [coordinator prepareGroupsForContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]; CHECK(groups.count == 2);
    NSString *content = coordinator.snapshot[@"content"][@"id"];
    CHECK([coordinator startGroup:groups[0][@"id"] content:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]);
    NSString *run = execution.run;
    sqlite3 *fault = NULL; CHECK(sqlite3_open(path.fileSystemRepresentation, &fault) == SQLITE_OK);
    CHECK(sqlite3_exec(fault, "UPDATE configurations SET payload='{}' WHERE account='account'", NULL, NULL, NULL) == SQLITE_OK);
    NSError *error = nil;
    CHECK(![coordinator configurationSavedForAccount:displayedAccount(coordinator) error:&error] && error);
    CHECK([coordinator.snapshot[@"stateLoaded"] boolValue]);
    CHECK([coordinator.snapshot[@"requirements"] isEqual:@[@"configuration_invalid"]]);
    CHECK([coordinator.snapshot[@"content"][@"id"] isEqual:content]);
    CHECK([coordinator.snapshot[@"content"][@"configuration"][@"minimum"] isEqual:@5]);
    CHECK([[store summaryForRun:run error:NULL][@"state"] isEqual:@"paused"]);
    CHECK(count(store, run, @"pending") == 2 && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
    CHECK([coordinator pauseRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL] && [coordinator.snapshot[@"phase"] integerValue] == SROpsPaused);
    CHECK(![coordinator resumeRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL] && ![coordinator startGroup:groups[1][@"id"] content:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]);
    // Corrupt editable settings do not take away controls for a verified frozen task.
    CHECK([coordinator cancelRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL] && [coordinator cancelRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL]);
    CHECK([coordinator.snapshot[@"phase"] integerValue] == SROpsGroupCancelled);
    CHECK(count(store, run, @"cancelled") == 2);
    NSDictionary *cancellation = [store operationsCancellationForRun:run account:@"account" error:NULL];
    CHECK(cancellation[@"drained_at"] != NSNull.null);
    CHECK(sqlite3_exec(fault, "CREATE TRIGGER fail_archive BEFORE UPDATE OF archived_at ON operations_contents BEGIN SELECT RAISE(ABORT,'fault'); END", NULL, NULL, NULL) == SQLITE_OK);
    CHECK(![coordinator finishContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]);
    CHECK([[store operationsContentForAccount:@"account" error:NULL][@"current"][@"id"] isEqual:content]);
    CHECK(sqlite3_exec(fault, "DROP TRIGGER fail_archive", NULL, NULL, NULL) == SQLITE_OK);
    CHECK([coordinator finishContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]);
    CHECK(coordinator.snapshot[@"content"] == NSNull.null && [coordinator.snapshot[@"recent"][@"id"] isEqual:content]);
    CHECK(!capture.active && ![coordinator.snapshot[@"captureAllowed"] boolValue]);
    CHECK([coordinator.snapshot[@"problem"] length] > 0);
    CHECK([[store operationsCancellationForRun:run account:@"account" error:NULL] isEqual:cancellation]);
    CHECK([store plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 1);
    CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
    CHECK([coordinator configurationSavedForAccount:displayedAccount(coordinator) error:NULL] && !capture.active);
    CHECK([coordinator setEnabled:YES account:displayedAccount(coordinator) error:NULL] && capture.active);
    CHECK(execution.starts == 1 && execution.resumes == 0);
    CHECK(sqlite3_close(fault) == SQLITE_OK);
    puts("PASS: unreadable editable settings block dispatch but retain frozen-task cancellation/archive controls and rollback");
}

static void checkCancellationReadback(NSString *root) {
    ReadFaultStore *store = [[ReadFaultStore alloc] initWithPath:[root stringByAppendingPathComponent:@"cancel-readback.sqlite3"] error:NULL]; CHECK(store);
    CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
    CHECK([store setOperationsEnabled:YES account:@"account" error:NULL]);
    ExecutionPort *execution = [ExecutionPort new]; execution.store = store;
    CapturePort *capture = [CapturePort new]; __block double now = 400.2;
    SRRelayCoordinator *coordinator = [[SRRelayCoordinator alloc] initWithStore:store execution:execution capture:capture
        currentAccount:^NSString *{ return @"account"; } clock:^double { return now; }];
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]); now = 402;
    CHECK([coordinator acceptPreparedEnvelope:source(@"cancel-readback") generation:capture.generation createdAt:401 receivedAt:402 error:NULL]);
    NSArray *groups = [coordinator prepareGroupsForContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]; CHECK(groups.count == 2);
    CHECK([coordinator startGroup:groups[0][@"id"] content:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]);
    NSString *run = execution.run;
    execution.afterCancel = ^{ store.failContentRead = YES; };
    NSError *error = nil;
    CHECK(![coordinator cancelRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:&error] && error);
    CHECK(![coordinator.snapshot[@"stateLoaded"] boolValue] && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
    CHECK([[store summaryForRun:run error:NULL][@"state"] isEqual:@"ended"]);
    NSDictionary *cancellation = [store operationsCancellationForRun:run account:@"account" error:NULL];
    CHECK(cancellation[@"drained_at"] != NSNull.null);
    execution.afterCancel = nil; store.failContentRead = NO;
    CHECK([coordinator cancelRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL]);
    CHECK([coordinator.snapshot[@"phase"] integerValue] == SROpsGroupCancelled);
    CHECK([[store operationsCancellationForRun:run account:@"account" error:NULL] isEqual:cancellation]);
    CHECK(execution.starts == 1 && execution.resumes == 0);
    CHECK([coordinator finishContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL] && !capture.active);
    puts("PASS: cancellation commit with failed projection readback is explicit and safely retryable without a new run");
}

static void checkCommandIdentity(NSString *root) {
    SRStore *store = [[SRStore alloc] initWithPath:[root stringByAppendingPathComponent:@"command-identity.sqlite3"] error:NULL]; CHECK(store);
    CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
    CHECK([store saveConfiguration:configuration() account:@"other" error:NULL]);
    CHECK([store setOperationsEnabled:YES account:@"account" error:NULL]);
    ExecutionPort *execution = [ExecutionPort new]; execution.store = store;
    CapturePort *capture = [CapturePort new];
    __block NSString *account = @"account"; __block double now = 500.2;
    SRRelayCoordinator *coordinator = [[SRRelayCoordinator alloc] initWithStore:store execution:execution capture:capture
        currentAccount:^NSString *{ return account; } clock:^double { return now; }];
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]); now = 502;
    CHECK([coordinator.snapshot[@"account"] isEqual:account]);
    CHECK([coordinator acceptPreparedEnvelope:source(@"identity-first") generation:capture.generation createdAt:501 receivedAt:502 error:NULL]);
    NSString *content = displayedContent(coordinator);
    NSArray *groups = [coordinator prepareGroupsForContent:content account:account error:NULL]; CHECK(groups.count == 2);
    CHECK([coordinator startGroup:groups[0][@"id"] content:content account:account error:NULL]);
    NSString *firstRun = execution.run;
    NSDictionary *running = coordinator.snapshot;
    NSUInteger pauses = execution.pauses;
    CHECK(![coordinator setEnabled:NO account:@"other" error:NULL]);
    CHECK(![coordinator configurationSavedForAccount:@"other" error:NULL]);
    CHECK(![coordinator prepareGroupsForContent:content account:@"other" error:NULL]);
    CHECK(![coordinator startGroup:groups[1][@"id"] content:content account:@"other" error:NULL]);
    CHECK(![coordinator pauseRun:firstRun account:@"other" error:NULL]);
    CHECK(![coordinator resumeRun:firstRun account:@"other" error:NULL]);
    CHECK(![coordinator cancelRun:firstRun account:@"other" error:NULL]);
    CHECK(![coordinator recoverLegacyRun:firstRun account:@"other" error:NULL]);
    CHECK(![coordinator finishContent:content account:@"other" error:NULL]);
    CHECK([coordinator.snapshot isEqual:running] && execution.pauses == pauses);
    CHECK(execution.starts == 1 && execution.resumes == 0 && execution.cancels == 0);

    CHECK([coordinator cancelRun:firstRun account:account error:NULL]);
    CHECK([coordinator startGroup:groups[1][@"id"] content:content account:account error:NULL]);
    NSString *secondRun = execution.run;
    CHECK(![secondRun isEqual:firstRun]); running = coordinator.snapshot;
    pauses = execution.pauses;
    NSError *error = nil;
    CHECK(![coordinator cancelRun:firstRun account:account error:&error] && error);
    CHECK(![coordinator pauseRun:firstRun account:account error:NULL]);
    CHECK(![coordinator resumeRun:firstRun account:account error:NULL]);
    CHECK([coordinator.snapshot isEqual:running] && execution.pauses == pauses);
    CHECK([[store summaryForRun:secondRun error:NULL][@"state"] isEqual:@"running"]);
    CHECK(count(store, secondRun, @"pending") == 1 && execution.cancels == 1);
    CHECK([coordinator pauseRun:secondRun account:account error:NULL]);
    CHECK(![coordinator resumeRun:firstRun account:account error:NULL] && execution.resumes == 0);
    CHECK([coordinator resumeRun:secondRun account:account error:NULL]);
    CHECK([coordinator cancelRun:secondRun account:account error:NULL]);
    CHECK([coordinator finishContent:content account:account error:NULL]);
    NSNumber *archivedAt = coordinator.snapshot[@"recent"][@"archived_at"];

    now = 504;
    CHECK([coordinator acceptPreparedEnvelope:source(@"identity-replacement") generation:capture.generation createdAt:503 receivedAt:504 error:NULL]);
    NSString *replacement = displayedContent(coordinator); CHECK(![replacement isEqual:content]);
    NSDictionary *ready = coordinator.snapshot;
    // A late duplicate confirmation succeeds only for its already archived ID.
    CHECK([coordinator finishContent:content account:account error:NULL]);
    CHECK(![coordinator finishContent:@"unknown-content" account:account error:NULL]);
    CHECK(![coordinator prepareGroupsForContent:content account:account error:NULL]);
    CHECK(![coordinator startGroup:groups[0][@"id"] content:content account:account error:NULL]);
    CHECK(![coordinator cancelRun:secondRun account:account error:NULL]);
    CHECK([coordinator.snapshot isEqual:ready]);
    CHECK([coordinator.snapshot[@"recent"][@"archived_at"] isEqual:archivedAt]);
    CHECK([store plansForAccount:account limit:10 offset:0 error:NULL].count == 1);
    CHECK(execution.starts == 2 && execution.resumes == 1 && execution.cancels == 2);

    account = @"other";
    // A delayed command from the old account must be rejected before reload
    // can enter the new account's safe-closed state or rewrite its preference.
    CHECK([store setOperationsEnabled:YES account:account error:NULL]);
    NSDictionary *beforeSwitchRefresh = coordinator.snapshot;
    pauses = execution.pauses;
    CHECK(![coordinator configurationSavedForAccount:@"account" error:NULL]);
    CHECK(![coordinator prepareGroupsForContent:replacement account:@"account" error:NULL]);
    CHECK(![coordinator startGroup:groups[0][@"id"] content:replacement account:@"account" error:NULL]);
    CHECK(![coordinator pauseRun:secondRun account:@"account" error:NULL]);
    CHECK(![coordinator resumeRun:secondRun account:@"account" error:NULL]);
    CHECK(![coordinator cancelRun:secondRun account:@"account" error:NULL]);
    CHECK(![coordinator recoverLegacyRun:secondRun account:@"account" error:NULL]);
    CHECK(![coordinator finishContent:replacement account:@"account" error:NULL]);
    CHECK([[store operationsEnabledForAccount:account error:NULL] boolValue]);
    CHECK(![coordinator setEnabled:NO account:@"account" error:NULL]);
    CHECK([[store operationsEnabledForAccount:account error:NULL] boolValue]);
    CHECK([coordinator.snapshot isEqual:beforeSwitchRefresh] && execution.pauses == pauses);
    CHECK(execution.starts == 2 && execution.resumes == 1 && execution.cancels == 2);
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    CHECK(![coordinator setEnabled:YES account:@"account" error:NULL]);
    CHECK(![[store operationsEnabledForAccount:account error:NULL] boolValue] && !capture.active);
    CHECK(![coordinator finishContent:replacement account:@"account" error:NULL]);
    CHECK([coordinator setEnabled:YES account:account error:NULL] && capture.active);
    CHECK(coordinator.snapshot[@"content"] == NSNull.null && coordinator.snapshot[@"recent"] == NSNull.null);
    CHECK([[store operationsContentForAccount:@"account" error:NULL][@"current"][@"id"] isEqual:replacement]);
    account = nil;
    CHECK(![coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    CHECK(coordinator.snapshot[@"account"] == NSNull.null);
    puts("PASS: account/content/run-bound commands reject stale pages and never retarget a late confirmation");
}

static void checkCaptureEventIdentity(NSString *root) {
    ReadFaultStore *store = [[ReadFaultStore alloc] initWithPath:[root stringByAppendingPathComponent:@"capture-identity.sqlite3"] error:NULL]; CHECK(store);
    CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
    CHECK([store saveConfiguration:configuration() account:@"other" error:NULL]);
    CHECK([store setOperationsEnabled:YES account:@"account" error:NULL]);
    CHECK([store setOperationsEnabled:YES account:@"other" error:NULL]);
    ExecutionPort *execution = [ExecutionPort new]; execution.store = store;
    CapturePort *capture = [CapturePort new];
    __block NSString *account = @"account"; __block double now = 1000.2; __block BOOL throwAccount = NO;
    SRRelayCoordinator *coordinator = [[SRRelayCoordinator alloc] initWithStore:store execution:execution capture:capture
        currentAccount:^NSString *{ if (throwAccount) @throw @"private account lookup failure"; return account; }
        clock:^double { return now; }];
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    uint64_t oldGeneration = capture.generation; NSDictionary *before = coordinator.snapshot;
    NSUInteger reads = store.contentReads, pauses = execution.pauses, starts = capture.starts;
    NSMutableDictionary *otherSource = [source(@"capture-identity") mutableCopy]; otherSource[@"account"] = @"other";
    now = 1002;
    CHECK(![coordinator acceptPreparedEnvelope:@{} generation:oldGeneration createdAt:1001 receivedAt:1002 error:NULL]);
    CHECK(![coordinator acceptPreparedEnvelope:otherSource generation:oldGeneration createdAt:1001 receivedAt:1002 error:NULL]);
    // Before lifecycle refresh, an old callback cannot safe-close the new account.
    account = @"other";
    CHECK(![coordinator acceptPreparedEnvelope:source(@"old-account") generation:oldGeneration createdAt:1001 receivedAt:1002 error:NULL]);
    CHECK([[store operationsEnabledForAccount:@"other" error:NULL] boolValue]);
    account = nil;
    CHECK(![coordinator acceptPreparedEnvelope:source(@"unavailable-account") generation:oldGeneration createdAt:1001 receivedAt:1002 error:NULL]);
    throwAccount = YES;
    NSError *error = nil;
    CHECK(![coordinator acceptPreparedEnvelope:source(@"throwing-account") generation:oldGeneration createdAt:1001 receivedAt:1002 error:&error] && error);
    CHECK(![error.localizedDescription containsString:@"private"]);
    throwAccount = NO;
    CHECK(store.contentReads == reads && execution.pauses == pauses && capture.starts == starts);
    CHECK([coordinator.snapshot isEqual:before] && capture.active);

    account = @"other";
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    CHECK(![[store operationsEnabledForAccount:account error:NULL] boolValue] && !capture.active);
    CHECK([coordinator setEnabled:YES account:account error:NULL] && capture.active);
    CHECK(capture.generation != oldGeneration);
    before = coordinator.snapshot; reads = store.contentReads; pauses = execution.pauses; starts = capture.starts;
    store.failContentRead = YES;
    CHECK(![coordinator acceptPreparedEnvelope:source(@"old-token") generation:oldGeneration createdAt:1001 receivedAt:1002 error:NULL]);
    CHECK(![coordinator acceptPreparedEnvelope:otherSource generation:oldGeneration createdAt:1001 receivedAt:1002 error:NULL]);
    CHECK(![coordinator acceptPreparedEnvelope:source(@"wrong-owner") generation:capture.generation createdAt:1001 receivedAt:1002 error:NULL]);
    CHECK(store.contentReads == reads && execution.pauses == pauses && capture.starts == starts);
    CHECK([coordinator.snapshot isEqual:before] && capture.active);
    store.failContentRead = NO;

    // The precheck does not replace reload's saved-configuration validation.
    NSMutableDictionary *updated = configuration(); updated[@"minimum"] = @6;
    CHECK([store saveConfiguration:updated account:account error:NULL]);
    uint64_t priorConfiguration = capture.generation; now = 1004;
    CHECK(![coordinator acceptPreparedEnvelope:otherSource generation:priorConfiguration createdAt:1003 receivedAt:1004 error:NULL]);
    CHECK(capture.active && capture.generation != priorConfiguration && coordinator.snapshot[@"content"] == NSNull.null);
    now = 1006;
    CHECK([coordinator acceptPreparedEnvelope:otherSource generation:capture.generation createdAt:1005 receivedAt:1006 error:NULL]);
    CHECK([coordinator.snapshot[@"content"][@"configuration"][@"minimum"] isEqual:@6]);
    CHECK([coordinator.snapshot[@"content"][@"envelope"][@"account"] isEqual:account]);
    CHECK([store operationsContentForAccount:@"account" error:NULL][@"current"] == NSNull.null);
    CHECK(execution.starts == 0 && execution.resumes == 0 && execution.cancels == 0);
    puts("PASS: stale capture account/token preflight has no lifecycle side effects and saved configuration is still revalidated");
}

static void checkRunProjectionOrder(NSString *root) {
    NSString *path = [root stringByAppendingPathComponent:@"run-projection-order.sqlite3"];
    SRStore *store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
    CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
    CHECK([store setOperationsEnabled:YES account:@"account" error:NULL]);
    ExecutionPort *execution = [ExecutionPort new]; execution.store = store;
    CapturePort *capture = [CapturePort new]; __block double now = 800.2;
    SRRelayCoordinator *coordinator = [[SRRelayCoordinator alloc] initWithStore:store execution:execution capture:capture
        currentAccount:^NSString *{ return @"account"; } clock:^double { return now; }];
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]); now = 802;
    CHECK([coordinator acceptPreparedEnvelope:source(@"run-projection-order") generation:capture.generation createdAt:801 receivedAt:802 error:NULL]);
    NSString *content = displayedContent(coordinator);
    NSArray *groups = [coordinator prepareGroupsForContent:content account:@"account" error:NULL]; CHECK(groups.count == 2);
    CHECK([coordinator startGroup:groups[0][@"id"] content:content account:@"account" error:NULL]);
    NSString *firstRun = execution.run;
    CHECK([coordinator cancelRun:firstRun account:@"account" error:NULL]);
    CHECK([coordinator startGroup:groups[1][@"id"] content:content account:@"account" error:NULL]);
    NSString *secondRun = execution.run;
    CHECK([coordinator cancelRun:secondRun account:@"account" error:NULL]);
    NSNumber *firstEnded = [store summaryForRun:firstRun error:NULL][@"ended_at"];
    NSNumber *secondEnded = [store summaryForRun:secondRun error:NULL][@"ended_at"];
    NSDictionary *cancellation = [store operationsCancellationForRun:secondRun account:@"account" error:NULL];
    sqlite3 *database = NULL; CHECK(sqlite3_open(path.fileSystemRepresentation, &database) == SQLITE_OK);
    for (NSArray *times in @[@[@1000, @100], @[@100, @100]]) {
        sqlite3_stmt *update = NULL;
        CHECK(sqlite3_prepare_v2(database, "UPDATE runs SET started_at=CASE WHEN id=? THEN ? ELSE ? END", -1, &update, NULL) == SQLITE_OK);
        CHECK(sqlite3_bind_text(update, 1, firstRun.UTF8String, -1, SQLITE_TRANSIENT) == SQLITE_OK);
        CHECK(sqlite3_bind_double(update, 2, [times[0] doubleValue]) == SQLITE_OK);
        CHECK(sqlite3_bind_double(update, 3, [times[1] doubleValue]) == SQLITE_OK);
        CHECK(sqlite3_step(update) == SQLITE_DONE && sqlite3_finalize(update) == SQLITE_OK);
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK([displayedRun(coordinator) isEqual:secondRun] && [coordinator.snapshot[@"phase"] integerValue] == SROpsGroupCancelled);
        CHECK([coordinator.snapshot[@"run"][@"counts"][@"cancelled"] isEqual:@1]);
        NSArray *cards = coordinator.snapshot[@"groups"];
        CHECK([cards[1][@"latestRun"][@"creationOrder"] longLongValue] > [cards[0][@"latestRun"][@"creationOrder"] longLongValue]);
        CHECK([[store historyForRule:groups[1][@"id"] account:@"account" limit:1 offset:0 error:NULL][0][@"creationOrder"]
            isEqual:cards[1][@"latestRun"][@"creationOrder"]]);
        CHECK([[store summaryForRun:firstRun error:NULL][@"started_at"] isEqual:times[0]]);
        CHECK([[store summaryForRun:secondRun error:NULL][@"started_at"] isEqual:times[1]]);
        CHECK([[store summaryForRun:firstRun error:NULL][@"ended_at"] isEqual:firstEnded]);
        CHECK([[store summaryForRun:secondRun error:NULL][@"ended_at"] isEqual:secondEnded]);
        CHECK([[store operationsCancellationForRun:secondRun account:@"account" error:NULL] isEqual:cancellation]);
    }
    CHECK(sqlite3_close(database) == SQLITE_OK);
    SRStore *reopened = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(reopened);
    ExecutionPort *restoredExecution = [ExecutionPort new]; restoredExecution.store = reopened;
    coordinator = [[SRRelayCoordinator alloc] initWithStore:reopened execution:restoredExecution capture:[CapturePort new]
        currentAccount:^NSString *{ return @"account"; } clock:^double { return now; }];
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    CHECK([displayedRun(coordinator) isEqual:secondRun] && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
    CHECK(execution.starts == 2 && execution.resumes == 0 && restoredExecution.starts == 0 && restoredExecution.resumes == 0);
    puts("PASS: terminal run projection follows persisted creation order after clock rollback, equal timestamps and reopen");
}

static void checkArchiveReadback(NSString *root) {
    ReadFaultStore *store = [[ReadFaultStore alloc] initWithPath:[root stringByAppendingPathComponent:@"archive-readback.sqlite3"] error:NULL]; CHECK(store);
    CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
    CHECK([store setOperationsEnabled:YES account:@"account" error:NULL]);
    ExecutionPort *execution = [ExecutionPort new]; execution.store = store;
    CapturePort *capture = [CapturePort new]; __block double now = 600.2;
    SRRelayCoordinator *coordinator = [[SRRelayCoordinator alloc] initWithStore:store execution:execution capture:capture
        currentAccount:^NSString *{ return @"account"; } clock:^double { return now; }];
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]); now = 602;
    CHECK([coordinator acceptPreparedEnvelope:source(@"archive-readback") generation:capture.generation createdAt:601 receivedAt:602 error:NULL]);
    NSString *content = displayedContent(coordinator);
    NSArray *groups = [coordinator prepareGroupsForContent:content account:@"account" error:NULL]; CHECK(groups.count == 2);
    CHECK([coordinator startGroup:groups[0][@"id"] content:content account:@"account" error:NULL]);
    NSString *run = execution.run;
    CHECK([coordinator cancelRun:run account:@"account" error:NULL]);
    NSDictionary *cancellation = [store operationsCancellationForRun:run account:@"account" error:NULL];
    __weak ReadFaultStore *weakStore = store;
    store.afterArchive = ^{ weakStore.failContentRead = YES; };
    NSError *error = nil;
    CHECK(![coordinator finishContent:content account:@"account" error:&error] && error);
    CHECK(![coordinator.snapshot[@"stateLoaded"] boolValue] && !capture.active);
    store.afterArchive = nil; store.failContentRead = NO;
    NSDictionary *saved = [store operationsContentForAccount:@"account" error:NULL];
    CHECK(saved[@"current"] == NSNull.null && [saved[@"recent"][@"id"] isEqual:content]);
    NSNumber *archivedAt = saved[@"recent"][@"archived_at"];
    CHECK([coordinator finishContent:content account:@"account" error:NULL]);
    CHECK([coordinator finishContent:content account:@"account" error:NULL]);
    CHECK([coordinator.snapshot[@"stateLoaded"] boolValue] && coordinator.snapshot[@"content"] == NSNull.null);
    CHECK([coordinator.snapshot[@"recent"][@"archived_at"] isEqual:archivedAt] && store.archives == 1);
    CHECK([coordinator.snapshot[@"problem"] length] > 0 && !capture.active);
    CHECK([[store operationsCancellationForRun:run account:@"account" error:NULL] isEqual:cancellation]);
    CHECK(count(store, run, @"cancelled") == 2 && execution.starts == 1 && execution.resumes == 0);
    CHECK([store plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 1);
    CHECK([coordinator setEnabled:YES account:@"account" error:NULL] && capture.active);
    now = 604;
    CHECK([coordinator acceptPreparedEnvelope:source(@"archive-replacement") generation:capture.generation createdAt:603 receivedAt:604 error:NULL]);
    NSString *replacement = displayedContent(coordinator);
    CHECK([coordinator finishContent:content account:@"account" error:NULL]);
    CHECK([displayedContent(coordinator) isEqual:replacement] && store.archives == 1);
    puts("PASS: committed archive readback failure retries the original ID without rewriting dates or archiving a replacement");
}

static void checkArchiveProjectionOrder(NSString *root) {
    NSString *path = [root stringByAppendingPathComponent:@"archive-projection-order.sqlite3"];
    ReadFaultStore *store = [[ReadFaultStore alloc] initWithPath:path error:NULL]; CHECK(store);
    CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
    CHECK([store setOperationsEnabled:YES account:@"account" error:NULL]);
    ExecutionPort *execution = [ExecutionPort new]; execution.store = store;
    CapturePort *capture = [CapturePort new]; __block double now = 900.2;
    SRRelayCoordinator *coordinator = [[SRRelayCoordinator alloc] initWithStore:store execution:execution capture:capture
        currentAccount:^NSString *{ return @"account"; } clock:^double { return now; }];
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]); now = 902;
    CHECK([coordinator acceptPreparedEnvelope:source(@"archive-order-first") generation:capture.generation createdAt:901 receivedAt:902 error:NULL]);
    NSString *first = displayedContent(coordinator);
    CHECK([coordinator finishContent:first account:@"account" error:NULL] && capture.active);
    sqlite3 *database = NULL; CHECK(sqlite3_open(path.fileSystemRepresentation, &database) == SQLITE_OK);
    CHECK(sqlite3_exec(database, "UPDATE operations_contents SET archived_at=4000000000 WHERE message_id='archive-order-first'", NULL, NULL, NULL) == SQLITE_OK);
    now = 904;
    CHECK([coordinator acceptPreparedEnvelope:source(@"archive-order-second") generation:capture.generation createdAt:903 receivedAt:904 error:NULL]);
    NSString *second = displayedContent(coordinator);
    NSArray *groups = [coordinator prepareGroupsForContent:second account:@"account" error:NULL]; CHECK(groups.count == 2);
    CHECK([coordinator startGroup:groups[0][@"id"] content:second account:@"account" error:NULL]);
    NSString *run = execution.run;
    CHECK([coordinator cancelRun:run account:@"account" error:NULL]);
    NSDictionary *cancellation = [store operationsCancellationForRun:run account:@"account" error:NULL];
    __weak ReadFaultStore *weakStore = store;
    store.afterArchive = ^{ weakStore.failContentRead = YES; };
    NSError *error = nil;
    CHECK(![coordinator finishContent:second account:@"account" error:&error] && error);
    CHECK(![coordinator.snapshot[@"stateLoaded"] boolValue] && !capture.active);
    store.afterArchive = nil; store.failContentRead = NO;
    NSDictionary *saved = [store operationsContentForAccount:@"account" error:NULL];
    CHECK(saved[@"current"] == NSNull.null && [saved[@"recent"][@"id"] isEqual:second]);
    NSNumber *archivedAt = saved[@"recent"][@"archived_at"];
    CHECK([coordinator finishContent:second account:@"account" error:NULL]);
    CHECK([coordinator.snapshot[@"recent"][@"archived_at"] isEqual:archivedAt] && store.archives == 2);
    // A same-time archive is ordered by occupancy too, without rewriting dates.
    for (NSArray *times in @[@[@1000, @100], @[@100, @100]]) {
        sqlite3_stmt *update = NULL;
        CHECK(sqlite3_prepare_v2(database, "UPDATE operations_contents SET archived_at=CASE WHEN id=? THEN ? ELSE ? END", -1, &update, NULL) == SQLITE_OK);
        CHECK(sqlite3_bind_text(update, 1, first.UTF8String, -1, SQLITE_TRANSIENT) == SQLITE_OK);
        CHECK(sqlite3_bind_double(update, 2, [times[0] doubleValue]) == SQLITE_OK);
        CHECK(sqlite3_bind_double(update, 3, [times[1] doubleValue]) == SQLITE_OK);
        CHECK(sqlite3_step(update) == SQLITE_DONE && sqlite3_finalize(update) == SQLITE_OK);
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK([coordinator.snapshot[@"recent"][@"id"] isEqual:second]);
        CHECK([coordinator.snapshot[@"recent"][@"archived_at"] isEqual:times[1]]);
        CHECK([coordinator finishContent:second account:@"account" error:NULL] && store.archives == 2);
        CHECK(![coordinator finishContent:first account:@"account" error:NULL]);
        CHECK([[store operationsCancellationForRun:run account:@"account" error:NULL] isEqual:cancellation]);
        CHECK(count(store, run, @"cancelled") == 2 && !capture.active);
    }
    CHECK(sqlite3_close(database) == SQLITE_OK);
    SRStore *reopened = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(reopened);
    ExecutionPort *restoredExecution = [ExecutionPort new]; restoredExecution.store = reopened;
    capture = [CapturePort new];
    coordinator = [[SRRelayCoordinator alloc] initWithStore:reopened execution:restoredExecution capture:capture
        currentAccount:^NSString *{ return @"account"; } clock:^double { return now; }];
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL] && capture.active);
    CHECK([coordinator.snapshot[@"phase"] integerValue] == SROpsContentCompleted);
    CHECK([coordinator.snapshot[@"recent"][@"id"] isEqual:second] && [coordinator.snapshot[@"recent"][@"archived_at"] isEqual:@100]);
    now = 906;
    CHECK([coordinator acceptPreparedEnvelope:source(@"archive-order-current") generation:capture.generation createdAt:905 receivedAt:906 error:NULL]);
    NSString *current = displayedContent(coordinator);
    CHECK([coordinator finishContent:second account:@"account" error:NULL]);
    CHECK(![coordinator finishContent:first account:@"account" error:NULL]);
    CHECK([displayedContent(coordinator) isEqual:current]);
    CHECK([coordinator.snapshot[@"recent"][@"archived_at"] isEqual:@100] && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
    CHECK(execution.starts == 1 && execution.resumes == 0 && restoredExecution.starts == 0 && restoredExecution.resumes == 0);
    CHECK([[reopened operationsCancellationForRun:run account:@"account" error:NULL] isEqual:cancellation]);
    puts("PASS: recent archive and original-ID retries survive clock rollback, readback failure, equal timestamps and reopen");
}

/* A frozen library task owns its run. That run must occupy its own account in
 * the coordinator (no arming, no "idle") without being projected as legacy
 * content, and must never leak into another account. */
static void checkLibraryOccupancyGate(NSString *root) {
    NSString *path = [root stringByAppendingPathComponent:@"library-occupancy.sqlite3"];
    SRStore *store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
    CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
    CHECK([store setOperationsEnabled:YES account:@"account" error:NULL]);
    ExecutionPort *execution = [ExecutionPort new]; execution.store = store;
    CapturePort *capture = [CapturePort new]; __block double now = 1200.2;
    // The factory takes its store, execution port and capture recorder as
    // arguments, so a "restart" can build a coordinator bound to the reopened
    // database instead of silently reusing the first one.
    SRRelayCoordinator *(^makeCoordinator)(SRStore *, ExecutionPort *, CapturePort *) =
        ^SRRelayCoordinator *(SRStore *bound, ExecutionPort *port, CapturePort *recorder) {
        return [[SRRelayCoordinator alloc] initWithStore:bound execution:port capture:recorder
            currentAccount:^NSString *{ return @"account"; } clock:^double { return now; }];
    };
    SRRelayCoordinator *coordinator = makeCoordinator(store, execution, capture);
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    CHECK(capture.active && [coordinator.snapshot[@"captureAllowed"] boolValue]);
    CHECK(coordinator.snapshot[@"libraryTask"] == NSNull.null);

    // Another account's frozen task is not this account's occupancy.
    NSString *otherItem = [store createLibraryItemForAccount:@"other" kind:@"text"
        payload:@{@"text": @"other body"} capturedAt:100 error:NULL]; CHECK(otherItem);
    NSString *otherTask = [store createLibraryTaskForAccount:@"other" item:otherItem version:nil
        confirmationID:@"other-confirm" targets:@[@"x@chatroom"] minimum:5 maximum:10 error:NULL];
    CHECK(otherTask && [store startLibraryTask:otherTask account:@"other" error:NULL]);
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    CHECK(capture.active && [coordinator.snapshot[@"captureAllowed"] boolValue]);
    CHECK(coordinator.snapshot[@"libraryTask"] == NSNull.null && [coordinator.snapshot[@"captureState"] isEqual:@"waiting"]);
    CHECK(execution.starts == 0 && execution.resumes == 0);

    // This account's frozen task starts: capture is stopped and never re-armed,
    // and the snapshot says occupied instead of idle or legacy.
    NSString *item = [store createLibraryItemForAccount:@"account" kind:@"text"
        payload:@{@"text": @"library body"} capturedAt:100 error:NULL]; CHECK(item);
    NSString *task = [store createLibraryTaskForAccount:@"account" item:item version:nil
        confirmationID:@"confirm-library" targets:@[@"a@chatroom", @"b@chatroom"] minimum:5 maximum:10 error:NULL];
    CHECK(task);
    NSString *run = [store startLibraryTask:task account:@"account" error:NULL]; CHECK(run);
    NSUInteger arms = capture.starts;
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    CHECK(!capture.active && capture.starts == arms);
    CHECK(![coordinator.snapshot[@"captureAllowed"] boolValue]);
    CHECK([coordinator.snapshot[@"captureState"] isEqual:@"library_occupied"]);
    CHECK([coordinator.snapshot[@"libraryTask"][@"taskID"] isEqual:task]);
    CHECK([coordinator.snapshot[@"libraryTask"][@"runID"] isEqual:run]);
    CHECK(coordinator.snapshot[@"legacyRun"] == NSNull.null);
    CHECK(coordinator.snapshot[@"content"] == NSNull.null);
    CHECK(![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
    // Enabling again cannot turn the occupancy into a capture window.
    CHECK([coordinator setEnabled:YES account:@"account" error:NULL]);
    CHECK(!capture.active && capture.starts == arms);
    // A delivery event cannot create content for the occupied account, even
    // with the current capture token and a fresh receipt time.
    now = 1204;
    CHECK(![coordinator acceptPreparedEnvelope:source(@"while-library-busy")
        generation:[coordinator.snapshot[@"generation"] unsignedLongLongValue]
        createdAt:1201 receivedAt:1204 error:NULL]);
    CHECK(coordinator.snapshot[@"content"] == NSNull.null);

    // A restart still sees the occupancy and still does not arm or resume. The
    // reopened database gets its own execution port and capture recorder, so
    // occupancy is proven on the new store rather than read from it.
    SRStore *reopened = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(reopened);
    CHECK([[reopened operationsContentForAccount:@"account" error:NULL][@"libraryOccupancy"][@"taskID"] isEqual:task]);
    ExecutionPort *restoredExecution = [ExecutionPort new]; restoredExecution.store = reopened;
    CapturePort *restoredCapture = [CapturePort new];
    coordinator = makeCoordinator(reopened, restoredExecution, restoredCapture);
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    CHECK(!restoredCapture.active && restoredCapture.starts == 0);
    CHECK(restoredExecution.starts == 0 && restoredExecution.resumes == 0);
    CHECK([coordinator.snapshot[@"libraryTask"][@"runID"] isEqual:run] && ![coordinator.snapshot[@"captureAllowed"] boolValue]);
    CHECK([coordinator.snapshot[@"captureState"] isEqual:@"library_occupied"]);
    CHECK(coordinator.snapshot[@"content"] == NSNull.null && coordinator.snapshot[@"legacyRun"] == NSNull.null);
    CHECK([[reopened summaryForRun:run error:NULL][@"state"] isEqual:@"awaiting_resume"]);

    // Only the reopened database is mutated from here on: cancel, read-back and
    // release are all observed through it.
    CHECK([reopened cancelOperationsRun:run account:@"account" error:NULL]);
    now = 1206;
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    CHECK(restoredCapture.active && [coordinator.snapshot[@"captureAllowed"] boolValue]);
    CHECK(coordinator.snapshot[@"libraryTask"] == NSNull.null && [coordinator.snapshot[@"captureState"] isEqual:@"waiting"]);
    CHECK([[reopened libraryTask:task account:@"account" error:NULL][@"runID"] isEqual:run]);
    CHECK([[reopened summaryForRun:run error:NULL][@"state"] isEqual:@"ended"]);
    // The released account captures normally again; the other account is untouched.
    now = 1208;
    CHECK([coordinator acceptPreparedEnvelope:source(@"after-library-release") generation:restoredCapture.generation
        createdAt:1207 receivedAt:1208 error:NULL]);
    CHECK([displayedContent(coordinator) length] > 0);
    CHECK([[reopened summaryForRun:[reopened libraryTask:otherTask account:@"other" error:NULL][@"runID"] error:NULL][@"state"] isEqual:@"awaiting_resume"]);
    puts("PASS: a frozen library run occupies only its own account, is never armed, survives restart and releases on cancel");
}

static void checkSilentFailureDiagnostic(NSString *root) {
    SRStore *store = [[SRStore alloc] initWithPath:[root stringByAppendingPathComponent:@"silent-failure.sqlite3"] error:NULL]; CHECK(store);
    CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
    CHECK([store setOperationsEnabled:YES account:@"account" error:NULL]);
    ExecutionPort *execution = [ExecutionPort new]; execution.store = store; execution.silentStartFailure = YES;
    CapturePort *capture = [CapturePort new]; __block double now = 700.2;
    SRRelayCoordinator *coordinator = [[SRRelayCoordinator alloc] initWithStore:store execution:execution capture:capture
        currentAccount:^NSString *{ return @"account"; } clock:^double { return now; }];
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]); now = 702;
    CHECK([coordinator acceptPreparedEnvelope:source(@"silent-failure") generation:capture.generation createdAt:701 receivedAt:702 error:NULL]);
    NSString *content = displayedContent(coordinator);
    NSArray *groups = [coordinator prepareGroupsForContent:content account:@"account" error:NULL]; CHECK(groups.count == 2);
    NSArray *beforeDiagnostics = SRRuntimeLog.shared.snapshot[@"events"];
    unsigned long long diagnosticsBefore = [beforeDiagnostics.lastObject[@"sequence"] unsignedLongLongValue];
    NSError *error = nil;
    CHECK(![coordinator startGroup:groups[0][@"id"] content:content account:@"account" error:&error] && error);
    CHECK([coordinator.snapshot[@"problem"] length] > 0 && execution.run == nil);
    BOOL sawFault = NO;
    for (NSDictionary *row in SRRuntimeLog.shared.snapshot[@"events"])
        if ([row[@"sequence"] unsignedLongLongValue] > diagnosticsBefore && [row[@"event"] isEqual:@"operations_fault"]) { sawFault = YES; break; }
    CHECK(sawFault);
    execution.silentStartFailure = NO;
    CHECK([coordinator startGroup:groups[0][@"id"] content:content account:@"account" error:NULL]);
    CHECK(execution.starts == 2);
    puts("PASS: silent execution failure is classified as a fault without losing the frozen plan");
}

static void checkDeferredLifecycleDispatch(NSString *root) {
    for (NSString *mode in @[@"foreground", @"background-foreground", @"source-revalidation"]) {
        NSString *path = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"deferred-%@.sqlite3", mode]];
        SRStore *store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
        CHECK([store setOperationsEnabled:YES account:@"account" error:NULL]);
        ExecutionPort *execution = [ExecutionPort new]; execution.store = store;
        CapturePort *capture = [CapturePort new]; __block double now = 1100.2;
        SRRelayCoordinator *coordinator = [[SRRelayCoordinator alloc] initWithStore:store execution:execution capture:capture
            currentAccount:^NSString *{ return @"account"; } clock:^double { return now; }];
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]); now = 1102;
        CHECK([coordinator acceptPreparedEnvelope:source([@"deferred-" stringByAppendingString:mode]) generation:capture.generation
            createdAt:1101 receivedAt:1102 error:NULL]);
        NSString *content = displayedContent(coordinator);
        NSArray *groups = [coordinator prepareGroupsForContent:content account:@"account" error:NULL]; CHECK(groups.count == 2);
        __weak SRRelayCoordinator *weak = coordinator;
        void (^reenter)(void) = ^{
            if ([mode isEqual:@"background-foreground"])
                CHECK(![weak refreshForeground:NO sourceTimeVerified:YES error:NULL]);
            if ([mode isEqual:@"source-revalidation"])
                CHECK(![weak refreshForeground:YES sourceTimeVerified:NO error:NULL]);
            CHECK(![weak refreshForeground:YES sourceTimeVerified:YES error:NULL]);
            CHECK(![weak.snapshot[@"dispatchAllowed"] boolValue]);
        };
        execution.duringStart = reenter;
        NSUInteger pauses = execution.pauses; NSError *error = nil;
        CHECK(![coordinator startGroup:groups[0][@"id"] content:content account:@"account" error:&error] && error);
        NSString *run = execution.run; CHECK(run);
        CHECK([[store summaryForRun:run error:NULL][@"state"] isEqual:@"paused"]);
        CHECK(execution.pauses == pauses + 1 && execution.starts == 1 && execution.resumes == 0);
        CHECK([coordinator.snapshot[@"phase"] integerValue] == SROpsPaused);
        CHECK([coordinator.snapshot[@"stateLoaded"] boolValue] && [coordinator.snapshot[@"visible"] boolValue]);
        CHECK([coordinator.snapshot[@"enabled"] boolValue] && ![coordinator.snapshot[@"dispatchAllowed"] boolValue] && !capture.active);
        CHECK([displayedRun(coordinator) isEqual:run] && [displayedContent(coordinator) isEqual:content]);
        CHECK(count(store, run, @"pending") == 2 && count(store, run, @"submitting") == 0);
        execution.duringStart = nil;
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK(execution.resumes == 0 && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        // A single normal deferral needs manual continuation, not re-enabling.
        CHECK([coordinator resumeRun:run account:@"account" error:NULL]);
        CHECK(execution.resumes == 1 && [coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([coordinator pauseRun:run account:@"account" error:NULL]);

        execution.duringResume = reenter; pauses = execution.pauses; error = nil;
        CHECK(![coordinator resumeRun:run account:@"account" error:&error] && error);
        CHECK([[store summaryForRun:run error:NULL][@"state"] isEqual:@"paused"]);
        CHECK(execution.pauses == pauses + 1 && execution.resumes == 2);
        CHECK([coordinator.snapshot[@"phase"] integerValue] == SROpsPaused && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK(count(store, run, @"pending") == 2 && count(store, run, @"submitting") == 0);
        CHECK([store historyForRule:groups[0][@"id"] account:@"account" limit:10 offset:0 error:NULL].count == 1);
        CHECK([store plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 1);
        execution.duringResume = nil;
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK(execution.resumes == 2 && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([coordinator resumeRun:run account:@"account" error:NULL]);
        CHECK(execution.resumes == 3 && [coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([coordinator cancelRun:run account:@"account" error:NULL]);
        CHECK(count(store, run, @"cancelled") == 2 && [coordinator.snapshot[@"enabled"] boolValue]);
        CHECK([coordinator finishContent:content account:@"account" error:NULL] && capture.active);
        CHECK(execution.starts == 1 && execution.resumes == 3);
    }
    puts("PASS: same-account deferred lifecycle pauses start/resume even when final foreground and source capability are restored");
}

static void checkFaultRevokesManualLease(NSString *root) {
    for (NSNumber *reject in @[@NO, @YES]) for (NSNumber *inflight in @[@NO, @YES]) {
        NSString *identifier = [NSString stringWithFormat:@"fault-lease-%@-%@", reject, inflight];
        NSString *path = [root stringByAppendingPathComponent:[identifier stringByAppendingString:@".sqlite3"]];
        ReadFaultStore *store = [[ReadFaultStore alloc] initWithPath:path error:NULL]; CHECK(store);
        CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
        CHECK([store setOperationsEnabled:YES account:@"account" error:NULL]);
        ExecutionPort *execution = [ExecutionPort new]; execution.store = store;
        CapturePort *capture = [CapturePort new]; __block double now = 1200.2;
        SRRelayCoordinator *coordinator = [[SRRelayCoordinator alloc] initWithStore:store execution:execution capture:capture
            currentAccount:^NSString *{ return @"account"; } clock:^double { return now; }];
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]); now = 1202;
        CHECK([coordinator acceptPreparedEnvelope:source(identifier) generation:capture.generation createdAt:1201 receivedAt:1202 error:NULL]);
        NSString *content = displayedContent(coordinator);
        NSArray *groups = [coordinator prepareGroupsForContent:content account:@"account" error:NULL]; CHECK(groups.count == 2);
        CHECK([coordinator startGroup:groups[0][@"id"] content:content account:@"account" error:NULL]);
        NSString *run = execution.run; NSDictionary *delivery = nil;
        if (inflight.boolValue) {
            delivery = [store claimNextForRun:run error:NULL]; CHECK(delivery);
            CHECK([store claimSmallGroupDelivery:delivery source:source(identifier) account:@"account" error:NULL]);
        }
        NSDictionary *before = [store summaryForRun:run error:NULL];
        CHECK([coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        execution.liePause = !reject.boolValue; execution.rejectPause = reject.boolValue;
        store.failContentRead = YES; NSError *error = nil;
        CHECK(![coordinator refreshForeground:YES sourceTimeVerified:YES error:&error] && error);
        CHECK(![coordinator.snapshot[@"dispatchAllowed"] boolValue] && !capture.active);
        store.failContentRead = NO;
        // Re-enabling may clear a fault, but never restores the old manual lease.
        for (NSUInteger retry = 0; retry < 2; retry++) {
            NSUInteger pauses = execution.pauses; error = nil;
            CHECK(![coordinator setEnabled:YES account:@"account" error:&error] && error);
            CHECK(execution.pauses - pauses <= 3 && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
            CHECK([[store summaryForRun:run error:NULL] isEqual:before]);
            CHECK(execution.starts == 1 && execution.resumes == 0 && !capture.active);
        }
        execution.liePause = NO; execution.rejectPause = NO;
        CHECK([coordinator setEnabled:YES account:@"account" error:NULL]);
        CHECK([coordinator.snapshot[@"enabled"] boolValue] && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([[store summaryForRun:run error:NULL][@"state"] isEqual:@"paused"]);
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL] && execution.resumes == 0);
        CHECK(count(store, run, @"pending") == 2 - inflight.unsignedIntegerValue);
        if (delivery) {
            CHECK([coordinator.snapshot[@"phase"] integerValue] == SROpsDraining);
            CHECK(![coordinator resumeRun:run account:@"account" error:NULL] && execution.resumes == 0);
            CHECK(count(store, run, @"submitting") == 1);
            CHECK([store recordResultForDelivery:delivery[@"id"] attempt:delivery[@"attempt_id"] state:@"submitted" messageID:nil reason:nil error:NULL]);
            CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
            CHECK(count(store, run, @"submitted") == 1);
            CHECK(![store claimSmallGroupDelivery:delivery source:source(identifier) account:@"account" error:NULL]);
        }
        CHECK([coordinator.snapshot[@"phase"] integerValue] == SROpsPaused);
        CHECK(![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([coordinator resumeRun:run account:@"account" error:NULL]);
        CHECK(execution.resumes == 1 && [coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([displayedRun(coordinator) isEqual:run] && [displayedContent(coordinator) isEqual:content]);
        CHECK(count(store, run, @"pending") == 2 - inflight.unsignedIntegerValue);
        CHECK([store historyForRule:groups[0][@"id"] account:@"account" limit:10 offset:0 error:NULL].count == 1);
        CHECK([store plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 1);
        CHECK([coordinator cancelRun:run account:@"account" error:NULL]);
        CHECK([coordinator finishContent:content account:@"account" error:NULL] && capture.active);
        if (delivery) {
            sqlite3 *db = NULL; sqlite3_stmt *claim = NULL;
            CHECK(sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK);
            CHECK(sqlite3_prepare_v2(db, "SELECT delivery_id,attempt_id FROM native_attempt_claims", -1, &claim, NULL) == SQLITE_OK);
            CHECK(sqlite3_step(claim) == SQLITE_ROW);
            CHECK([[NSString stringWithUTF8String:(const char *)sqlite3_column_text(claim, 0)] isEqual:delivery[@"id"]]);
            CHECK([[NSString stringWithUTF8String:(const char *)sqlite3_column_text(claim, 1)] isEqual:delivery[@"attempt_id"]]);
            CHECK(sqlite3_step(claim) == SQLITE_DONE);
            sqlite3_finalize(claim); CHECK(sqlite3_close(db) == SQLITE_OK);
        }
    }
    puts("PASS: faults revoke manual leases; re-enabling cannot bypass a rejected or unpersisted pause, including in-flight receipts");
}

static void checkPortBoundaries(NSString *root) {
    SRStore *store = [[SRStore alloc] initWithPath:[root stringByAppendingPathComponent:@"ports.sqlite3"] error:NULL]; CHECK(store);
    CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
    CHECK([store saveConfiguration:configuration() account:@"other" error:NULL]);
    CHECK([store setOperationsEnabled:YES account:@"account" error:NULL]);
    ExecutionPort *execution = [ExecutionPort new]; execution.store = store;
    CapturePort *capture = [CapturePort new];
    __block NSString *account = @"account"; __block double now = 200.2;
    SRRelayCoordinator *coordinator = [[SRRelayCoordinator alloc] initWithStore:store execution:execution capture:capture
        currentAccount:^NSString *{ return account; } clock:^double{ return now; }];
    __weak SRRelayCoordinator *weak = coordinator;
    __weak CapturePort *weakCapture = capture;
    capture.duringArm = ^{
        CHECK(![weak setEnabled:NO account:displayedAccount(weak) error:NULL]);
        CHECK(![weak configurationSavedForAccount:displayedAccount(weak) error:NULL]);
        CHECK(![weak acceptPreparedEnvelope:source(@"synchronous") generation:weakCapture.generation createdAt:201 receivedAt:202 error:NULL]);
        CHECK(![weak prepareGroupsForContent:displayedContent(weak) account:displayedAccount(weak) error:NULL] && ![weak finishContent:displayedContent(weak) account:displayedAccount(weak) error:NULL]);
    };
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    CHECK(capture.active && coordinator.snapshot[@"content"] == NSNull.null);
    capture.duringArm = nil;
    uint64_t stale = capture.generation;
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:NO error:NULL] && !capture.active);
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL] && capture.generation != stale);
    now = 202;
    CHECK(![coordinator acceptPreparedEnvelope:source(@"stale-trust") generation:stale createdAt:201 receivedAt:202 error:NULL]);

    CHECK([coordinator setEnabled:NO account:displayedAccount(coordinator) error:NULL]);
    capture.throwArm = YES; NSError *error = nil;
    CHECK(![coordinator setEnabled:YES account:displayedAccount(coordinator) error:&error]);
    CHECK(!capture.active && ![error.localizedDescription containsString:@"private"]);
    NSUInteger starts = capture.starts;
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    CHECK(capture.starts == starts && ![coordinator.snapshot[@"captureAllowed"] boolValue]);
    capture.throwArm = NO; CHECK([coordinator setEnabled:YES account:displayedAccount(coordinator) error:NULL]);
    stale = capture.generation; capture.throwStop = YES;
    CHECK(![coordinator setEnabled:NO account:displayedAccount(coordinator) error:NULL]);
    CHECK(![[store operationsEnabledForAccount:account error:NULL] boolValue] && ![coordinator.snapshot[@"listening"] boolValue]);
    capture.throwStop = NO; CHECK([coordinator setEnabled:YES account:displayedAccount(coordinator) error:NULL]);
    now = 204;
    CHECK(![coordinator acceptPreparedEnvelope:source(@"stale-stop") generation:stale createdAt:203 receivedAt:204 error:NULL]);
    CHECK([coordinator acceptPreparedEnvelope:source(@"exception-source") generation:capture.generation createdAt:203 receivedAt:204 error:NULL]);
    NSArray *groups = [coordinator prepareGroupsForContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]; CHECK(groups.count == 2);
    execution.throwAfterStart = YES; error = nil;
    NSArray *beforeDiagnostics = SRRuntimeLog.shared.snapshot[@"events"];
    unsigned long long diagnosticsBefore = [beforeDiagnostics.lastObject[@"sequence"] unsignedLongLongValue];
    CHECK(![coordinator startGroup:groups[0][@"id"] content:displayedContent(coordinator) account:displayedAccount(coordinator) error:&error]);
    CHECK(![error.localizedDescription containsString:@"private"]);
    NSArray *diagnostics = SRRuntimeLog.shared.snapshot[@"events"];
    BOOL sawFault = NO;
    for (NSDictionary *row in diagnostics)
        if ([row[@"sequence"] unsignedLongLongValue] > diagnosticsBefore && [row[@"event"] isEqual:@"operations_fault"]) { sawFault = YES; break; }
    CHECK(sawFault);
    CHECK([[store summaryForRun:execution.run error:NULL][@"state"] isEqual:@"paused"]);
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL] && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
    execution.throwAfterStart = NO;
    CHECK([coordinator setEnabled:YES account:displayedAccount(coordinator) error:NULL] && [coordinator resumeRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL]);
    // A lying port cannot cause recursive refresh or pretend a pause persisted.
    execution.liePause = YES; NSUInteger pauses = execution.pauses;
    CHECK(![coordinator refreshForeground:NO sourceTimeVerified:YES error:NULL]);
    CHECK(execution.pauses - pauses <= 3 && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
    execution.liePause = NO;
    CHECK([coordinator setEnabled:NO account:displayedAccount(coordinator) error:NULL]);
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    // Safe cancellation is still available when disabled or saved settings need repair.
    CHECK([store saveConfiguration:[SRConfiguration emptyDraft] account:account error:NULL]);
    CHECK([coordinator configurationSavedForAccount:displayedAccount(coordinator) error:NULL]);
    CHECK([coordinator cancelRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL] && [coordinator finishContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]);
    CHECK([store saveConfiguration:configuration() account:account error:NULL]);
    CHECK([coordinator setEnabled:YES account:displayedAccount(coordinator) error:NULL]);
    now = 206;
    CHECK([coordinator acceptPreparedEnvelope:source(@"lifecycle-source") generation:capture.generation createdAt:205 receivedAt:206 error:NULL]);
    groups = [coordinator prepareGroupsForContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]; CHECK(groups.count == 2);
    execution.duringStart = ^{
        account = @"other";
        CHECK(![weak refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK(![weak.snapshot[@"visible"] boolValue] && weak.snapshot[@"content"] == NSNull.null);
    };
    CHECK(![coordinator startGroup:groups[0][@"id"] content:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]);
    CHECK([[store summaryForRun:execution.run error:NULL][@"state"] isEqual:@"paused"]);
    CHECK(![coordinator.snapshot[@"enabled"] boolValue] && coordinator.snapshot[@"content"] == NSNull.null && !capture.active);
    CHECK(execution.resumes == 1);
    execution.duringStart = nil;
    // Reentry while arming is also drained before returning to the host.
    capture.duringArm = ^{ (void)[weak refreshForeground:NO sourceTimeVerified:NO error:NULL]; };
    CHECK(![coordinator setEnabled:YES account:displayedAccount(coordinator) error:NULL]);
    CHECK(![coordinator.snapshot[@"visible"] boolValue] && !capture.active);
    capture.duringArm = nil;
    puts("PASS: serialized commands, source-trust generations, port exceptions, bounded pause verification and lifecycle reentry");
}

int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *path = [root stringByAppendingPathComponent:@"operations.sqlite3"];
        SRStore *store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        CHECK([[SRConfiguration operationsRequirementsForDraft:[SRConfiguration emptyDraft]] isEqual:@[@"source_group", @"source_members", @"target_groups"]]);
        CHECK([[SRConfiguration operationsRequirementsForDraft:@{}] isEqual:@[@"configuration_invalid"]]);
        NSMutableDictionary *config = configuration();
        CHECK([SRConfiguration operationsRequirementsForDraft:config].count == 0);
        NSMutableDictionary *invalid = [config mutableCopy]; invalid[@"minimum"] = @2;
        CHECK([[SRConfiguration operationsRequirementsForDraft:invalid] isEqual:@[@"send_interval"]]);
        invalid = [config mutableCopy]; invalid[@"types"] = @[];
        CHECK([[SRConfiguration operationsRequirementsForDraft:invalid] isEqual:@[@"message_types"]]);
        CHECK([store saveConfiguration:config account:@"account" error:NULL]);
        CHECK([store setOperationsEnabled:YES account:@"account" error:NULL]);
        ExecutionPort *execution = [ExecutionPort new]; execution.store = store;
        CapturePort *capture = [CapturePort new];
        __block NSString *account = @"account"; __block double now = 100.2;
        SRRelayCoordinator *(^newCoordinator)(void) = ^{
            return [[SRRelayCoordinator alloc] initWithStore:store execution:execution capture:capture
                currentAccount:^NSString *{ return account; } clock:^double{ return now; }];
        };
        SRRelayCoordinator *coordinator = newCoordinator();
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:NO error:NULL]);
        CHECK([coordinator.snapshot[@"visible"] boolValue] && !capture.active && execution.starts == 0);
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL] && capture.active);
        uint64_t generation = capture.generation;
        now = 102;
        CHECK(![coordinator acceptPreparedEnvelope:source(@"old") generation:generation createdAt:99 receivedAt:102 error:NULL]);
        CHECK(![coordinator acceptPreparedEnvelope:source(@"same-second") generation:generation createdAt:100.8 receivedAt:102 error:NULL]);
        CHECK(![coordinator acceptPreparedEnvelope:source(@"future") generation:generation createdAt:103 receivedAt:102 error:NULL]);
        CHECK([coordinator acceptPreparedEnvelope:source(@"first") generation:generation createdAt:101 receivedAt:102 error:NULL]);
        CHECK(!capture.active && execution.starts == 0);
        CHECK([store plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 0);
        CHECK(![coordinator acceptPreparedEnvelope:source(@"second") generation:generation createdAt:101 receivedAt:102 error:NULL]);
        NSString *content = coordinator.snapshot[@"content"][@"id"];
        CHECK([[store saveOperationsContent:source(@"first") configuration:config account:@"account" capturedAt:103 error:NULL] isEqual:content]);
        CHECK(![store saveOperationsContent:source(@"second") configuration:config account:@"account" capturedAt:103 error:NULL]);
        config[@"minimum"] = @6; config[@"maximum"] = @12;
        CHECK([store saveConfiguration:config account:@"account" error:NULL]);
        CHECK([coordinator configurationSavedForAccount:displayedAccount(coordinator) error:NULL]);
        CHECK([coordinator.snapshot[@"content"][@"configuration"][@"minimum"] isEqual:@5]);

        // A failed plan/link transaction leaves no partial plan or source claim.
        sqlite3 *fault = NULL; CHECK(sqlite3_open(path.fileSystemRepresentation, &fault) == SQLITE_OK);
        CHECK(sqlite3_exec(fault, "CREATE TRIGGER fail_content_link BEFORE UPDATE OF plan_id ON operations_contents BEGIN SELECT RAISE(ABORT,'fault'); END", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(![coordinator prepareGroupsForContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]);
        CHECK([store plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 0);
        CHECK(sqlite3_exec(fault, "DROP TRIGGER fail_content_link", NULL, NULL, NULL) == SQLITE_OK);
        NSArray *groups = [coordinator prepareGroupsForContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]; CHECK(groups.count == 2);
        CHECK([[coordinator prepareGroupsForContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL] isEqual:groups]);
        CHECK([store plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 1);
        __weak SRRelayCoordinator *weakCoordinator = coordinator;
        execution.duringStart = ^{ CHECK(![weakCoordinator startGroup:groups[0][@"id"] content:displayedContent(weakCoordinator) account:displayedAccount(weakCoordinator) error:NULL]); };
        CHECK([coordinator startGroup:groups[0][@"id"] content:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]);
        CHECK(![coordinator startGroup:groups[0][@"id"] content:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL] && execution.starts == 1);
        CHECK([coordinator pauseRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL] && [coordinator resumeRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL]);
        NSString *run = execution.run;
        NSDictionary *delivery = [store claimNextForRun:run error:NULL]; CHECK(delivery);
        CHECK(sqlite3_exec(fault, "CREATE TRIGGER fail_cancel BEFORE UPDATE OF state ON deliveries WHEN NEW.state='cancelled' BEGIN SELECT RAISE(ABORT,'fault'); END", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(![coordinator cancelRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL]);
        CHECK([store operationsCancellationForRun:run account:@"account" error:NULL].count == 0);
        CHECK(count(store, run, @"pending") == 1 && count(store, run, @"submitting") == 1);
        CHECK(![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK(sqlite3_exec(fault, "DROP TRIGGER fail_cancel", NULL, NULL, NULL) == SQLITE_OK);
        CHECK([coordinator cancelRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL]);
        CHECK([coordinator.snapshot[@"phase"] integerValue] == SROpsCancelling);
        CHECK(count(store, run, @"submitting") == 1 && count(store, run, @"cancelled") == 1);
        CHECK(![coordinator resumeRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL] && ![coordinator finishContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]);
        CHECK(![store resumeRun:run error:NULL] && ![store claimNextForRun:run error:NULL]);
        CHECK(![store endRun:run error:NULL]); // Legacy end cannot destroy the draining receipt.
        CHECK(![store startSmallGroupRule:groups[1][@"id"] account:@"account" error:NULL]);
        CHECK([store recordResultForDelivery:delivery[@"id"] attempt:delivery[@"attempt_id"] state:@"submitted" messageID:nil reason:nil error:NULL]);
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK([coordinator.snapshot[@"phase"] integerValue] == SROpsGroupCancelled);
        CHECK([store summaryForRun:run error:NULL][@"ended_at"] != NSNull.null);
        CHECK(count(store, run, @"submitted") == 1 && count(store, run, @"cancelled") == 1);
        CHECK([coordinator cancelRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL] && !capture.active); // Confirmation double-click is idempotent.
        now = 110; CHECK([coordinator finishContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL] && capture.active);
        CHECK(![store saveOperationsContent:source(@"first") configuration:config account:@"account" capturedAt:110 error:NULL]);

        // A plan and paused run survive attachment failure; ordinary retry cannot rebuild either.
        now = 112; generation = capture.generation;
        CHECK([coordinator acceptPreparedEnvelope:source(@"next") generation:generation createdAt:111 receivedAt:112 error:NULL]);
        groups = [coordinator prepareGroupsForContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]; CHECK(groups.count == 2);
        execution.duringStart = nil; execution.failAttach = YES; NSError *error = nil;
        CHECK(![coordinator startGroup:groups[0][@"id"] content:displayedContent(coordinator) account:displayedAccount(coordinator) error:&error]);
        CHECK([error.localizedDescription isEqual:@"fake attach failure"]);
        CHECK([coordinator.snapshot[@"problem"] isEqual:@"fake attach failure"]);
        CHECK(![coordinator startGroup:groups[0][@"id"] content:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]);
        CHECK([store historyForRule:groups[0][@"id"] account:@"account" limit:10 offset:0 error:NULL].count == 1);
        execution.failAttach = NO; CHECK([coordinator resumeRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL]);
        CHECK([coordinator refreshForeground:NO sourceTimeVerified:YES error:NULL]);
        NSUInteger resumed = execution.resumes;
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK(execution.resumes == resumed && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([store recoverInterruptedRuns:NULL]);
        coordinator = newCoordinator();
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK(!capture.active && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([coordinator resumeRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL]);
        delivery = [store claimNextForRun:execution.run error:NULL]; CHECK(delivery);
        CHECK([coordinator cancelRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL]);
        CHECK([store recoverInterruptedRuns:NULL]); // Process death drains to unknown, never cancelled success.
        CHECK([store summaryForRun:execution.run error:NULL][@"state"] && count(store, execution.run, @"uncertain") == 1);
        CHECK([[store summaryForRun:execution.run error:NULL][@"state"] isEqual:@"ended"]);
        CHECK(![store resumeRun:execution.run error:NULL]);
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK([coordinator finishContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]);

        // Candidate persistence failure never advertises a captured message.
        CHECK(sqlite3_exec(fault, "CREATE TRIGGER fail_content BEFORE INSERT ON operations_contents BEGIN SELECT RAISE(ABORT,'fault'); END", NULL, NULL, NULL) == SQLITE_OK);
        now = 120; generation = capture.generation;
        CHECK(![coordinator acceptPreparedEnvelope:source(@"write-failure") generation:generation createdAt:119 receivedAt:120 error:NULL]);
        CHECK(coordinator.snapshot[@"content"] == NSNull.null && !capture.active);
        CHECK(sqlite3_exec(fault, "DROP TRIGGER fail_content", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(fault) == SQLITE_OK);
        CHECK([store saveConfiguration:configuration() account:@"other" error:NULL]);
        CHECK([store setOperationsEnabled:YES account:@"other" error:NULL]);
        account = @"other";
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK(![coordinator.snapshot[@"enabled"] boolValue] && coordinator.snapshot[@"recent"] == NSNull.null);
        CHECK(![[store operationsEnabledForAccount:@"other" error:NULL] boolValue]);
        account = nil;
        CHECK(![coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK(![coordinator.snapshot[@"visible"] boolValue] && coordinator.snapshot[@"groups"] != nil);
        CHECK([store plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 2);

        // An older paused task without content linkage cannot be hidden by a new capture.
        account = @"account";
        NSString *legacyPlan = [store createPlanFromConfiguration:config envelope:source(@"legacy") account:account error:NULL]; CHECK(legacyPlan);
        NSString *legacyRule = [store rulesForPlan:legacyPlan error:NULL][0][@"id"];
        NSString *legacyRun = [store startSmallGroupRule:legacyRule account:account error:NULL]; CHECK(legacyRun);
        CHECK(![store adoptLegacyOperationsRun:legacyRun account:account error:NULL]);
        CHECK([store pauseRun:legacyRun error:NULL]);
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]); // Account switch first disables.
        CHECK(![coordinator setEnabled:YES account:displayedAccount(coordinator) error:NULL] && !capture.active);
        CHECK(![[store operationsEnabledForAccount:account error:NULL] boolValue]);
        CHECK([coordinator.snapshot[@"legacyRun"][@"id"] isEqual:legacyRun]);
        CHECK(![store adoptLegacyOperationsRun:legacyRun account:@"other" error:NULL]);
        CHECK(sqlite3_open(path.fileSystemRepresentation, &fault) == SQLITE_OK);
        CHECK(sqlite3_exec(fault, "CREATE TRIGGER fail_adoption BEFORE INSERT ON operations_legacy_adoptions BEGIN SELECT RAISE(ABORT,'fault'); END", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(![coordinator recoverLegacyRun:legacyRun account:displayedAccount(coordinator) error:NULL]);
        CHECK([store operationsContentForAccount:account error:NULL][@"current"] == NSNull.null);
        CHECK(sqlite3_exec(fault, "DROP TRIGGER fail_adoption", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(fault) == SQLITE_OK);
        CHECK([coordinator recoverLegacyRun:legacyRun account:displayedAccount(coordinator) error:NULL]);
        content = coordinator.snapshot[@"content"][@"id"];
        CHECK([coordinator.snapshot[@"content"][@"plan_id"] isEqual:legacyPlan]);
        CHECK(coordinator.snapshot[@"content"][@"captured_at"] == NSNull.null && ![coordinator.snapshot[@"content"][@"captureTimeKnown"] boolValue]);
        CHECK(![coordinator.snapshot[@"enabled"] boolValue] && !capture.active);
        CHECK([coordinator recoverLegacyRun:legacyRun account:displayedAccount(coordinator) error:NULL] && [coordinator.snapshot[@"content"][@"id"] isEqual:content]);
        CHECK([coordinator setEnabled:YES account:displayedAccount(coordinator) error:NULL] && !capture.active);
        CHECK(![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([coordinator resumeRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL] && [execution.run isEqual:legacyRun]);
        NSDictionary *resumedSnapshot = coordinator.snapshot;
        NSUInteger legacyPauses = execution.pauses, legacyResumes = execution.resumes;
        CHECK([coordinator recoverLegacyRun:legacyRun account:displayedAccount(coordinator) error:NULL]);
        CHECK([coordinator.snapshot isEqual:resumedSnapshot]);
        CHECK(execution.pauses == legacyPauses && execution.resumes == legacyResumes);
        CHECK([[store summaryForRun:legacyRun error:NULL][@"state"] isEqual:@"running"]);
        CHECK([coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([coordinator cancelRun:displayedRun(coordinator) account:displayedAccount(coordinator) error:NULL] && [coordinator finishContent:displayedContent(coordinator) account:displayedAccount(coordinator) error:NULL]);
        CHECK([coordinator setEnabled:YES account:displayedAccount(coordinator) error:NULL] && capture.active);

        // Older schema numbers are not upgrade inputs. Keep the database
        // untouched and require a fresh schema-14 install instead.
        NSString *oldSchemaPath = [root stringByAppendingPathComponent:@"old-schema.sqlite3"];
        SRStore *oldSchema = [[SRStore alloc] initWithPath:oldSchemaPath error:NULL]; CHECK(oldSchema);
        oldSchema = nil;
        CHECK(sqlite3_open(oldSchemaPath.fileSystemRepresentation, &fault) == SQLITE_OK);
        CHECK(sqlite3_exec(fault, "PRAGMA user_version=9", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(fault) == SQLITE_OK);
        CHECK(![[SRStore alloc] initWithPath:oldSchemaPath error:NULL]);
        checkUnreadableConfigurationControls(root);
        checkCancellationReadback(root);
        checkCommandIdentity(root);
        checkCaptureEventIdentity(root);
        checkRunProjectionOrder(root);
        checkLibraryOccupancyGate(root);
        checkArchiveReadback(root);
        checkArchiveProjectionOrder(root);
        checkSilentFailureDiagnostic(root);
        checkDeferredLifecycleDispatch(root);
        checkFaultRevokesManualLease(root);
        checkPortBoundaries(root);
        puts("PASS: UI-free coordinator, frozen content, idempotent planning, cancellation drain, account and recovery gates");
    }
    return 0;
}
