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
        assert(store.schemaVersion == 14);
        NSDictionary *migration = store.migrationDiagnostics;
        assert([migration[@"schema"] isEqual:@1] && [migration[@"sourceVersion"] isEqual:@0] &&
            [migration[@"targetVersion"] isEqual:@14] && [migration[@"performed"] boolValue] &&
            [migration[@"committed"] boolValue] && ![migration[@"rowCountsComparable"] boolValue]);
        assert([migration[@"foreignKeyCheckPassed"] boolValue]);
        assert([migration[@"versionRelationsPassed"] boolValue]);
        assert(![[store operationsEnabledForAccount:@"account" error:&error] boolValue]);
        assert(![store setOperationsEnabled:YES account:@"account" error:NULL]);
        assert(![store setOperationsEnabled:YES account:@"" error:NULL]);
        NSMutableDictionary *draft = [SRConfiguration emptyDraft];
        assert([draft[@"minimum"] isEqual:@5] && [draft[@"maximum"] isEqual:@10]);
        draft[@"maximum"] = @30;
        assert([store saveConfiguration:draft account:@"account" error:&error]);
        assert([store configurationForAccount:@"other-account" error:&error][@"maximum"] != nil);
        assert([[store configurationForAccount:@"other-account" error:&error][@"maximum"] isEqual:@10]);
        draft[@"minimum"] = @2;
        assert(![store saveConfiguration:draft account:@"account" error:NULL]);
        assert([[store configurationForAccount:@"account" error:&error][@"minimum"] isEqual:@5]);
        draft[@"minimum"] = @3;
        assert([store saveConfiguration:draft account:@"account" error:&error]);
        assert([[store configurationForAccount:@"account" error:&error][@"minimum"] isEqual:@3]);
        NSMutableDictionary *experimentDraft = [SRConfiguration emptyDraft];
        experimentDraft[@"sourceGroup"] = @{ @"id": @"source@chatroom", @"name": @"Source" };
        experimentDraft[@"senders"] = @[ @{ @"id": @"wxid_sender", @"name": @"Sender" } ];
        experimentDraft[@"types"] = @[ @"text" ];
        experimentDraft[@"rules"] = @[ @{ @"id": @"experiment-rule", @"name": @"Rule 1", @"targets": @[ @{ @"id": @"target@chatroom", @"name": @"Target" } ] } ];
        assert([SRConfiguration validateDraft:experimentDraft error:&error]);
        assert([store saveConfiguration:experimentDraft account:@"account" error:&error]);
        assert([store setOperationsEnabled:YES account:@"account" error:&error]);
        assert([[store operationsEnabledForAccount:@"account" error:&error] boolValue]);
        assert(![[store operationsEnabledForAccount:@"other-account" error:&error] boolValue]);
        SRStore *reopened = [[SRStore alloc] initWithPath:path error:&error];
        assert([[reopened operationsEnabledForAccount:@"account" error:&error] boolValue]);
        assert([reopened setOperationsEnabled:NO account:@"account" error:&error]);
        assert(![[store operationsEnabledForAccount:@"account" error:&error] boolValue]);
        assert([[store configurationForAccount:@"account" error:&error] isEqual:experimentDraft]);
        sqlite3 *faultDB = NULL;
        assert(sqlite3_open(path.fileSystemRepresentation, &faultDB) == SQLITE_OK);
        assert(sqlite3_exec(faultDB, "CREATE TRIGGER reject_operations BEFORE INSERT ON operations_preferences BEGIN SELECT RAISE(ABORT,'test write failure'); END", NULL, NULL, NULL) == SQLITE_OK);
        assert(![store setOperationsEnabled:YES account:@"account" error:NULL]);
        assert(![[store operationsEnabledForAccount:@"account" error:&error] boolValue]);
        assert(sqlite3_exec(faultDB, "DROP TRIGGER reject_operations", NULL, NULL, NULL) == SQLITE_OK);
        assert(sqlite3_close(faultDB) == SQLITE_OK);
        reopened = nil;
        assert([store saveConfiguration:draft account:@"account" error:&error]);
        NSDictionary *experimentSource = @{ @"account": @"account", @"group": @"source@chatroom", @"sender": @"wxid_sender",
            @"messageID": @"experiment-source", @"type": @"text", @"generatedByRelay": @NO, @"payload": @{ @"text": @"hello" } };
        assert([store claimTextExperiment:experimentSource configuration:experimentDraft account:@"account" target:@"target@chatroom" error:&error]);
        assert(![store claimTextExperiment:experimentSource configuration:experimentDraft account:@"account" target:@"target@chatroom" error:NULL]);
        assert([[store textExperimentSummaryForAccount:@"account" error:&error][@"deliveryOutcome"] isEqual:@"uncertain"]);
        NSString *plan = [store createPlanForAccount:@"account" sourceGroup:@"source@chatroom"
            senders:@[@"wxid_sender"] types:@[@"text", @"image"] sourceSnapshot:@{@"id": @"source-message", @"text": @"test"} error:&error];
        assert(plan);
        assert(![store addRuleToPlan:plan name:@"invalid" targets:@[@"invalid"] minimum:2 maximum:20 error:NULL]);
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
        NSMutableDictionary *nextExperiment = [experimentSource mutableCopy]; nextExperiment[@"messageID"] = @"experiment-source-2";
        assert(![store claimTextExperiment:nextExperiment configuration:experimentDraft account:@"account" target:@"target@chatroom" error:NULL]);
        assert(![store startRule:first replay:YES error:NULL]);
        NSDictionary *delivery = [store claimNextForRun:run error:&error];
        assert(delivery);
        assert(![store claimNextForRun:run error:NULL]);
        assert([store pauseRun:run error:&error]);
        assert(![store startRule:second replay:NO error:NULL]);
        assert(![store claimNextForRun:run error:NULL]);
        store = nil;
        store = [[SRStore alloc] initWithPath:path error:&error];
        assert(![store claimTextExperiment:experimentSource configuration:experimentDraft account:@"account" target:@"target@chatroom" error:NULL]);
        assert([[store textExperimentSummaryForAccount:@"account" error:&error][@"claimed"] boolValue]);
        assert([[store configurationForAccount:@"account" error:&error][@"maximum"] isEqual:@30]);
        assert([[store configurationForAccount:@"account" error:&error][@"minimum"] isEqual:@3]);
        assert([store recoverInterruptedRuns:&error]);
        NSDictionary *summary = [store summaryForRun:run error:&error];
        assert([summary[@"state"] isEqual:@"awaiting_resume"]);
        assert(count(summary, @"uncertain") == 1 && count(summary, @"pending") == 1999);
        assert(![store claimNextForRun:run error:NULL]);
        assert(![store recordResultForDelivery:delivery[@"id"] attempt:@"wrong" state:@"confirmed" messageID:@"server-1" reason:nil error:NULL]);
        assert([store recordResultForDelivery:delivery[@"id"] attempt:delivery[@"attempt_id"] state:@"confirmed" messageID:@"server-1" reason:nil error:&error]);
        assert([store resumeRun:run error:&error]);
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
        assert([[store summaryForRun:secondRun error:&error][@"state"] isEqual:@"completed"]);
        assert(count([store summaryForRun:secondRun error:&error], @"failed") == 1);
        assert(![store claimTextExperiment:experimentSource configuration:experimentDraft account:@"account" target:@"target@chatroom" error:NULL]);
        assert(![store claimTextExperiment:nextExperiment configuration:experimentDraft account:@"account" target:@"source@chatroom" error:NULL]);
        assert(![store claimTextExperiment:nextExperiment configuration:experimentDraft account:@"account" target:@"unallocated@chatroom" error:NULL]);
        assert([store claimTextExperiment:nextExperiment configuration:experimentDraft account:@"account" target:@"target@chatroom" error:&error]);
        assert(count([store summaryForRun:run error:&error], @"confirmed") == 2000);

        /* A schema-14 file with an orphaned foreign-key row must be rejected
         * before the open-time trigger refresh can commit. */
        NSString *damagedPath = [directory stringByAppendingPathComponent:@"damaged.sqlite3"];
        SRStore *damaged = [[SRStore alloc] initWithPath:damagedPath error:&error];
        assert(damaged);
        damaged = nil;
        sqlite3 *damagedDB = NULL;
        assert(sqlite3_open(damagedPath.fileSystemRepresentation, &damagedDB) == SQLITE_OK);
        assert(sqlite3_exec(damagedDB, "PRAGMA foreign_keys=OFF; INSERT INTO allocations(plan_id,target,rule_id,position) VALUES('missing-plan','orphan@chatroom','missing-rule',0); PRAGMA user_version=14;", NULL, NULL, NULL) == SQLITE_OK);
        assert(sqlite3_close(damagedDB) == SQLITE_OK);
        damaged = [[SRStore alloc] initWithPath:damagedPath error:&error];
        assert(!damaged && error);
        assert([NSFileManager.defaultManager removeItemAtPath:damagedPath error:nil]);
        NSString *damagedMediaPath = [damagedPath stringByAppendingString:@".media"];
        if ([NSFileManager.defaultManager fileExistsAtPath:damagedMediaPath])
            assert([NSFileManager.defaultManager removeItemAtPath:damagedMediaPath error:nil]);
        /* A current-version pointer is a composite relation (item, account,
         * kind and highest ordinal), so foreign_key_check alone cannot catch
         * an orphaned pointer. Opening the schema-14 file must reject it. */
        NSString *damagedVersionPath = [directory stringByAppendingPathComponent:@"damaged-version.sqlite3"];
        SRStore *damagedVersion = [[SRStore alloc] initWithPath:damagedVersionPath error:&error];
        assert(damagedVersion);
        damagedVersion = nil;
        sqlite3 *damagedVersionDB = NULL;
        assert(sqlite3_open(damagedVersionPath.fileSystemRepresentation, &damagedVersionDB) == SQLITE_OK);
        assert(sqlite3_exec(damagedVersionDB, "PRAGMA foreign_keys=OFF; INSERT INTO library_items(id,account,kind,created_at,updated_at,current_version_id) VALUES('item','account','text',1,1,'missing-version'); PRAGMA user_version=14;", NULL, NULL, NULL) == SQLITE_OK);
        assert(sqlite3_close(damagedVersionDB) == SQLITE_OK);
        damagedVersion = [[SRStore alloc] initWithPath:damagedVersionPath error:&error];
        assert(!damagedVersion && error);
        assert([NSFileManager.defaultManager removeItemAtPath:damagedVersionPath error:nil]);
        NSString *damagedVersionMediaPath = [damagedVersionPath stringByAppendingString:@".media"];
        if ([NSFileManager.defaultManager fileExistsAtPath:damagedVersionMediaPath])
            assert([NSFileManager.defaultManager removeItemAtPath:damagedVersionMediaPath error:nil]);
        /* Foreign keys do not encode account ownership. A content source
         * carrying another account must still make a schema-14 open fail
         * before any trigger refresh or media cleanup can commit. */
        NSString *damagedSourcePath = [directory stringByAppendingPathComponent:@"damaged-source.sqlite3"];
        SRStore *damagedSource = [[SRStore alloc] initWithPath:damagedSourcePath error:&error];
        assert(damagedSource);
        damagedSource = nil;
        sqlite3 *damagedSourceDB = NULL;
        assert(sqlite3_open(damagedSourcePath.fileSystemRepresentation, &damagedSourceDB) == SQLITE_OK);
        const char *crossAccountSource =
            "PRAGMA foreign_keys=OFF;"
            "INSERT INTO operations_contents(id,account,source_group,message_id,configuration,envelope,captured_at) "
            "VALUES('content','account','mother@chatroom','message','{}','{}',1);"
            "INSERT INTO content_sources(content_id,account,source_kind,library_item_id,library_version_id,recorded_at) "
            "VALUES('content','other-account','group_sync',NULL,NULL,1);"
            "PRAGMA user_version=14;";
        assert(sqlite3_exec(damagedSourceDB, crossAccountSource, NULL, NULL, NULL) == SQLITE_OK);
        assert(sqlite3_close(damagedSourceDB) == SQLITE_OK);
        damagedSource = [[SRStore alloc] initWithPath:damagedSourcePath error:&error];
        assert(!damagedSource && error);
        assert([NSFileManager.defaultManager removeItemAtPath:damagedSourcePath error:nil]);
        NSString *damagedSourceMediaPath = [damagedSourcePath stringByAppendingString:@".media"];
        if ([NSFileManager.defaultManager fileExistsAtPath:damagedSourceMediaPath])
            assert([NSFileManager.defaultManager removeItemAtPath:damagedSourceMediaPath error:nil]);
        /* Media references are account-scoped too; a foreign-key check cannot
         * detect a reference that points at another account's asset. */
        NSString *damagedMediaRefPath = [directory stringByAppendingPathComponent:@"damaged-media-ref.sqlite3"];
        SRStore *damagedMediaRef = [[SRStore alloc] initWithPath:damagedMediaRefPath error:&error];
        assert(damagedMediaRef);
        damagedMediaRef = nil;
        sqlite3 *damagedMediaRefDB = NULL;
        assert(sqlite3_open(damagedMediaRefPath.fileSystemRepresentation, &damagedMediaRefDB) == SQLITE_OK);
        const char *crossAccountMediaReference =
            "PRAGMA foreign_keys=OFF;"
            "INSERT INTO media_assets(token,account,scope_kind,scope_sha256,sha256,byte_count,created_at) "
            "VALUES('token','account','message_library','scope','digest',1,1);"
            "INSERT INTO media_references(account,token,owner_kind,owner_id,created_at) "
            "VALUES('other-account','token','plan','missing-plan',1);"
            "PRAGMA user_version=14;";
        assert(sqlite3_exec(damagedMediaRefDB, crossAccountMediaReference, NULL, NULL, NULL) == SQLITE_OK);
        assert(sqlite3_close(damagedMediaRefDB) == SQLITE_OK);
        damagedMediaRef = [[SRStore alloc] initWithPath:damagedMediaRefPath error:&error];
        assert(!damagedMediaRef && error);
        assert([NSFileManager.defaultManager removeItemAtPath:damagedMediaRefPath error:nil]);
        NSString *damagedMediaRefMediaPath = [damagedMediaRefPath stringByAppendingString:@".media"];
        if ([NSFileManager.defaultManager fileExistsAtPath:damagedMediaRefMediaPath])
            assert([NSFileManager.defaultManager removeItemAtPath:damagedMediaRefMediaPath error:nil]);
        store = nil;
        sqlite3 *legacy = NULL;
        assert(sqlite3_open(path.fileSystemRepresentation, &legacy) == SQLITE_OK);
        assert(sqlite3_exec(legacy, "DROP TABLE configurations; PRAGMA user_version=1;", NULL, NULL, NULL) == SQLITE_OK);
        assert(sqlite3_close(legacy) == SQLITE_OK);
        store = [[SRStore alloc] initWithPath:path error:&error];
        assert(store);
        assert(store.schemaVersion == 14);
        migration = store.migrationDiagnostics;
        assert([migration[@"sourceVersion"] isEqual:@1] && [migration[@"performed"] boolValue] &&
            [migration[@"committed"] boolValue] && [migration[@"rowCountsComparable"] boolValue] &&
            [migration[@"legacyRowCountsUnchanged"] boolValue] &&
            [migration[@"foreignKeyCheckPassed"] boolValue]);
        assert([migration[@"versionRelationsPassed"] boolValue]);
        assert(count([store summaryForRun:run error:&error], @"confirmed") == 2000);
        assert([store saveConfiguration:[SRConfiguration emptyDraft] account:@"account" error:&error]);
        store = nil;
        assert([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
        puts("PASS: SQLite fan-out, allocation rollback, serial execution, recovery, replay and late callbacks");
    }
    return 0;
}
