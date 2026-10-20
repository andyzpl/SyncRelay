#import <Foundation/Foundation.h>
#import "Core/SRStore.h"
#import "Core/SRConfiguration.h"
#import <sqlite3.h>
#include <assert.h>

static NSUInteger count(NSDictionary *summary, NSString *state) {
    for (NSDictionary *row in summary[@"counts"]) if ([row[@"state"] isEqual:state]) return [row[@"count"] unsignedIntegerValue];
    return 0;
}

int main(void) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
        NSString *path = [directory stringByAppendingPathComponent:@"test.sqlite3"];
        NSError *error = nil;
        SRStore *store = [[SRStore alloc] initWithPath:path error:&error];
        assert(store && !error);
        NSMutableDictionary *draft = [SRConfiguration emptyDraft];
        draft[@"maximum"] = @30;
        assert([store saveConfiguration:draft account:@"account" error:&error]);
        assert([store configurationForAccount:@"other-account" error:&error][@"maximum"] != nil);
        assert([[store configurationForAccount:@"other-account" error:&error][@"maximum"] isEqual:@20]);
        draft[@"minimum"] = @5;
        assert(![store saveConfiguration:draft account:@"account" error:NULL]);
        assert([[store configurationForAccount:@"account" error:&error][@"minimum"] isEqual:@10]);
        NSString *plan = [store createPlanForAccount:@"account" sourceGroup:@"source@chatroom"
            senders:@[@"wxid_sender"] types:@[@"text", @"image"] sourceSnapshot:@{@"id": @"source-message", @"text": @"test"} error:&error];
        assert(plan);
        assert(![store addRuleToPlan:plan name:@"invalid" targets:@[@"invalid"] minimum:9 maximum:20 error:NULL]);
        assert(![store addRuleToPlan:plan name:@"self" targets:@[@"source@chatroom"] minimum:10 maximum:20 error:NULL]);
        NSMutableArray *targets = [NSMutableArray array];
        for (int i = 0; i < 2000; i++) [targets addObject:[NSString stringWithFormat:@"group-%d@chatroom", i]];
        NSString *first = [store addRuleToPlan:plan name:@"first" targets:targets minimum:10 maximum:20 error:&error];
        assert(first);
        assert((![store addRuleToPlan:plan name:@"conflict" targets:@[@"extra@chatroom", targets[0]] minimum:10 maximum:20 error:NULL]));
        assert([store allocatedTargetsForPlan:plan error:&error].count == 2000);
        NSString *second = [store addRuleToPlan:plan name:@"second" targets:@[@"extra@chatroom"] minimum:10 maximum:10 error:&error];
        assert(second);
        assert(![store startRule:second replay:NO error:NULL]);
        NSString *run = [store startRule:first replay:NO error:&error];
        assert(run);
        assert(![store startRule:first replay:YES error:NULL]);
        NSDictionary *delivery = [store claimNextForRun:run error:&error];
        assert(delivery);
        assert(![store claimNextForRun:run error:NULL]);
        assert([store pauseRun:run error:&error]);
        assert(![store startRule:second replay:NO error:NULL]);
        assert(![store claimNextForRun:run error:NULL]);
        store = nil;
        store = [[SRStore alloc] initWithPath:path error:&error];
        assert([[store configurationForAccount:@"account" error:&error][@"maximum"] isEqual:@30]);
        assert([store recoverInterruptedRuns:&error]);
        NSDictionary *summary = [store summaryForRun:run error:&error];
        assert([summary[@"state"] isEqual:@"awaiting_resume"]);
        assert(count(summary, @"uncertain") == 1 && count(summary, @"pending") == 1999);
        assert(![store claimNextForRun:run error:NULL]);
        assert([store resumeRun:run error:&error]);
        assert(![store claimNextForRun:run error:NULL]);
        assert(![store recordResultForDelivery:delivery[@"id"] attempt:@"wrong" state:@"confirmed" messageID:@"server-1" reason:nil error:NULL]);
        assert([store recordResultForDelivery:delivery[@"id"] attempt:delivery[@"attempt_id"] state:@"confirmed" messageID:@"server-1" reason:nil error:&error]);
        assert([store recordResultForDelivery:delivery[@"id"] attempt:delivery[@"attempt_id"] state:@"confirmed" messageID:@"server-1" reason:nil error:&error]);
        for (int i = 1; i < 2000; i++) {
            @autoreleasepool {
                NSDictionary *next = [store claimNextForRun:run error:&error];
                assert(next);
                assert(([store recordResultForDelivery:next[@"id"] attempt:next[@"attempt_id"] state:@"confirmed"
                    messageID:[NSString stringWithFormat:@"server-%d", i + 1] reason:nil error:&error]));
            }
        }
        summary = [store summaryForRun:run error:&error];
        assert(count(summary, @"confirmed") == 2000);
        assert([summary[@"state"] isEqual:@"completed"] && [summary[@"ended_at"] doubleValue] > 0);
        assert(![store startRule:first replay:NO error:NULL]);
        NSString *replay = [store startRule:first replay:YES error:&error];
        assert(replay && ![replay isEqual:run]);
        assert(count([store summaryForRun:replay error:&error], @"pending") == 2000);
        assert(![store startRule:second replay:NO error:NULL]);
        NSDictionary *late = [store claimNextForRun:replay error:&error];
        assert(late);
        assert([store endRun:replay error:&error]);
        NSString *secondRun = [store startRule:second replay:NO error:&error];
        assert(secondRun);
        assert([store recordResultForDelivery:late[@"id"] attempt:late[@"attempt_id"] state:@"confirmed" messageID:@"late-server" reason:nil error:&error]);
        assert(count([store summaryForRun:secondRun error:&error], @"pending") == 1);
        assert([[store summaryForRun:replay error:&error][@"state"] isEqual:@"ended"]);
        NSDictionary *failed = [store claimNextForRun:secondRun error:&error];
        assert(failed);
        assert([store recordResultForDelivery:failed[@"id"] attempt:failed[@"attempt_id"] state:@"failed" messageID:nil reason:@"test failure" error:&error]);
        assert(![[store summaryForRun:secondRun error:&error][@"state"] isEqual:@"completed"]);
        assert([store endRun:secondRun error:&error]);
        assert(count([store summaryForRun:run error:&error], @"confirmed") == 2000);
        store = nil;
        sqlite3 *legacy = NULL;
        assert(sqlite3_open(path.fileSystemRepresentation, &legacy) == SQLITE_OK);
        assert(sqlite3_exec(legacy, "DROP TABLE configurations; PRAGMA user_version=1;", NULL, NULL, NULL) == SQLITE_OK);
        assert(sqlite3_close(legacy) == SQLITE_OK);
        store = [[SRStore alloc] initWithPath:path error:&error];
        assert(store);
        assert(count([store summaryForRun:run error:&error], @"confirmed") == 2000);
        assert([store saveConfiguration:[SRConfiguration emptyDraft] account:@"account" error:&error]);
        store = nil;
        assert([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
        puts("PASS: SQLite fan-out, allocation rollback, serial execution, recovery, replay and late callbacks");
    }
    return 0;
}
