#import <Foundation/Foundation.h>
#import "Core/SRRuntimeLog.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

int main(void) {
    @autoreleasepool {
        SRRuntimeLog *log = [[SRRuntimeLog alloc] init];
        [log record:@"untrusted_wxid_secret" facts:@{}]; CHECK([log.snapshot[@"events"] count] == 0);
        NSMutableDictionary *facts = [@{@"senderCount": @1, @"sourceSelected": @YES, @"messageID": @123456,
            @"wxid": @"wxid_secret", @"group": @"secret@chatroom", @"body": @"private message",
            @"ruleCount": @"private message", @"errorCode": @14} mutableCopy];
        [log record:@"capture_arm_failed" facts:facts]; facts[@"senderCount"] = @99;
        NSDictionary *event = [log.snapshot[@"events"] lastObject];
        CHECK([event[@"facts"] count] == 3 && [event[@"facts"][@"senderCount"] isEqual:@1]);
        NSString *serialized = log.snapshot.description;
        for (NSString *secret in @[@"wxid_secret", @"secret@chatroom", @"private message", @"messageID"])
            CHECK(![serialized containsString:secret]);
        [log record:@"operations_group_cancelled" facts:@{@"reasonCode": @7, @"targetCount": @20,
            @"account": @"account-secret", @"runID": @"run-secret"}];
        event = [log.snapshot[@"events"] lastObject];
        CHECK([event[@"event"] isEqual:@"operations_group_cancelled"]);
        CHECK([event[@"facts"] count] == 2 && [event[@"facts"][ @"reasonCode"] isEqual:@7] &&
            [event[@"facts"][ @"targetCount"] isEqual:@20]);
        CHECK(![log.snapshot.description containsString:@"account-secret"] &&
            ![log.snapshot.description containsString:@"run-secret"]);
        NSArray *operationEvents = @[@"operations_enabled", @"operations_disabled", @"operations_plan_prepared",
            @"operations_group_started", @"operations_group_resumed", @"operations_group_paused",
            @"operations_group_cancelled", @"operations_content_archived", @"operations_legacy_recovered",
            @"operations_command_rejected", @"operations_fault"];
        for (NSString *operationEvent in operationEvents) [log record:operationEvent facts:@{ @"reasonCode": @2 }];
        for (NSString *operationEvent in operationEvents) {
            BOOL found = NO;
            for (NSDictionary *row in log.snapshot[@"events"])
                if ([row[@"event"] isEqual:operationEvent]) { found = YES; break; }
            CHECK(found);
        }
        for (NSUInteger i = 0; i < 1000; i++) [log record:@"capture_attempt" facts:@{@"ruleCount": @(i)}];
        CHECK([log.snapshot[@"events"] count] == 300);
        CHECK([log.snapshot[@"events"][0][@"facts"][@"ruleCount"] isEqual:@700]);
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *path = [directory stringByAppendingPathComponent:@"runtime.json"];
        [log enablePersistenceAtPath:path]; [log record:@"draft_saved" facts:@{@"ruleCount": @2}];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (![NSFileManager.defaultManager fileExistsAtPath:path] && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.02];
        CHECK([NSFileManager.defaultManager fileExistsAtPath:path]);
        SRRuntimeLog *reopened = [[SRRuntimeLog alloc] init]; [reopened enablePersistenceAtPath:path];
        CHECK([reopened.snapshot[@"events"] count] == 300);
        CHECK([[reopened.snapshot[@"events"] lastObject][@"event"] isEqual:@"draft_saved"]);
        CHECK([[reopened.snapshot[@"events"] lastObject][@"previousLaunch"] boolValue]);
        CHECK(![[[reopened.snapshot[@"events"] lastObject] allKeys] containsObject:@"session"]);
        CHECK([NSJSONSerialization isValidJSONObject:reopened.snapshot]);
        log = nil; reopened = nil;
        CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: bounded redacted runtime log, fixed event allowlist, numeric facts, immutable snapshot, coalesced persistence and reopen");
    }
    return 0;
}
