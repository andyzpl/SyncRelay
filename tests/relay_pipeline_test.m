#import <Foundation/Foundation.h>
#import "Core/SRConfiguration.h"
#import "Core/SRSourceCapture.h"
#import "Core/SRStore.h"
#import "Core/SRRunner.h"
#import <sqlite3.h>
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

@interface FakeTransport : NSObject <SRSendTransport>
@property(nonatomic, copy) NSString *account;
@property(nonatomic) BOOL immediate;
@property(nonatomic) NSUInteger submitted;
@property(nonatomic, strong) NSMutableArray *callbacks;
@property(nonatomic, strong) NSMutableArray *snapshots;
@end
@implementation FakeTransport
- (instancetype)init { self = [super init]; if (self) { _account = @"account"; _callbacks = [NSMutableArray array]; _snapshots = [NSMutableArray array]; } return self; }
- (BOOL)canSendForAccount:(NSString *)account { return [account isEqual:self.account]; }
- (void)submitDelivery:(NSDictionary *)delivery snapshot:(NSDictionary *)snapshot completion:(SRSendCompletion)completion {
    self.submitted++; [self.snapshots addObject:snapshot]; [self.callbacks addObject:[completion copy]];
    if (self.immediate) completion(@"confirmed", [@"server-" stringByAppendingString:delivery[@"attempt_id"]], nil);
}
@end

static NSMutableDictionary *configuration(NSUInteger total) {
    NSMutableDictionary *draft = [SRConfiguration emptyDraft];
    draft[@"sourceGroup"] = @{@"id": @"mother@chatroom", @"name": @"Mother"};
    draft[@"senders"] = @[@{@"id": @"wxid_sender", @"name": @"Same nickname"}];
    NSMutableArray *targets = [NSMutableArray array];
    for (NSUInteger i = 0; i < total; i++) [targets addObject:@{@"id": [NSString stringWithFormat:@"group-%lu@chatroom", (unsigned long)i], @"name": @"Target"}];
    draft[@"rules"] = @[@{@"id": @"draft-rule", @"name": @"First", @"targets": targets},
        @{@"id": @"draft-rule2", @"name": @"Second", @"targets": @[@{@"id": @"next@chatroom", @"name": @"Next"}]}];
    return draft;
}
static NSMutableDictionary *message(NSString *identifier) {
    return [@{@"account": @"account", @"group": @"mother@chatroom", @"sender": @"wxid_sender", @"messageID": identifier,
        @"type": @"text", @"generatedByRelay": @NO, @"payload": [@{@"text": @"original text"} mutableCopy]} mutableCopy];
}
static NSUInteger deliveryCount(SRStore *store, NSString *run, NSString *state) {
    for (NSDictionary *row in [store summaryForRun:run error:NULL][@"counts"]) if ([row[@"state"] isEqual:state]) return [row[@"count"] unsignedIntegerValue];
    return 0;
}
static void callback(FakeTransport *transport, NSUInteger index, NSString *state, NSString *identifier) {
    SRSendCompletion completion = transport.callbacks[index]; completion(state, identifier, nil);
}

int main(void) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *path = [directory stringByAppendingPathComponent:@"pipeline.sqlite3"];
        SRStore *store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        SRSourceCapture *capture = [[SRSourceCapture alloc] initWithStore:store];
        NSMutableDictionary *incomplete = configuration(1); incomplete[@"senders"] = @[];
        NSError *readiness = nil;
        CHECK(![capture armForAccount:@"account" configuration:incomplete error:&readiness] && readiness.code == 14);
        incomplete = configuration(1); incomplete[@"rules"] = @[];
        CHECK(![capture armForAccount:@"account" configuration:incomplete error:&readiness] && readiness.code == 15);
        NSMutableDictionary *draft = configuration(2000);
        CHECK([capture armForAccount:@"account" configuration:draft error:NULL]);
        draft[@"types"] = @[@"image"]; // Armed configuration is a deep immutable snapshot.
        for (NSString *key in @[@"account", @"group", @"sender", @"type"]) {
            NSMutableDictionary *wrong = message(@"message1"); wrong[key] = @"wrong"; CHECK(![capture offerEnvelope:wrong]);
        }
        CHECK([capture.diagnostics[@"rejected"] isEqual:@4]);
        CHECK(![capture.diagnostics.description containsString:@"wxid_sender"]);
        NSMutableDictionary *generated = message(@"message1"); generated[@"generatedByRelay"] = @YES; CHECK(![capture offerEnvelope:generated]);
        [generated removeObjectForKey:@"generatedByRelay"]; CHECK(![capture offerEnvelope:generated]);
        NSMutableDictionary *source = message(@"message1"); CHECK([capture offerEnvelope:source]);
        source[@"payload"][@"text"] = @"mutated";
        CHECK([capture.preview[@"payload"][@"text"] isEqual:@"original text"]);
        CHECK(![capture offerEnvelope:message(@"message2")]);
        CHECK(![capture confirmForCurrentAccount:@"other-account" error:NULL]); CHECK(capture.preview);
        NSString *plan = [capture confirmForCurrentAccount:@"account" error:NULL]; CHECK(plan && !capture.preview);
        CHECK(![capture confirmForCurrentAccount:@"account" error:NULL]);
        CHECK(![store createPlanFromConfiguration:configuration(2000) envelope:message(@"message1") account:@"account" error:NULL]);
        NSArray *rules = [store rulesForPlan:plan error:NULL]; CHECK(rules.count == 2);
        CHECK([store allocatedTargetsForPlan:plan error:NULL].count == 2001);

        // Forced insertion failure must roll back both the source claim and its plan.
        sqlite3 *fault = NULL; CHECK(sqlite3_open(path.fileSystemRepresentation, &fault) == SQLITE_OK);
        CHECK(sqlite3_exec(fault, "CREATE TRIGGER fail_alloc BEFORE INSERT ON allocations BEGIN SELECT RAISE(ABORT,'test fault'); END", NULL, NULL, NULL) == SQLITE_OK);
        CHECK([capture armForAccount:@"account" configuration:configuration(1) error:NULL]);
        CHECK([capture offerEnvelope:message(@"rollback-message")]);
        CHECK(![capture confirmForCurrentAccount:@"account" error:NULL]); CHECK(capture.preview);
        CHECK(sqlite3_exec(fault, "DROP TRIGGER fail_alloc", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(fault) == SQLITE_OK);
        CHECK([capture confirmForCurrentAccount:@"account" error:NULL]);

        __block double now = 0; __block BOOL environment = YES;
        FakeTransport *transport = [[FakeTransport alloc] init]; transport.immediate = YES;
        SRRunner *(^newRunner)(void) = ^{ return [[SRRunner alloc] initWithStore:store transport:transport clock:^double{ return now; }
            random:^double{ return 0.5; } environmentAllowed:^BOOL{ return environment; }]; };
        SRRunner *runner = newRunner();
        NSString *run = [store startRule:rules[0][@"id"] replay:NO error:NULL]; CHECK(run);
        CHECK(![runner activateRun:run account:@"other-account" error:NULL]);
        CHECK([runner activateRun:run account:@"account" error:NULL]);
        SRRunner *competitor = newRunner(); CHECK(![competitor activateRun:run account:@"account" error:NULL]);
        CHECK(![runner tick]); now = 7.49; CHECK(![runner tick]); now = 7.5; CHECK([runner tick]);
        CHECK(![runner.status[@"inflight"] boolValue]);
        CHECK(transport.submitted == 1);
        CHECK([runner pause:NULL]); now = 1000; CHECK(![runner tick]);
        CHECK(![store startRule:rules[1][@"id"] replay:NO error:NULL]);
        CHECK([runner activateRun:run account:@"account" error:NULL]); CHECK(![runner tick]);
        environment = NO; now = 1015; CHECK(![runner tick]); CHECK([runner.status[@"halted"] boolValue]);
        environment = YES; CHECK(![runner tick]); // Readiness recovery does not automatically resume.
        CHECK([runner activateRun:run account:@"account" error:NULL]);
        for (NSUInteger i = 1; i < 2000; i++) {
            now = [runner.status[@"nextMonotonic"] doubleValue]; CHECK([runner tick]); (void)runner.status;
        }
        CHECK(transport.submitted == 2000); CHECK([runner.status[@"run"] isEqual:NSNull.null]);
        CHECK(deliveryCount(store, run, @"confirmed") == 2000);
        CHECK([transport.snapshots.lastObject[@"payload"][@"text"] isEqual:@"original text"]);
        now += 10000; CHECK(![runner tick]); CHECK(transport.submitted == 2000); // No automatic next rule.

        NSString *second = [store startRule:rules[1][@"id"] replay:NO error:NULL]; CHECK(second);
        transport.immediate = NO;
        CHECK([runner activateRun:second account:@"account" error:NULL]);
        now = [runner.status[@"nextMonotonic"] doubleValue]; CHECK([runner tick]);
        CHECK([runner pause:NULL]); now += 60; CHECK(![runner tick]);
        CHECK(deliveryCount(store, second, @"uncertain") == 1);
        CHECK(![runner activateRun:second account:@"account" error:NULL]);
        callback(transport, 2000, @"confirmed", @"late-server"); (void)runner.status;
        CHECK(deliveryCount(store, second, @"confirmed") == 1);
        CHECK([runner.status[@"run"] isEqual:NSNull.null]); // Late final success must release account ownership.

        NSString *replay = [store startRule:rules[1][@"id"] replay:YES error:NULL]; CHECK(replay);
        CHECK([competitor activateRun:replay account:@"account" error:NULL]);
        now = [competitor.status[@"nextMonotonic"] doubleValue]; CHECK([competitor tick]);
        CHECK([competitor end:NULL]);
        NSString *again = [store startRule:rules[1][@"id"] replay:YES error:NULL]; CHECK(again);
        CHECK([runner activateRun:again account:@"account" error:NULL]);
        callback(transport, 2001, @"confirmed", @"ended-late"); (void)competitor.status;
        CHECK(deliveryCount(store, again, @"pending") == 1);
        now = [runner.status[@"nextMonotonic"] doubleValue]; CHECK([runner tick]);
        callback(transport, 2002, @"failed", nil); (void)runner.status;
        CHECK([runner.status[@"halted"] boolValue]);
        CHECK([[store summaryForRun:again error:NULL][@"state"] isEqual:@"completed"]);
        CHECK([runner.status[@"run"] isEqual:NSNull.null]);

        NSString *interrupted = [store startRule:rules[1][@"id"] replay:YES error:NULL]; CHECK(interrupted);
        CHECK([runner activateRun:interrupted account:@"account" error:NULL]);
        now = [runner.status[@"nextMonotonic"] doubleValue]; CHECK([runner tick]); (void)runner.status;
        runner = nil; competitor = nil;
        CHECK([store recoverInterruptedRuns:NULL]);
        runner = newRunner(); CHECK(![runner tick]);
        CHECK(![runner activateRun:interrupted account:@"account" error:NULL]);
        CHECK(deliveryCount(store, interrupted, @"uncertain") == 1);
        CHECK([[store summaryForRun:interrupted error:NULL][@"state"] isEqual:@"completed"]);

        runner = nil; capture = nil; transport = nil; newRunner = nil; store = nil;
        CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: source filters/freeze/atomic confirmation, 2000 paced deliveries, manual resume, timeout, late callbacks and recovery");
    }
    return 0;
}
