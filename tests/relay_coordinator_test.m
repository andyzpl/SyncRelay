#import <Foundation/Foundation.h>
#import "Core/SRRelayCoordinator.h"
#import "Core/SROperationsState.h"
#import "Core/SRConfiguration.h"
#import "Core/SRStore.h"
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
@end
@implementation ReadFaultStore
- (NSDictionary *)operationsContentForAccount:(NSString *)account error:(NSError **)error {
    if (!self.failContentRead) return [super operationsContentForAccount:account error:error];
    if (error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey: @"injected content read failure"}];
    return nil;
}
@end

@interface ExecutionPort : NSObject <SRRelayExecution>
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, copy) NSString *run;
@property(nonatomic) NSUInteger starts;
@property(nonatomic) NSUInteger resumes;
@property(nonatomic) BOOL failAttach;
@property(nonatomic) BOOL throwAfterStart;
@property(nonatomic) BOOL liePause;
@property(nonatomic) NSUInteger pauses;
@property(nonatomic, copy) void (^duringStart)(void);
@property(nonatomic, copy) void (^afterCancel)(void);
@end
@implementation ExecutionPort
- (BOOL)startRule:(NSString *)rule account:(NSString *)account error:(NSError **)error {
    self.starts++;
    if (self.duringStart) self.duringStart();
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
    self.resumes++; self.run = run; return [self.store resumeRun:run error:error];
}
- (BOOL)pauseForAccount:(NSString *)account error:(NSError **)error {
    self.pauses++;
    if (self.liePause) return YES;
    NSDictionary *row = self.run ? [self.store summaryForRun:self.run error:NULL] : nil;
    if (![row[@"account"] isEqual:account]) return NO;
    if ([row[@"state"] isEqual:@"paused"] || [row[@"state"] isEqual:@"awaiting_resume"]) return YES;
    return [row[@"state"] isEqual:@"running"] && [self.store pauseRun:self.run error:error];
}
- (BOOL)cancelRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
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
    NSArray *groups = [coordinator prepareGroups:NULL]; CHECK(groups.count == 2);
    NSString *content = coordinator.snapshot[@"content"][@"id"];
    CHECK([coordinator startGroup:groups[0][@"id"] error:NULL]);
    NSString *run = execution.run;
    sqlite3 *fault = NULL; CHECK(sqlite3_open(path.fileSystemRepresentation, &fault) == SQLITE_OK);
    CHECK(sqlite3_exec(fault, "UPDATE configurations SET payload='{}' WHERE account='account'", NULL, NULL, NULL) == SQLITE_OK);
    NSError *error = nil;
    CHECK(![coordinator configurationSaved:&error] && error);
    CHECK([coordinator.snapshot[@"stateLoaded"] boolValue]);
    CHECK([coordinator.snapshot[@"requirements"] isEqual:@[@"configuration_invalid"]]);
    CHECK([coordinator.snapshot[@"content"][@"id"] isEqual:content]);
    CHECK([coordinator.snapshot[@"content"][@"configuration"][@"minimum"] isEqual:@5]);
    CHECK([[store summaryForRun:run error:NULL][@"state"] isEqual:@"paused"]);
    CHECK(count(store, run, @"pending") == 2 && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
    CHECK([coordinator pause:NULL] && [coordinator.snapshot[@"phase"] integerValue] == SROpsPaused);
    CHECK(![coordinator resume:NULL] && ![coordinator startGroup:groups[1][@"id"] error:NULL]);
    // Corrupt editable settings do not take away controls for a verified frozen task.
    CHECK([coordinator cancel:NULL] && [coordinator cancel:NULL]);
    CHECK([coordinator.snapshot[@"phase"] integerValue] == SROpsGroupCancelled);
    CHECK(count(store, run, @"cancelled") == 2);
    NSDictionary *cancellation = [store operationsCancellationForRun:run account:@"account" error:NULL];
    CHECK(cancellation[@"drained_at"] != NSNull.null);
    CHECK(sqlite3_exec(fault, "CREATE TRIGGER fail_archive BEFORE UPDATE OF archived_at ON operations_contents BEGIN SELECT RAISE(ABORT,'fault'); END", NULL, NULL, NULL) == SQLITE_OK);
    CHECK(![coordinator finishContent:NULL]);
    CHECK([[store operationsContentForAccount:@"account" error:NULL][@"current"][@"id"] isEqual:content]);
    CHECK(sqlite3_exec(fault, "DROP TRIGGER fail_archive", NULL, NULL, NULL) == SQLITE_OK);
    CHECK([coordinator finishContent:NULL]);
    CHECK(coordinator.snapshot[@"content"] == NSNull.null && [coordinator.snapshot[@"recent"][@"id"] isEqual:content]);
    CHECK(!capture.active && ![coordinator.snapshot[@"captureAllowed"] boolValue]);
    CHECK([coordinator.snapshot[@"problem"] length] > 0);
    CHECK([[store operationsCancellationForRun:run account:@"account" error:NULL] isEqual:cancellation]);
    CHECK([store plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 1);
    CHECK([store saveConfiguration:configuration() account:@"account" error:NULL]);
    CHECK([coordinator configurationSaved:NULL] && !capture.active);
    CHECK([coordinator setEnabled:YES error:NULL] && capture.active);
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
    NSArray *groups = [coordinator prepareGroups:NULL]; CHECK(groups.count == 2);
    CHECK([coordinator startGroup:groups[0][@"id"] error:NULL]);
    NSString *run = execution.run;
    execution.afterCancel = ^{ store.failContentRead = YES; };
    NSError *error = nil;
    CHECK(![coordinator cancel:&error] && error);
    CHECK(![coordinator.snapshot[@"stateLoaded"] boolValue] && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
    CHECK([[store summaryForRun:run error:NULL][@"state"] isEqual:@"ended"]);
    NSDictionary *cancellation = [store operationsCancellationForRun:run account:@"account" error:NULL];
    CHECK(cancellation[@"drained_at"] != NSNull.null);
    execution.afterCancel = nil; store.failContentRead = NO;
    CHECK([coordinator cancel:NULL]);
    CHECK([coordinator.snapshot[@"phase"] integerValue] == SROpsGroupCancelled);
    CHECK([[store operationsCancellationForRun:run account:@"account" error:NULL] isEqual:cancellation]);
    CHECK(execution.starts == 1 && execution.resumes == 0);
    CHECK([coordinator finishContent:NULL] && !capture.active);
    puts("PASS: cancellation commit with failed projection readback is explicit and safely retryable without a new run");
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
        CHECK(![weak setEnabled:NO error:NULL]);
        CHECK(![weak acceptPreparedEnvelope:source(@"synchronous") generation:weakCapture.generation createdAt:201 receivedAt:202 error:NULL]);
        CHECK(![weak prepareGroups:NULL] && ![weak finishContent:NULL]);
    };
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    CHECK(capture.active && coordinator.snapshot[@"content"] == NSNull.null);
    capture.duringArm = nil;
    uint64_t stale = capture.generation;
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:NO error:NULL] && !capture.active);
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL] && capture.generation != stale);
    now = 202;
    CHECK(![coordinator acceptPreparedEnvelope:source(@"stale-trust") generation:stale createdAt:201 receivedAt:202 error:NULL]);

    CHECK([coordinator setEnabled:NO error:NULL]);
    capture.throwArm = YES; NSError *error = nil;
    CHECK(![coordinator setEnabled:YES error:&error]);
    CHECK(!capture.active && ![error.localizedDescription containsString:@"private"]);
    NSUInteger starts = capture.starts;
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    CHECK(capture.starts == starts && ![coordinator.snapshot[@"captureAllowed"] boolValue]);
    capture.throwArm = NO; CHECK([coordinator setEnabled:YES error:NULL]);
    stale = capture.generation; capture.throwStop = YES;
    CHECK(![coordinator setEnabled:NO error:NULL]);
    CHECK(![[store operationsEnabledForAccount:account error:NULL] boolValue] && ![coordinator.snapshot[@"listening"] boolValue]);
    capture.throwStop = NO; CHECK([coordinator setEnabled:YES error:NULL]);
    now = 204;
    CHECK(![coordinator acceptPreparedEnvelope:source(@"stale-stop") generation:stale createdAt:203 receivedAt:204 error:NULL]);
    CHECK([coordinator acceptPreparedEnvelope:source(@"exception-source") generation:capture.generation createdAt:203 receivedAt:204 error:NULL]);
    NSArray *groups = [coordinator prepareGroups:NULL]; CHECK(groups.count == 2);
    execution.throwAfterStart = YES; error = nil;
    CHECK(![coordinator startGroup:groups[0][@"id"] error:&error]);
    CHECK(![error.localizedDescription containsString:@"private"]);
    CHECK([[store summaryForRun:execution.run error:NULL][@"state"] isEqual:@"paused"]);
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL] && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
    execution.throwAfterStart = NO;
    CHECK([coordinator setEnabled:YES error:NULL] && [coordinator resume:NULL]);
    // A lying port cannot cause recursive refresh or pretend a pause persisted.
    execution.liePause = YES; NSUInteger pauses = execution.pauses;
    CHECK(![coordinator refreshForeground:NO sourceTimeVerified:YES error:NULL]);
    CHECK(execution.pauses - pauses <= 3 && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
    execution.liePause = NO;
    CHECK([coordinator setEnabled:NO error:NULL]);
    CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
    // Safe cancellation is still available when disabled or saved settings need repair.
    CHECK([store saveConfiguration:[SRConfiguration emptyDraft] account:account error:NULL]);
    CHECK([coordinator configurationSaved:NULL]);
    CHECK([coordinator cancel:NULL] && [coordinator finishContent:NULL]);
    CHECK([store saveConfiguration:configuration() account:account error:NULL]);
    CHECK([coordinator setEnabled:YES error:NULL]);
    now = 206;
    CHECK([coordinator acceptPreparedEnvelope:source(@"lifecycle-source") generation:capture.generation createdAt:205 receivedAt:206 error:NULL]);
    groups = [coordinator prepareGroups:NULL]; CHECK(groups.count == 2);
    execution.duringStart = ^{
        account = @"other";
        CHECK(![weak refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK(![weak.snapshot[@"visible"] boolValue] && weak.snapshot[@"content"] == NSNull.null);
    };
    CHECK(![coordinator startGroup:groups[0][@"id"] error:NULL]);
    CHECK([[store summaryForRun:execution.run error:NULL][@"state"] isEqual:@"paused"]);
    CHECK(![coordinator.snapshot[@"enabled"] boolValue] && coordinator.snapshot[@"content"] == NSNull.null && !capture.active);
    CHECK(execution.resumes == 1);
    execution.duringStart = nil;
    // Reentry while arming is also drained before returning to the host.
    capture.duringArm = ^{ (void)[weak refreshForeground:NO sourceTimeVerified:NO error:NULL]; };
    CHECK(![coordinator setEnabled:YES error:NULL]);
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
        CHECK([coordinator configurationSaved:NULL]);
        CHECK([coordinator.snapshot[@"content"][@"configuration"][@"minimum"] isEqual:@5]);

        // A failed plan/link transaction leaves no partial plan or source claim.
        sqlite3 *fault = NULL; CHECK(sqlite3_open(path.fileSystemRepresentation, &fault) == SQLITE_OK);
        CHECK(sqlite3_exec(fault, "CREATE TRIGGER fail_content_link BEFORE UPDATE OF plan_id ON operations_contents BEGIN SELECT RAISE(ABORT,'fault'); END", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(![coordinator prepareGroups:NULL]);
        CHECK([store plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 0);
        CHECK(sqlite3_exec(fault, "DROP TRIGGER fail_content_link", NULL, NULL, NULL) == SQLITE_OK);
        NSArray *groups = [coordinator prepareGroups:NULL]; CHECK(groups.count == 2);
        CHECK([[coordinator prepareGroups:NULL] isEqual:groups]);
        CHECK([store plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 1);
        __weak SRRelayCoordinator *weakCoordinator = coordinator;
        execution.duringStart = ^{ CHECK(![weakCoordinator startGroup:groups[0][@"id"] error:NULL]); };
        CHECK([coordinator startGroup:groups[0][@"id"] error:NULL]);
        CHECK(![coordinator startGroup:groups[0][@"id"] error:NULL] && execution.starts == 1);
        CHECK([coordinator pause:NULL] && [coordinator resume:NULL]);
        NSString *run = execution.run;
        NSDictionary *delivery = [store claimNextForRun:run error:NULL]; CHECK(delivery);
        CHECK(sqlite3_exec(fault, "CREATE TRIGGER fail_cancel BEFORE UPDATE OF state ON deliveries WHEN NEW.state='cancelled' BEGIN SELECT RAISE(ABORT,'fault'); END", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(![coordinator cancel:NULL]);
        CHECK([store operationsCancellationForRun:run account:@"account" error:NULL].count == 0);
        CHECK(count(store, run, @"pending") == 1 && count(store, run, @"submitting") == 1);
        CHECK(![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK(sqlite3_exec(fault, "DROP TRIGGER fail_cancel", NULL, NULL, NULL) == SQLITE_OK);
        CHECK([coordinator cancel:NULL]);
        CHECK([coordinator.snapshot[@"phase"] integerValue] == SROpsCancelling);
        CHECK(count(store, run, @"submitting") == 1 && count(store, run, @"cancelled") == 1);
        CHECK(![coordinator resume:NULL] && ![coordinator finishContent:NULL]);
        CHECK(![store resumeRun:run error:NULL] && ![store claimNextForRun:run error:NULL]);
        CHECK(![store endRun:run error:NULL]); // Legacy end cannot destroy the draining receipt.
        CHECK(![store startSmallGroupRule:groups[1][@"id"] account:@"account" error:NULL]);
        CHECK([store recordResultForDelivery:delivery[@"id"] attempt:delivery[@"attempt_id"] state:@"submitted" messageID:nil reason:nil error:NULL]);
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK([coordinator.snapshot[@"phase"] integerValue] == SROpsGroupCancelled);
        CHECK([store summaryForRun:run error:NULL][@"ended_at"] != NSNull.null);
        CHECK(count(store, run, @"submitted") == 1 && count(store, run, @"cancelled") == 1);
        CHECK([coordinator cancel:NULL] && !capture.active); // Confirmation double-click is idempotent.
        now = 110; CHECK([coordinator finishContent:NULL] && capture.active);
        CHECK(![store saveOperationsContent:source(@"first") configuration:config account:@"account" capturedAt:110 error:NULL]);

        // A plan and paused run survive attachment failure; ordinary retry cannot rebuild either.
        now = 112; generation = capture.generation;
        CHECK([coordinator acceptPreparedEnvelope:source(@"next") generation:generation createdAt:111 receivedAt:112 error:NULL]);
        groups = [coordinator prepareGroups:NULL]; CHECK(groups.count == 2);
        execution.duringStart = nil; execution.failAttach = YES; NSError *error = nil;
        CHECK(![coordinator startGroup:groups[0][@"id"] error:&error]);
        CHECK([error.localizedDescription isEqual:@"fake attach failure"]);
        CHECK([coordinator.snapshot[@"problem"] isEqual:@"fake attach failure"]);
        CHECK(![coordinator startGroup:groups[0][@"id"] error:NULL]);
        CHECK([store historyForRule:groups[0][@"id"] account:@"account" limit:10 offset:0 error:NULL].count == 1);
        execution.failAttach = NO; CHECK([coordinator resume:NULL]);
        CHECK([coordinator refreshForeground:NO sourceTimeVerified:YES error:NULL]);
        NSUInteger resumed = execution.resumes;
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK(execution.resumes == resumed && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([store recoverInterruptedRuns:NULL]);
        coordinator = newCoordinator();
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK(!capture.active && ![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([coordinator resume:NULL]);
        delivery = [store claimNextForRun:execution.run error:NULL]; CHECK(delivery);
        CHECK([coordinator cancel:NULL]);
        CHECK([store recoverInterruptedRuns:NULL]); // Process death drains to unknown, never cancelled success.
        CHECK([store summaryForRun:execution.run error:NULL][@"state"] && count(store, execution.run, @"uncertain") == 1);
        CHECK([[store summaryForRun:execution.run error:NULL][@"state"] isEqual:@"ended"]);
        CHECK(![store resumeRun:execution.run error:NULL]);
        CHECK([coordinator refreshForeground:YES sourceTimeVerified:YES error:NULL]);
        CHECK([coordinator finishContent:NULL]);

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
        CHECK(![coordinator setEnabled:YES error:NULL] && !capture.active);
        CHECK(![[store operationsEnabledForAccount:account error:NULL] boolValue]);
        CHECK([coordinator.snapshot[@"legacyRun"][@"id"] isEqual:legacyRun]);
        CHECK(![store adoptLegacyOperationsRun:legacyRun account:@"other" error:NULL]);
        CHECK(sqlite3_open(path.fileSystemRepresentation, &fault) == SQLITE_OK);
        CHECK(sqlite3_exec(fault, "CREATE TRIGGER fail_adoption BEFORE INSERT ON operations_legacy_adoptions BEGIN SELECT RAISE(ABORT,'fault'); END", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(![coordinator recoverLegacyRun:legacyRun error:NULL]);
        CHECK([store operationsContentForAccount:account error:NULL][@"current"] == NSNull.null);
        CHECK(sqlite3_exec(fault, "DROP TRIGGER fail_adoption", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(fault) == SQLITE_OK);
        CHECK([coordinator recoverLegacyRun:legacyRun error:NULL]);
        content = coordinator.snapshot[@"content"][@"id"];
        CHECK([coordinator.snapshot[@"content"][@"plan_id"] isEqual:legacyPlan]);
        CHECK(coordinator.snapshot[@"content"][@"captured_at"] == NSNull.null && ![coordinator.snapshot[@"content"][@"captureTimeKnown"] boolValue]);
        CHECK(![coordinator.snapshot[@"enabled"] boolValue] && !capture.active);
        CHECK([coordinator recoverLegacyRun:legacyRun error:NULL] && [coordinator.snapshot[@"content"][@"id"] isEqual:content]);
        CHECK([coordinator setEnabled:YES error:NULL] && !capture.active);
        CHECK(![coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([coordinator resume:NULL] && [execution.run isEqual:legacyRun]);
        NSDictionary *resumedSnapshot = coordinator.snapshot;
        NSUInteger legacyPauses = execution.pauses, legacyResumes = execution.resumes;
        CHECK([coordinator recoverLegacyRun:legacyRun error:NULL]);
        CHECK([coordinator.snapshot isEqual:resumedSnapshot]);
        CHECK(execution.pauses == legacyPauses && execution.resumes == legacyResumes);
        CHECK([[store summaryForRun:legacyRun error:NULL][@"state"] isEqual:@"running"]);
        CHECK([coordinator.snapshot[@"dispatchAllowed"] boolValue]);
        CHECK([coordinator cancel:NULL] && [coordinator finishContent:NULL]);
        CHECK([coordinator setEnabled:YES error:NULL] && capture.active);

        // True schema-9 upgrade: old runs/claims/preferences survive additive tables.
        NSString *upgradePath = [root stringByAppendingPathComponent:@"upgrade.sqlite3"];
        SRStore *upgrade = [[SRStore alloc] initWithPath:upgradePath error:NULL]; CHECK(upgrade);
        CHECK([upgrade saveConfiguration:config account:@"account" error:NULL]);
        CHECK([upgrade setOperationsEnabled:YES account:@"account" error:NULL]);
        legacyPlan = [upgrade createPlanFromConfiguration:config envelope:source(@"upgrade-source") account:@"account" error:NULL]; CHECK(legacyPlan);
        legacyRule = [upgrade rulesForPlan:legacyPlan error:NULL][0][@"id"];
        legacyRun = [upgrade startSmallGroupRule:legacyRule account:@"account" error:NULL]; CHECK(legacyRun);
        delivery = [upgrade claimNextForRun:legacyRun error:NULL]; CHECK(delivery);
        CHECK([upgrade claimSmallGroupDelivery:delivery source:source(@"upgrade-source") account:@"account" error:NULL]);
        CHECK([upgrade recordResultForDelivery:delivery[@"id"] attempt:delivery[@"attempt_id"] state:@"submitted" messageID:nil reason:nil error:NULL]);
        CHECK([upgrade pauseRun:legacyRun error:NULL]); upgrade = nil;
        CHECK(sqlite3_open(upgradePath.fileSystemRepresentation, &fault) == SQLITE_OK);
        CHECK(sqlite3_exec(fault, "DROP TABLE operations_legacy_adoptions; DROP TABLE operations_contents; DROP TABLE operations_cancellations; PRAGMA user_version=9", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(fault) == SQLITE_OK);
        upgrade = [[SRStore alloc] initWithPath:upgradePath error:NULL]; CHECK(upgrade);
        CHECK([[upgrade operationsEnabledForAccount:@"account" error:NULL] boolValue]);
        CHECK(count(upgrade, legacyRun, @"submitted") == 1 && count(upgrade, legacyRun, @"pending") == 1);
        CHECK([[upgrade summaryForRun:legacyRun error:NULL][@"state"] isEqual:@"paused"]);
        CHECK(sqlite3_open(upgradePath.fileSystemRepresentation, &fault) == SQLITE_OK);
        sqlite3_stmt *check = NULL;
        CHECK(sqlite3_prepare_v2(fault, "SELECT (SELECT COUNT(*) FROM source_claims),(SELECT COUNT(*) FROM native_attempt_claims),(SELECT COUNT(*) FROM attempts),(SELECT COUNT(*) FROM submission_receipts)", -1, &check, NULL) == SQLITE_OK);
        CHECK(sqlite3_step(check) == SQLITE_ROW);
        for (int column = 0; column < 4; column++) CHECK(sqlite3_column_int(check, column) == 1);
        sqlite3_finalize(check); CHECK(sqlite3_close(fault) == SQLITE_OK);
        CHECK(![upgrade claimSmallGroupDelivery:delivery source:source(@"upgrade-source") account:@"account" error:NULL]);
        CHECK(![upgrade createPlanFromConfiguration:config envelope:source(@"upgrade-source") account:@"account" error:NULL]);
        content = [upgrade adoptLegacyOperationsRun:legacyRun account:@"account" error:NULL]; CHECK(content);
        CHECK([content isEqual:[upgrade adoptLegacyOperationsRun:legacyRun account:@"account" error:NULL]]);
        CHECK([[upgrade planForOperationsContent:content account:@"account" error:NULL] isEqual:legacyPlan]);
        CHECK([upgrade plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 1);
        CHECK(count(upgrade, legacyRun, @"submitted") == 1 && count(upgrade, legacyRun, @"pending") == 1);
        upgrade = nil; upgrade = [[SRStore alloc] initWithPath:upgradePath error:NULL]; CHECK(upgrade);
        CHECK([upgrade operationsContentForAccount:@"account" error:NULL][@"current"][@"captured_at"] == NSNull.null);
        CHECK(![[upgrade operationsContentForAccount:@"account" error:NULL][@"unlinkedActiveRun"] boolValue]);
        checkUnreadableConfigurationControls(root);
        checkCancellationReadback(root);
        checkPortBoundaries(root);
        puts("PASS: UI-free coordinator, frozen content, idempotent planning, cancellation drain, account and recovery gates");
    }
    return 0;
}
