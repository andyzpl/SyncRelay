#import <Foundation/Foundation.h>
#import "Core/SRConfiguration.h"
#import "Core/SRStore.h"
#import "Core/SRRunner.h"
#import <sqlite3.h>
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

@interface ProgressTransport : NSObject <SRSendTransport>
@property(nonatomic, copy) NSString *account;
@property(nonatomic, strong) NSMutableArray *deliveries;
@property(nonatomic, strong) NSMutableArray *callbacks;
@end
@implementation ProgressTransport
- (instancetype)init {
    self = [super init];
    if (self) { _account = @"account"; _deliveries = [NSMutableArray array]; _callbacks = [NSMutableArray array]; }
    return self;
}
- (BOOL)canSendForAccount:(NSString *)account { return [account isEqual:self.account]; }
- (void)submitDelivery:(NSDictionary *)delivery snapshot:(NSDictionary *)snapshot completion:(SRSendCompletion)completion {
    CHECK([snapshot[@"type"] isEqual:@"text"]);
    [self.deliveries addObject:delivery]; [self.callbacks addObject:[completion copy]];
}
@end

static NSString *plan(SRStore *store, NSString *identifier) {
    NSMutableDictionary *draft = [SRConfiguration emptyDraft];
    draft[@"sourceGroup"] = @{@"id": @"mother@chatroom", @"name": @"Mother"};
    draft[@"senders"] = @[@{@"id": @"sender", @"name": @"Sender"}];
    draft[@"rules"] = @[
        @{@"id": @"first", @"name": @"First", @"targets": @[
            @{@"id": @"one@chatroom", @"name": @"One"}, @{@"id": @"two@chatroom", @"name": @"Two"},
            @{@"id": @"three@chatroom", @"name": @"Three"}]},
        @{@"id": @"second", @"name": @"Second", @"targets": @[@{@"id": @"four@chatroom", @"name": @"Four"}]}];
    NSDictionary *source = @{@"account": @"account", @"group": @"mother@chatroom", @"sender": @"sender",
        @"messageID": identifier, @"type": @"text", @"generatedByRelay": @NO, @"payload": @{@"text": @"synthetic source"}};
    NSString *result = [store createPlanFromConfiguration:draft envelope:source account:@"account" error:NULL]; CHECK(result);
    return result;
}
static NSUInteger count(SRStore *store, NSString *run, NSString *state) {
    for (NSDictionary *row in [store summaryForRun:run error:NULL][@"counts"])
        if ([row[@"state"] isEqual:state]) return [row[@"count"] unsignedIntegerValue];
    return 0;
}
static void finish(ProgressTransport *transport, NSUInteger index, NSString *state) {
    SRSendCompletion completion = transport.callbacks[index]; completion(state, nil, nil);
}
static BOOL record(SRStore *store, NSDictionary *delivery, NSString *state) {
    return [store recordResultForDelivery:delivery[@"id"] attempt:delivery[@"attempt_id"] state:state messageID:nil reason:nil error:NULL];
}

int main(void) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *path = [directory stringByAppendingPathComponent:@"automatic.sqlite3"];
        SRStore *store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        NSArray *rules = [store rulesForPlan:plan(store, @"automatic") error:NULL];
        NSString *run = [store startRule:rules[0][@"id"] replay:NO error:NULL]; CHECK(run);
        __block double now = 0; __block BOOL environment = YES;
        ProgressTransport *transport = [[ProgressTransport alloc] init];
        SRRunner *runner = [[SRRunner alloc] initWithStore:store transport:transport clock:^double { return now; }
            random:^double { return 0.5; } environmentAllowed:^BOOL { return environment; }];
        CHECK([runner activateRun:run account:@"account" error:NULL]);
        for (NSUInteger i = 0; i < 3; i++) {
            double due = [runner.status[@"nextMonotonic"] doubleValue];
            now = due - 0.01; CHECK(![runner tick]); now = due; CHECK([runner tick]);
            CHECK(![runner activateRun:run account:@"account" error:NULL]);
            CHECK(![runner tick]);
            finish(transport, i, @"submitted"); (void)runner.status;
            CHECK(count(store, run, @"submitted") == i + 1 && count(store, run, @"confirmed") == 0);
            CHECK([store exceptionsForRun:run account:@"account" limit:50 offset:0 error:NULL].count == 0);
        }
        CHECK([runner.status[@"run"] isEqual:NSNull.null]);
        CHECK([[store summaryForRun:run error:NULL][@"state"] isEqual:@"completed"]);
        CHECK([store summaryForRun:run error:NULL][@"ended_at"] != NSNull.null);
        CHECK(transport.deliveries.count == 3);
        now += 10000; CHECK(![runner tick]); CHECK(transport.deliveries.count == 3);
        CHECK([store historyForRule:rules[1][@"id"] account:@"account" limit:50 offset:0 error:NULL].count == 0);
        CHECK([store historyForRule:rules[0][@"id"] account:@"account" limit:1 offset:0 error:NULL][0][@"counts"][@"submitted"] != nil);

        // A true interruption pauses once. Continuing skips its consumed target.
        rules = [store rulesForPlan:plan(store, @"interrupted") error:NULL];
        NSString *interrupted = [store startRule:rules[0][@"id"] replay:NO error:NULL]; CHECK(interrupted);
        CHECK([runner activateRun:interrupted account:@"account" error:NULL]);
        now = [runner.status[@"nextMonotonic"] doubleValue]; CHECK([runner tick]);
        CHECK([runner pause:NULL]); CHECK(![store resumeRun:interrupted error:NULL]);
        CHECK(![runner activateRun:interrupted account:@"account" error:NULL]);
        runner = nil; store = nil;
        store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store && [store recoverInterruptedRuns:NULL]);
        CHECK(count(store, run, @"submitted") == 3 && count(store, run, @"confirmed") == 0);
        CHECK(count(store, interrupted, @"uncertain") == 1 && count(store, interrupted, @"pending") == 2);
        CHECK([[store summaryForRun:interrupted error:NULL][@"state"] isEqual:@"awaiting_resume"]);
        ProgressTransport *restored = [[ProgressTransport alloc] init];
        runner = [[SRRunner alloc] initWithStore:store transport:restored clock:^double { return now; }
            random:^double { return 0.5; } environmentAllowed:^BOOL { return environment; }];
        CHECK(![runner tick]); now += 10000;
        CHECK(![runner activateRun:interrupted account:@"other" error:NULL]);
        CHECK([runner activateRun:interrupted account:@"account" error:NULL]);
        CHECK(![runner tick]); double due = [runner.status[@"nextMonotonic"] doubleValue]; CHECK(due == now + 7.5);
        now = due; CHECK([runner tick]);
        CHECK(![restored.deliveries[0][@"target"] isEqual:transport.deliveries[3][@"target"]]);
        finish(transport, 3, @"submitted"); (void)runner.status; // Dead runner callback cannot mutate recovery.
        CHECK(count(store, interrupted, @"uncertain") == 1);
        finish(restored, 0, @"submitted"); (void)runner.status;
        environment = NO; now += 15; CHECK(![runner tick]);
        environment = YES; CHECK(![runner tick]);
        CHECK([runner activateRun:interrupted account:@"account" error:NULL]);
        CHECK(![runner tick]); now = [runner.status[@"nextMonotonic"] doubleValue]; CHECK([runner tick]);
        finish(restored, 1, @"submitted"); (void)runner.status;
        CHECK(restored.deliveries.count == 2 && count(store, interrupted, @"submitted") == 2);
        CHECK(count(store, interrupted, @"uncertain") == 1 && count(store, interrupted, @"pending") == 0);
        CHECK([[store summaryForRun:interrupted error:NULL][@"state"] isEqual:@"completed"]);
        CHECK([store exceptionsForRun:interrupted account:@"account" limit:50 offset:0 error:NULL].count == 1);
        CHECK(![store exceptionsForRun:interrupted account:@"other" limit:50 offset:0 error:NULL]);

        // Target-local failures are recorded and skipped, not made a user chore.
        rules = [store rulesForPlan:plan(store, @"failure") error:NULL];
        NSString *failedRun = [store startRule:rules[0][@"id"] replay:NO error:NULL]; CHECK(failedRun);
        CHECK([runner activateRun:failedRun account:@"account" error:NULL]);
        for (NSUInteger i = 0; i < 3; i++) {
            now = [runner.status[@"nextMonotonic"] doubleValue]; CHECK([runner tick]);
            finish(restored, i + 2, i == 0 ? @"failed" : @"submitted"); (void)runner.status;
        }
        CHECK([runner.status[@"run"] isEqual:NSNull.null]);
        CHECK(count(store, failedRun, @"failed") == 1 && count(store, failedRun, @"submitted") == 2);
        CHECK([store exceptionsForRun:failedRun account:@"account" limit:50 offset:0 error:NULL].count == 1);

        rules = [store rulesForPlan:plan(store, @"unknown") error:NULL];
        NSString *unknownRun = [store startRule:rules[0][@"id"] replay:NO error:NULL]; CHECK(unknownRun);
        CHECK([runner activateRun:unknownRun account:@"account" error:NULL]);
        now = [runner.status[@"nextMonotonic"] doubleValue]; CHECK([runner tick]);
        finish(restored, 5, @"uncertain"); (void)runner.status;
        CHECK([runner.status[@"halted"] boolValue] && count(store, unknownRun, @"pending") == 2);
        now += 10000; CHECK(![runner tick]);
        CHECK([runner activateRun:unknownRun account:@"account" error:NULL]); CHECK(![runner tick]);
        now = [runner.status[@"nextMonotonic"] doubleValue]; CHECK([runner tick]);
        finish(restored, 5, @"uncertain"); (void)runner.status;
        CHECK([runner.status[@"inflight"] boolValue] && ![runner.status[@"halted"] boolValue]);
        finish(restored, 6, @"submitted"); (void)runner.status;
        now = [runner.status[@"nextMonotonic"] doubleValue]; CHECK([runner tick]);
        finish(restored, 7, @"submitted"); (void)runner.status;
        CHECK([runner.status[@"run"] isEqual:NSNull.null] && count(store, unknownRun, @"uncertain") == 1);
        CHECK(count(store, unknownRun, @"submitted") == 2);

        // Receipt insertion is atomic; a storage error cannot fake progress.
        rules = [store rulesForPlan:plan(store, @"atomic") error:NULL];
        NSString *atomic = [store startRule:rules[0][@"id"] replay:NO error:NULL]; CHECK(atomic);
        NSDictionary *delivery = [store claimNextForRun:atomic error:NULL]; CHECK(delivery);
        sqlite3 *db = NULL; CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
        CHECK(sqlite3_exec(db, "CREATE TRIGGER fail_receipt BEFORE INSERT ON submission_receipts BEGIN SELECT RAISE(ABORT,'test fault'); END", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(!record(store, delivery, @"submitted"));
        CHECK(count(store, atomic, @"submitting") == 1 && count(store, atomic, @"submitted") == 0);
        CHECK(sqlite3_exec(db, "DROP TRIGGER fail_receipt", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(record(store, delivery, @"submitted")); CHECK(record(store, delivery, @"submitted"));
        CHECK(record(store, delivery, @"uncertain")); // Repeated uncertainty does not erase known dispatch.
        CHECK(count(store, atomic, @"submitted") == 1 && count(store, atomic, @"confirmed") == 0);
        CHECK([[store summaryForRun:atomic error:NULL][@"state"] isEqual:@"running"]);
        CHECK(![store recordResultForDelivery:delivery[@"id"] attempt:@"wrong" state:@"submitted" messageID:nil reason:nil error:NULL]);
        CHECK(!record(store, delivery, @"confirmed"));
        CHECK(record(store, delivery, @"failed")); CHECK(count(store, atomic, @"failed") == 1);
        NSDictionary *second = [store claimNextForRun:atomic error:NULL]; CHECK(second);
        CHECK(record(store, second, @"uncertain"));
        CHECK([[store summaryForRun:atomic error:NULL][@"state"] isEqual:@"paused"]);
        CHECK(![store claimNextForRun:atomic error:NULL]);
        CHECK([store resumeRun:atomic error:NULL]);
        NSDictionary *third = [store claimNextForRun:atomic error:NULL]; CHECK(third);
        CHECK(![third[@"target"] isEqual:second[@"target"]] && ![third[@"target"] isEqual:delivery[@"target"]]);
        CHECK(record(store, third, @"submitted"));
        CHECK([[store summaryForRun:atomic error:NULL][@"state"] isEqual:@"completed"]);
        CHECK([store exceptionsForRun:atomic account:@"account" limit:50 offset:0 error:NULL].count == 2);
        CHECK(sqlite3_close(db) == SQLITE_OK);

        // Unsupported schemas are not upgrade inputs; a fresh install starts at 0.
        NSString *unsupportedPath = [directory stringByAppendingPathComponent:@"unsupported-schema.sqlite3"];
        SRStore *unsupportedSeed = [[SRStore alloc] initWithPath:unsupportedPath error:NULL]; CHECK(unsupportedSeed);
        unsupportedSeed = nil;
        CHECK(sqlite3_open(unsupportedPath.fileSystemRepresentation, &db) == SQLITE_OK);
        CHECK(sqlite3_exec(db, "PRAGMA user_version=13", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(db) == SQLITE_OK);
        CHECK(![[SRStore alloc] initWithPath:unsupportedPath error:NULL]);

        // A refused future schema must never publish a constructor or a version.
        NSString *futurePath = [directory stringByAppendingPathComponent:@"future-schema.sqlite3"];
        SRStore *future = [[SRStore alloc] initWithPath:futurePath error:NULL]; CHECK(future);
        future = nil;
        CHECK(sqlite3_open(futurePath.fileSystemRepresentation, &db) == SQLITE_OK);
        CHECK(sqlite3_exec(db, "PRAGMA user_version=15", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(db) == SQLITE_OK);
        future = [[SRStore alloc] initWithPath:futurePath error:NULL]; CHECK(!future);
        CHECK(future.schemaVersion == 0);

        runner = nil; store = nil; transport = nil; restored = nil;
        CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: automatic submitted progress without delivery claims, no per-target review, paced pending-only resume, restart, exceptions and atomic receipts");
    }
    return 0;
}
