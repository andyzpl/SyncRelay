#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ImageIO/ImageIO.h>
#import "Adapter/SRSmallGroupSession.h"
#import "Core/SRStore.h"
#import "Core/SRConfiguration.h"
#import "Core/SRImageAssetStore.h"
#import "Core/SRExecutionProgress.h"
#include <assert.h>
#include <sqlite3.h>
#define CHECK(...) assert((__VA_ARGS__))

@interface SmallHost : NSObject <SRSmallGroupHost>
@property(nonatomic, copy) BOOL (^allowed)(void);
@property(nonatomic, copy) SRSendCompletion completion;
@property(nonatomic, copy) NSDictionary *request;
@property(nonatomic, strong) NSMutableDictionary *facts;
@property(nonatomic) BOOL ready;
@property(nonatomic) NSUInteger calls;
- (void)finish;
@end
@implementation SmallHost
- (instancetype)init {
    self = [super init];
    if (self) {
        _ready = YES;
        _facts = [@{@"schema": @1, @"submissionAttempted": @YES, @"hostReturned": @YES, @"observing": @YES,
            @"localIDPresent": @YES, @"serverIDPresent": @YES, @"lookupAttempts": @1, @"lookupMisses": @0,
            @"identityConflicts": @0, @"observationServiceCheckFailed": @NO, @"problem": @"",
            @"materialValidated": @YES, @"imageSetterInvoked": @YES,
            @"samples": @[@{@"source": @"local_readback", @"localIDPresent": @YES, @"serverIDPresent": @YES}]} mutableCopy];
    }
    return self;
}
- (BOOL)readyForAccount:(__unused NSString *)account error:(__unused NSError **)error { CHECK(NSThread.isMainThread); return self.ready && self.allowed(); }
- (void)submitRequest:(NSDictionary *)request completion:(SRSendCompletion)completion {
    CHECK(NSThread.isMainThread && self.allowed() && self.calls == 0); self.calls++;
    self.request = request; self.completion = completion;
}
- (void)finish { self.facts[@"observing"] = @NO; self.completion(@"uncertain", nil, @"submitted_delivery_unknown"); }
- (void)stopObservation { if (self.completion) { self.facts[@"problem"] = @"stopped"; [self finish]; } }
- (NSDictionary *)diagnostics { return [self.facts copy]; }
@end

static NSMutableDictionary *draft(NSUInteger size) {
    NSMutableDictionary *value = [SRConfiguration emptyDraft];
    value[@"sourceGroup"] = @{@"id": @"mother@chatroom", @"name": @"Synthetic mother"};
    value[@"senders"] = @[@{@"id": @"sender", @"name": @"Synthetic sender"}]; value[@"minimum"] = @10; value[@"maximum"] = @10;
    NSMutableArray *targets = [NSMutableArray array];
    for (NSUInteger i = 0; i < size; i++) [targets addObject:@{@"id": [NSString stringWithFormat:@"target%lu@chatroom", (unsigned long)i], @"name": @"Synthetic target"}];
    value[@"rules"] = @[@{@"id": @"first", @"name": @"First", @"targets": targets},
        @{@"id": @"second", @"name": @"Second", @"targets": @[@{@"id": @"second@chatroom", @"name": @"Second"}]}];
    value[@"excludedGroups"] = @[@{@"id": @"excluded@chatroom", @"name": @"Excluded"}];
    return value;
}
static NSMutableDictionary *source(NSString *identifier) {
    return [@{@"account": @"account", @"group": @"mother@chatroom", @"sender": @"sender", @"messageID": identifier,
        @"type": @"text", @"generatedByRelay": @NO, @"payload": @{@"text": @"Synthetic text only"}} mutableCopy];
}
static NSArray *makePlan(SRStore *store, NSString *identifier, NSUInteger size) {
    NSString *plan = [store createPlanFromConfiguration:draft(size) envelope:source(identifier) account:@"account" error:NULL]; CHECK(plan);
    return [store rulesForPlan:plan error:NULL];
}
static NSString *latest(SRStore *store, NSString *rule) { return [store historyForRule:rule account:@"account" limit:1 offset:0 error:NULL][0][@"id"]; }
static NSUInteger count(SRStore *store, NSString *run, NSString *state) {
    for (NSDictionary *row in [store summaryForRun:run error:NULL][@"counts"]) if ([row[@"state"] isEqual:state]) return [row[@"count"] unsignedIntegerValue];
    return 0;
}
static void pump(SRSmallGroupSession *session) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false); [session tick]; }
static NSData *png(void) {
    unsigned char pixels[16] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255};
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, 2, 2, 8, 8, color, kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context); NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef output = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(output, image, NULL); CHECK(CGImageDestinationFinalize(output));
    CFRelease(output); CGImageRelease(image); CGContextRelease(context); CGColorSpaceRelease(color); return data;
}

int main(void) {
    @autoreleasepool {
        CHECK(NSThread.isMainThread);
        CHECK(![[SRExecutionProgress modelForStatus:@{}][@"visible"] boolValue]);
        CHECK(![[SRExecutionProgress modelForStatus:@{@"busy": @YES, @"counts": @{@"pending": @-1}}][@"visible"] boolValue]);
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *path = [directory stringByAppendingPathComponent:@"small.sqlite3"];
        __block SRStore *store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        __block double now = 0; __block BOOL environment = YES, targetAllowed = YES, ready = YES;
        __block NSString *account = @"account";
        NSMutableArray<SmallHost *> *hosts = [NSMutableArray array];
        SRSmallGroupSession *(^newSession)(void) = ^SRSmallGroupSession * {
            return [[SRSmallGroupSession alloc] initWithStore:store currentAccount:^NSString *{ return account; }
                environmentAllowed:^BOOL { CHECK(NSThread.isMainThread); return environment; }
                targetAllowed:^BOOL(NSString *target) { CHECK(NSThread.isMainThread); return targetAllowed && ![target isEqual:@"mother@chatroom"] && ![target isEqual:@"excluded@chatroom"]; }
                hostFactory:^id<SRSmallGroupHost>(__unused NSDictionary *value, BOOL (^allowed)(void)) {
                    CHECK(NSThread.isMainThread);
                    SmallHost *host = [[SmallHost alloc] init]; host.allowed = allowed; host.ready = ready; [hosts addObject:host]; return host;
                } clock:^double { return now; } random:^double { return 0.5; }];
        };
        SRSmallGroupSession *session = newSession();
        NSArray *rules = makePlan(store, @"first", 3); NSString *rule = rules[0][@"id"];
        CHECK(![session startRule:rule account:@"other" error:NULL]); CHECK(!session.busy && !session.needsIdleTimer);
        CHECK([session startRule:rule account:@"account" error:NULL]); NSString *run = latest(store, rule);
        CHECK(session.busy && session.needsIdleTimer && !session.usedNativeHost);
        CHECK([session progressBelongsToCurrentAccount]); account = @"other"; CHECK(![session progressBelongsToCurrentAccount]); account = @"account";
        CHECK([[SRExecutionProgress modelForStatus:session.status][@"total"] isEqual:@3]);
        CHECK(![session startRule:rules[1][@"id"] account:@"account" error:NULL]);
        CHECK(![store claimTextExperiment:source(@"first") configuration:draft(3) account:@"account" target:@"target0@chatroom" error:NULL]);
        now = 9.99; [session tick]; pump(session); CHECK(hosts.count == 0);
        now = 10; [session tick]; CHECK(hosts.count == 0); pump(session); CHECK(hosts.count == 1 && hosts[0].calls == 1);
        CHECK([hosts[0].request[@"target"] isEqual:@"target0@chatroom"] && [hosts[0].request[@"payload"][@"text"] isEqual:@"Synthetic text only"]);
        now = 50; [hosts[0] finish]; [session tick]; CHECK(count(store, run, @"submitted") == 1 && count(store, run, @"confirmed") == 0);
        // The gap begins after delayed native completion, not the old claim time.
        now = 59.99; [session tick]; pump(session); CHECK(hosts.count == 1);
        now = 60; [session tick]; pump(session); CHECK(hosts.count == 2);
        CHECK([session togglePauseForCurrentAccount:NULL] && session.needsIdleTimer);
        NSDictionary *progress = [SRExecutionProgress modelForStatus:session.status];
        CHECK([progress[@"phase"] isEqual:@"settling"] && ![progress[@"actionEnabled"] boolValue]);
        CHECK(![session resumeRun:run account:@"account" error:NULL]);
        [hosts[1] finish]; [session tick]; CHECK(!session.needsIdleTimer && count(store, run, @"submitted") == 2);
        progress = [SRExecutionProgress modelForStatus:session.status];
        CHECK([progress[@"phase"] isEqual:@"paused"] && [progress[@"action"] isEqual:@"resume"] && [progress[@"processed"] isEqual:@2]);
        now = 500; [session tick]; pump(session); CHECK(hosts.count == 2);
        CHECK([session togglePauseForCurrentAccount:NULL]); [session tick]; pump(session); CHECK(hosts.count == 2);
        now = 510; [session tick]; pump(session); CHECK(hosts.count == 3);
        CHECK([hosts[2].request[@"target"] isEqual:@"target2@chatroom"]);
        [hosts[2] finish]; [session tick]; CHECK(!session.busy && !session.needsIdleTimer);
        CHECK([[store summaryForRun:run error:NULL][@"state"] isEqual:@"completed"] && count(store, run, @"submitted") == 3);
        CHECK([store historyForRule:rules[1][@"id"] account:@"account" limit:1 offset:0 error:NULL].count == 0);
        [hosts[0] finish]; [session tick]; CHECK(count(store, run, @"submitted") == 3);
        CHECK(![session startRule:rule account:@"account" error:NULL]);

        NSArray *big = makePlan(store, @"big", 4); CHECK(![session startRule:big[0][@"id"] account:@"account" error:NULL]);
        CHECK([store historyForRule:big[0][@"id"] account:@"account" limit:1 offset:0 error:NULL].count == 0);

        // Cancellation before main-queue dispatch cannot invoke a native host.
        rules = makePlan(store, @"queued", 3); rule = rules[0][@"id"];
        CHECK([session startRule:rule account:@"account" error:NULL]); run = latest(store, rule);
        now += 10; [session tick]; CHECK([session pauseForAccount:@"account" error:NULL]); pump(session);
        CHECK(hosts.count == 3 && count(store, run, @"uncertain") == 1 && count(store, run, @"pending") == 2);
        CHECK([session resumeRun:run account:@"account" error:NULL]); now += 10; [session tick]; pump(session); CHECK(hosts.count == 4);
        CHECK([hosts.lastObject.request[@"target"] isEqual:@"target1@chatroom"]);
        environment = NO; [session becameInactive]; CHECK(!session.needsIdleTimer); pump(session);
        CHECK(count(store, run, @"uncertain") == 2); environment = YES; now += 1000; [session tick]; pump(session); CHECK(hosts.count == 4);
        CHECK([session resumeRun:run account:@"account" error:NULL]); now += 10; [session tick]; pump(session);
        CHECK(hosts.count == 5 && [hosts.lastObject.request[@"target"] isEqual:@"target2@chatroom"]);
        [hosts.lastObject finish]; [session tick]; CHECK(!session.busy && count(store, run, @"submitted") == 1);

        // Restart keeps interrupted native claims and only sends pending targets.
        rules = makePlan(store, @"restart", 3); rule = rules[0][@"id"];
        CHECK([session startRule:rule account:@"account" error:NULL]); run = latest(store, rule);
        now += 10; [session tick]; pump(session); CHECK(hosts.count == 6);
        __weak SRSmallGroupSession *old = session; session = nil; CHECK(!old); store = nil;
        store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store && [store recoverInterruptedRuns:NULL]);
        CHECK(count(store, run, @"uncertain") == 1 && count(store, run, @"pending") == 2);
        session = newSession(); now += 1000; [session tick]; pump(session); CHECK(hosts.count == 6);
        account = @"other"; CHECK(![session resumeRun:run account:@"account" error:NULL]); account = @"account";
        CHECK([session resumeRun:run account:@"account" error:NULL]); [session tick]; pump(session); CHECK(hosts.count == 6);
        now += 10; [session tick]; pump(session); CHECK(hosts.count == 7);
        [hosts[5] finish]; [session tick]; CHECK(count(store, run, @"uncertain") == 1 && count(store, run, @"submitting") == 1);
        [hosts.lastObject finish]; [session tick]; now += 10; [session tick]; pump(session); CHECK(hosts.count == 8);
        [hosts.lastObject finish]; [session tick]; CHECK(!session.busy && count(store, run, @"submitted") == 2);

        // Missing readback, service/identity problems and preflight failures never become submitted.
        for (NSString *key in @[@"serverIDPresent", @"hostReturned", @"lookupMisses", @"identityConflicts", @"observationServiceCheckFailed", @"samples"] ) {
            rules = makePlan(store, [@"bad-" stringByAppendingString:key], 1); rule = rules[0][@"id"];
            CHECK([session startRule:rule account:@"account" error:NULL]); run = latest(store, rule);
            now += 10; [session tick]; pump(session);
            if ([key isEqual:@"samples"]) hosts.lastObject.facts[key] = @[];
            else hosts.lastObject.facts[key] = [@[@"serverIDPresent", @"hostReturned"] containsObject:key] ? @NO : @1;
            [hosts.lastObject finish]; [session tick];
            CHECK(!session.busy && count(store, run, @"uncertain") == 1 && count(store, run, @"submitted") == 0);
        }
        rules = makePlan(store, @"preflight", 1); rule = rules[0][@"id"]; ready = NO;
        CHECK([session startRule:rule account:@"account" error:NULL]); run = latest(store, rule);
        now += 10; [session tick]; pump(session); CHECK(hosts.lastObject.calls == 0);
        CHECK(count(store, run, @"uncertain") == 1 && !session.busy); ready = YES;
        rules = makePlan(store, @"target", 3); rule = rules[0][@"id"]; targetAllowed = NO;
        CHECK([session startRule:rule account:@"account" error:NULL]); run = latest(store, rule);
        NSUInteger oldCount = hosts.count; now += 10; [session tick]; pump(session); CHECK(hosts.count == oldCount);
        CHECK(count(store, run, @"uncertain") == 1 && !session.needsIdleTimer);
        CHECK([session endRun:run account:@"account" error:NULL]); targetAllowed = YES;

        // Native claims are exact, durable and never transferable to another delivery/source/account.
        rules = makePlan(store, @"claims", 3); rule = rules[0][@"id"];
        run = [store startSmallGroupRule:rule account:@"account" error:NULL]; CHECK(run);
        NSDictionary *delivery = [store claimNextForRun:run error:NULL]; CHECK(delivery);
        CHECK(![store claimSmallGroupDelivery:delivery source:source(@"different") account:@"account" error:NULL]);
        CHECK(![store claimSmallGroupDelivery:delivery source:source(@"claims") account:@"other" error:NULL]);
        sqlite3 *db = NULL; CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
        CHECK(sqlite3_exec(db, "CREATE TRIGGER reject_native BEFORE INSERT ON native_attempt_claims BEGIN SELECT RAISE(ABORT,'synthetic storage failure'); END", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(![store claimSmallGroupDelivery:delivery source:source(@"claims") account:@"account" error:NULL]);
        CHECK(sqlite3_exec(db, "DROP TRIGGER reject_native", NULL, NULL, NULL) == SQLITE_OK); CHECK(sqlite3_close(db) == SQLITE_OK);
        CHECK([store claimSmallGroupDelivery:delivery source:source(@"claims") account:@"account" error:NULL]);
        CHECK(![store claimSmallGroupDelivery:delivery source:source(@"claims") account:@"account" error:NULL]);
        store = nil; store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store && [store recoverInterruptedRuns:NULL]);
        CHECK(![store claimSmallGroupDelivery:delivery source:source(@"claims") account:@"account" error:NULL]);
        CHECK([store endRun:run error:NULL]);

        // Old single-target claims exclude the source from real batch execution.
        CHECK([store claimTextExperiment:source(@"legacy") configuration:draft(3) account:@"account" target:@"target0@chatroom" error:NULL]);
        rules = makePlan(store, @"legacy", 3); CHECK(![store startSmallGroupRule:rules[0][@"id"] account:@"account" error:NULL]);

        // Images use the same scope/queue, but require actual image submission evidence.
        NSMutableDictionary *image = source(@"image"); image[@"type"] = @"image";
        image[@"payload"] = [store.imageAssets saveData:png() source:image error:NULL]; CHECK(image[@"payload"]);
        NSString *plan = [store createPlanFromConfiguration:draft(3) envelope:image account:@"account" error:NULL]; CHECK(plan);
        rules = [store rulesForPlan:plan error:NULL]; rule = rules[0][@"id"]; session = newSession();
        CHECK([session startRule:rule account:@"account" error:NULL]); run = latest(store, rule);
        for (NSUInteger i = 0; i < 3; i++) {
            now += 10; [session tick]; pump(session); CHECK([hosts.lastObject.request[@"type"] isEqual:@"image"]);
            CHECK([hosts.lastObject.request[@"payload"] isEqual:image[@"payload"]]); [hosts.lastObject finish]; [session tick];
        }
        CHECK(!session.busy && count(store, run, @"submitted") == 3 && count(store, run, @"confirmed") == 0);
        CHECK([session.status[@"state"] isEqual:@"completed"] && [session.status[@"counts"][@"submitted"] isEqual:@3]);
        CHECK([session startRule:rules[1][@"id"] account:@"account" error:NULL]);
        NSString *lastRun = latest(store, rules[1][@"id"]);
        [store.imageAssets discardPayload:image[@"payload"]];
        CHECK(![store smallGroupRun:lastRun account:@"account" error:NULL]);
        CHECK(![session endRun:lastRun account:@"other" error:NULL]);
        CHECK([session endRun:lastRun account:@"account" error:NULL]); CHECK(!session.busy && !session.needsIdleTimer);
        CHECK(count(store, lastRun, @"cancelled") == 1);
        NSData *report = [NSJSONSerialization dataWithJSONObject:session.diagnostics options:0 error:NULL]; CHECK(report);
        NSString *json = [[NSString alloc] initWithData:report encoding:NSUTF8StringEncoding];
        for (NSString *secret in @[@"mother@chatroom", @"target0@chatroom", @"Synthetic text only", @"sourceMessageID"])
            CHECK(![json containsString:secret]);
        session = nil; store = nil;
        CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: real-session bridge mocks, main-thread dispatch, 3-target limits, completion pacing, pause/restart, durable native claims, strict evidence and image scope");
    }
    return 0;
}
