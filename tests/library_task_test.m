#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <sqlite3.h>
#import "Core/SRStore.h"
#import "Core/SRConfiguration.h"
#import "Core/SRImageAssetStore.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

static NSData *png(void) {
    unsigned char pixels[24] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
        255, 255, 0, 255, 0, 255, 255, 255, 255, 0, 255, 255};
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, 2, 3, 8, 8, color, kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef output = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(output, image, NULL); CHECK(CGImageDestinationFinalize(output));
    CFRelease(output); CGImageRelease(image); CGContextRelease(context); CGColorSpaceRelease(color); return data;
}
static NSDictionary *configuration(void) {
    NSMutableDictionary *draft = [SRConfiguration emptyDraft];
    draft[@"sourceGroup"] = @{@"id": @"mother@chatroom", @"name": @"Mother"};
    draft[@"senders"] = @[@{@"id": @"wxid_sender", @"name": @"Sender"}];
    draft[@"types"] = @[@"text"];
    draft[@"rules"] = @[@{@"id": @"rule", @"name": @"First",
        @"targets": @[@{@"id": @"target@chatroom", @"name": @"Target"}]}];
    return draft;
}
static NSDictionary *envelope(NSString *messageID) {
    return @{@"account": @"account", @"group": @"mother@chatroom", @"sender": @"wxid_sender",
        @"messageID": messageID, @"type": @"text", @"generatedByRelay": @NO,
        @"payload": @{@"text": @"group body"}};
}
static NSArray *targets(void) { return @[@"one@chatroom", @"two@chatroom"]; }
static NSUInteger countForRun(NSDictionary *summary, NSString *state) {
    for (NSDictionary *row in summary[@"counts"])
        if ([row[@"state"] isEqual:state]) return [row[@"count"] unsignedIntegerValue];
    return 0;
}
static NSUInteger taskCount(SRStore *store, NSString *account) {
    return [store plansForAccount:account limit:100 offset:0 error:NULL].count;
}
int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *path = [root stringByAppendingPathComponent:@"tasks.sqlite3"];
        NSError *error = nil;
        SRStore *store = [[SRStore alloc] initWithPath:path error:&error]; CHECK(store);

        // 1. A repeated confirmation resolves to the same frozen task.
        NSString *text = [store createLibraryItemForAccount:@"account" kind:@"text"
            payload:@{@"text": @"first body"} capturedAt:100 error:&error];
        CHECK(text && !error);
        NSString *frozenVersion = [store libraryItem:text account:@"account" error:NULL][@"current_version_id"];
        NSUInteger plans = taskCount(store, @"account");
        NSString *first = [store createLibraryTaskForAccount:@"account" item:text version:nil
            confirmationID:@"confirm-1" targets:targets() minimum:5 maximum:10 error:&error];
        CHECK(first && !error);
        NSString *repeated = [store createLibraryTaskForAccount:@"account" item:text version:nil
            confirmationID:@"confirm-1" targets:targets() minimum:5 maximum:10 error:NULL];
        CHECK([repeated isEqual:first]);
        CHECK(taskCount(store, @"account") == plans + 1);
        // The same key with a different request is refused, never re-pointed.
        CHECK(![store createLibraryTaskForAccount:@"account" item:text version:frozenVersion
            confirmationID:@"confirm-1" targets:@[@"one@chatroom"] minimum:5 maximum:10 error:NULL]);
        CHECK(![store createLibraryTaskForAccount:@"account" item:text version:frozenVersion
            confirmationID:@"confirm-1" targets:@[@"two@chatroom", @"one@chatroom"] minimum:5 maximum:10 error:NULL]);
        CHECK(![store createLibraryTaskForAccount:@"account" item:text version:frozenVersion
            confirmationID:@"confirm-1" targets:targets() minimum:6 maximum:10 error:NULL]);
        CHECK(![store createLibraryTaskForAccount:@"account" item:text version:frozenVersion
            confirmationID:@"confirm-1" targets:targets() minimum:5 maximum:12 error:NULL]);
        CHECK([[store createLibraryTaskForAccount:@"account" item:text version:frozenVersion
            confirmationID:@"confirm-1" targets:targets() minimum:5 maximum:10 error:NULL] isEqual:first]);
        CHECK(taskCount(store, @"account") == plans + 1);
        // Confirming never sends: the task has no run until it is started.
        NSDictionary *card = [store libraryTask:first account:@"account" error:&error];
        CHECK(card && !error);
        CHECK(card[@"runID"] == NSNull.null && [card[@"sourceKind"] isEqual:@"message_library"]);
        CHECK([card[@"versionID"] isEqual:frozenVersion]);
        CHECK([card[@"targets"] count] == 2 && [card[@"targetCount"] isEqual:@2]);
        CHECK([card[@"payload"][@"text"] isEqual:@"first body"]);
        CHECK([card[@"dispatchAvailable"] isEqual:@NO]);
        NSDictionary *plan = [store plan:card[@"planID"] account:@"account" error:NULL];
        CHECK([plan[@"source_group"] isEqual:@""]);
        // A frozen snapshot may not carry a group source identity at all.
        NSDictionary *snapshot = plan[@"snapshot"];
        CHECK([snapshot[@"sourceKind"] isEqual:@"message_library"]);
        CHECK(snapshot[@"group"] == nil && snapshot[@"sender"] == nil && snapshot[@"messageID"] == nil);
        CHECK([snapshot[@"generatedByRelay"] isEqual:@NO]);

        // 2. The same version can back two independent tasks.
        NSString *second = [store createLibraryTaskForAccount:@"account" item:text version:frozenVersion
            confirmationID:@"confirm-2" targets:targets() minimum:5 maximum:10 error:&error];
        CHECK(second && ![second isEqual:first] && !error);
        CHECK(taskCount(store, @"account") == plans + 2);
        NSDictionary *firstCard = [store libraryTask:first account:@"account" error:NULL];
        NSDictionary *secondCard = [store libraryTask:second account:@"account" error:NULL];
        CHECK(![firstCard[@"planID"] isEqual:secondCard[@"planID"]]);
        CHECK(![firstCard[@"ruleID"] isEqual:secondCard[@"ruleID"]]);
        CHECK(![store createLibraryTaskForAccount:@"account" item:text version:nil confirmationID:@"confirm-3"
            targets:@[] minimum:5 maximum:10 error:NULL]);
        CHECK(![store createLibraryTaskForAccount:@"account" item:text version:nil confirmationID:@"confirm-3"
            targets:@[@"one@chatroom", @"one@chatroom"] minimum:5 maximum:10 error:NULL]);
        CHECK(![store createLibraryTaskForAccount:@"account" item:text version:nil confirmationID:@"confirm-3"
            targets:@[@"not-a-group"] minimum:5 maximum:10 error:NULL]);
        CHECK(![store createLibraryTaskForAccount:@"account" item:text version:nil confirmationID:@"confirm-3"
            targets:targets() minimum:1 maximum:10 error:NULL]);
        CHECK(![store createLibraryTaskForAccount:@"account" item:text version:nil confirmationID:@""
            targets:targets() minimum:5 maximum:10 error:NULL]);
        CHECK(taskCount(store, @"account") == plans + 2);

        // 3. Editing the entry cannot rewrite a frozen task.
        CHECK([store appendLibraryVersion:text account:@"account" payload:@{@"text": @"edited body"}
            expectedVersion:frozenVersion capturedAt:110 error:NULL]);
        // The same confirmation still resolves to the frozen original version...
        CHECK([[store createLibraryTaskForAccount:@"account" item:text version:frozenVersion
            confirmationID:@"confirm-1" targets:targets() minimum:5 maximum:10 error:NULL] isEqual:first]);
        // ...but it may never be repointed at the newly edited version.
        CHECK(![store createLibraryTaskForAccount:@"account" item:text version:nil confirmationID:@"confirm-1"
            targets:targets() minimum:5 maximum:10 error:NULL]);
        firstCard = [store libraryTask:first account:@"account" error:NULL];
        CHECK([firstCard[@"payload"][@"text"] isEqual:@"first body"]);
        CHECK([firstCard[@"versionID"] isEqual:frozenVersion]);
        secondCard = [store libraryTask:second account:@"account" error:NULL];
        CHECK([secondCard[@"payload"][@"text"] isEqual:@"first body"]);
        CHECK([firstCard[@"frozenSha256"] isEqual:secondCard[@"frozenSha256"]]);

        // 4. A frozen task and its version survive entry-level tampering attempts.
        sqlite3 *db = NULL;
        CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
        CHECK(sqlite3_exec(db, "PRAGMA foreign_keys=ON;"
            " DELETE FROM library_versions WHERE id=(SELECT version_id FROM library_tasks LIMIT 1);",
            NULL, NULL, NULL) != SQLITE_OK);
        CHECK(sqlite3_exec(db, "PRAGMA foreign_keys=ON;"
            " UPDATE library_tasks SET frozen_snapshot='{}';", NULL, NULL, NULL) != SQLITE_OK);
        // Identity, media reference, target scope and origin are immutable too,
        // and a run may never be detached or replaced once attached.
        for (NSString *tamper in @[@"media_token='11111111-1111-1111-1111-111111111111'",
                 @"origin_task_id='forged'", @"target_count=1", @"account='other'",
                 @"created_at=1", @"run_id=NULL"]) {
            NSString *sql = [NSString stringWithFormat:@"PRAGMA foreign_keys=ON; UPDATE library_tasks SET %@;", tamper];
            CHECK(sqlite3_exec(db, sql.UTF8String, NULL, NULL, NULL) != SQLITE_OK);
        }
        CHECK(sqlite3_exec(db, "PRAGMA foreign_keys=ON;"
            " DELETE FROM library_tasks;", NULL, NULL, NULL) != SQLITE_OK);
        CHECK(sqlite3_close(db) == SQLITE_OK);
        CHECK([store libraryTask:first account:@"account" error:NULL]);
        CHECK([[store libraryItem:text account:@"account" error:NULL][@"versions"] count] == 2);

        // 5. Starting the first task creates its own run and pending deliveries.
        NSString *run = [store startLibraryTask:first account:@"account" error:&error];
        CHECK(run && !error);
        CHECK([[store startLibraryTask:first account:@"account" error:NULL] isEqual:run]);
        CHECK([[store libraryTask:first account:@"account" error:NULL][@"runID"] isEqual:run]);
        NSDictionary *summary = [store summaryForRun:run error:NULL];
        CHECK([summary[@"state"] isEqual:@"awaiting_resume"]);
        CHECK(countForRun(summary, @"pending") == 2);
        // An active library run is not an unclaimed legacy run awaiting adoption.
        NSDictionary *projection = [store operationsContentForAccount:@"account" error:NULL];
        CHECK(projection[@"legacyRun"] == NSNull.null);
        CHECK([projection[@"unlinkedActiveRun"] isEqual:@NO]);
        // It is not idle either: the account is occupied by this task's own run,
        // projected explicitly and only for the owning account.
        CHECK([projection[@"libraryOccupancy"][@"taskID"] isEqual:first]);
        CHECK([projection[@"libraryOccupancy"][@"runID"] isEqual:run]);
        CHECK([projection[@"libraryOccupancy"][@"state"] isEqual:@"awaiting_resume"]);
        CHECK([store operationsContentForAccount:@"other" error:NULL][@"libraryOccupancy"] == NSNull.null);
        // One active execution per account: the second task cannot start yet.
        CHECK(![store startLibraryTask:second account:@"account" error:NULL]);
        // Continuing is a different entry from re-sending, and this build has no
        // library dispatch, so the continue entry refuses instead of pretending.
        CHECK(![store resumeRun:run error:NULL]);
        CHECK(![store claimNextForRun:run error:NULL]);

        // 6. Legacy senders and callbacks cannot enter a library task.
        NSString *rule = [store libraryTask:first account:@"account" error:NULL][@"ruleID"];
        CHECK(![store startSmallGroupRule:rule account:@"account" error:NULL]);
        CHECK(![store startRule:rule replay:NO error:NULL]);
        CHECK(![store smallGroupRun:run account:@"account" error:NULL]);
        CHECK(![store claimSmallGroupDelivery:@{@"id": @"delivery", @"run_id": run,
            @"attempt_id": @"attempt", @"target": @"one@chatroom"} source:@{@"account": @"account",
            @"group": @"mother@chatroom", @"sender": @"wxid_sender", @"messageID": @"svr:invented",
            @"type": @"text", @"payload": @{@"text": @"x"}} account:@"account" error:NULL]);
        // Cancelling stays available for every run kind.
        CHECK([store cancelOperationsRun:run account:@"account" error:&error]);
        CHECK([[store summaryForRun:run error:NULL][@"state"] isEqual:@"ended"]);
        // Ending the run releases the occupancy projection, not the frozen task.
        CHECK([store operationsContentForAccount:@"account" error:NULL][@"libraryOccupancy"] == NSNull.null);
        CHECK([[store libraryTask:first account:@"account" error:NULL][@"runID"] isEqual:run]);
        // The freed account slot lets the independent task start its own run.
        NSString *runTwo = [store startLibraryTask:second account:@"account" error:&error];
        CHECK(runTwo && ![runTwo isEqual:run] && !error);
        CHECK([store cancelOperationsRun:runTwo account:@"account" error:NULL]);

        // 7. Group sync and message-library tasks never occupy the account together.
        CHECK([store saveOperationsContent:envelope(@"svr:group-one") configuration:configuration()
            account:@"account" capturedAt:200 error:&error]);
        CHECK(![store createLibraryTaskForAccount:@"account" item:text version:nil confirmationID:@"confirm-4"
            targets:targets() minimum:5 maximum:10 error:NULL]);
        NSString *captured = [store operationsContentForAccount:@"account" error:NULL][@"current"][@"id"];
        CHECK([captured isKindOfClass:NSString.class]);
        CHECK([store archiveOperationsContent:captured account:@"account" error:&error]);
        NSString *third = [store createLibraryTaskForAccount:@"account" item:text version:nil
            confirmationID:@"confirm-4" targets:targets() minimum:5 maximum:10 error:&error];
        CHECK(third && !error);
        NSString *runThree = [store startLibraryTask:third account:@"account" error:&error];
        CHECK(runThree && !error);
        CHECK(![store saveOperationsContent:envelope(@"svr:group-two") configuration:configuration()
            account:@"account" capturedAt:210 error:NULL]);
        CHECK([store cancelOperationsRun:runThree account:@"account" error:NULL]);

        // 8. Account switches see only their own frozen tasks.
        CHECK(![store libraryTask:first account:@"other" error:NULL]);
        CHECK(![store startLibraryTask:second account:@"other" error:NULL]);
        NSString *otherItem = [store createLibraryItemForAccount:@"other" kind:@"text"
            payload:@{@"text": @"other body"} capturedAt:300 error:&error];
        CHECK(otherItem && !error);
        NSString *otherTask = [store createLibraryTaskForAccount:@"other" item:otherItem version:nil
            confirmationID:@"confirm-1" targets:targets() minimum:5 maximum:10 error:&error];
        CHECK(otherTask && ![otherTask isEqual:first] && !error);
        CHECK([store libraryTask:otherTask account:@"other" error:NULL]);
        CHECK(![store libraryTask:otherTask account:@"account" error:NULL]);
        CHECK(taskCount(store, @"account") == plans + 3);

        // 9. Frozen versions, targets and media references survive a reopen.
        NSData *imageBytes = png();
        NSDictionary *asset = [store saveLibraryImageData:imageBytes account:@"account" error:&error];
        CHECK(asset && [SRImageAssetStore validPayload:asset] && !error);
        NSString *image = [store createLibraryItemForAccount:@"account" kind:@"image"
            payload:asset capturedAt:400 error:&error];
        CHECK(image && !error);
        NSString *imageVersion = [store libraryItem:image account:@"account" error:NULL][@"current_version_id"];
        NSString *imageTask = [store createLibraryTaskForAccount:@"account" item:image version:nil
            confirmationID:@"confirm-image" targets:@[@"one@chatroom", @"two@chatroom", @"three@chatroom"]
            minimum:5 maximum:10 error:&error];
        CHECK(imageTask && !error);
        NSString *imageRun = [store startLibraryTask:imageTask account:@"account" error:&error];
        CHECK(imageRun && !error);
        NSDictionary *beforeReopen = [store libraryTask:imageTask account:@"account" error:NULL];
        store = nil;
        store = [[SRStore alloc] initWithPath:path error:&error]; CHECK(store && !error);
        NSDictionary *afterReopen = [store libraryTask:imageTask account:@"account" error:&error];
        CHECK(afterReopen && !error);
        CHECK([afterReopen[@"frozenSha256"] isEqual:beforeReopen[@"frozenSha256"]]);
        CHECK([afterReopen[@"versionID"] isEqual:imageVersion]);
        CHECK([afterReopen[@"runID"] isEqual:imageRun]);
        CHECK([afterReopen[@"targets"] count] == 3);
        CHECK([afterReopen[@"payload"][@"sha256"] isEqual:asset[@"sha256"]]);
        NSString *scope = [SRImageAssetStore libraryScopeForAccount:@"account"];
        CHECK([[store.imageAssets dataForPayload:asset scopeSHA256:scope error:NULL] isEqual:imageBytes]);
        CHECK([[store summaryForRun:imageRun error:NULL][@"state"] isEqual:@"awaiting_resume"]);

        // 10. Re-send freezes the original bytes as a new identity.
        CHECK([store cancelOperationsRun:imageRun account:@"account" error:NULL]);
        NSString *resent = [store resendLibraryTask:first account:@"account" confirmationID:@"confirm-resent"
            error:&error];
        CHECK(resent && ![resent isEqual:first] && !error);
        NSDictionary *resentCard = [store libraryTask:resent account:@"account" error:NULL];
        CHECK([resentCard[@"originTaskID"] isEqual:first]);
        CHECK([resentCard[@"payload"][@"text"] isEqual:@"first body"]);
        CHECK([resentCard[@"frozenSha256"] isEqual:firstCard[@"frozenSha256"]]);
        CHECK([[store resendLibraryTask:first account:@"account" confirmationID:@"confirm-resent" error:NULL]
            isEqual:resent]);
        // A key belongs to one operation and one origin task. A create key can
        // never resolve through the re-send entry...
        CHECK(![store resendLibraryTask:first account:@"account" confirmationID:@"confirm-2" error:NULL]);
        // ...another task cannot borrow this re-send key...
        CHECK(![store resendLibraryTask:second account:@"account" confirmationID:@"confirm-resent" error:NULL]);
        // ...and a re-send key cannot be reused by a create.
        CHECK(![store createLibraryTaskForAccount:@"account" item:text version:frozenVersion
            confirmationID:@"confirm-resent" targets:targets() minimum:5 maximum:10 error:NULL]);
        CHECK([[store libraryTask:resent account:@"account" error:NULL][@"originTaskID"] isEqual:first]);
        CHECK(taskCount(store, @"account") == plans + 5);
        // A re-send still needs a confirmable request and an owned task.
        CHECK(![store resendLibraryTask:first account:@"account" confirmationID:@"" error:NULL]);
        CHECK(![store resendLibraryTask:first account:@"other" confirmationID:@"confirm-other" error:NULL]);
        NSString *resentRun = [store startLibraryTask:resent account:@"account" error:&error];
        CHECK(resentRun && !error);
        // Re-sending and starting never created or removed a source claim.
        CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
        sqlite3_stmt *statement = NULL;
        CHECK(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM source_claims", -1, &statement, NULL) == SQLITE_OK);
        CHECK(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 0);
        sqlite3_finalize(statement);
        CHECK(sqlite3_close(db) == SQLITE_OK);

        // 11. A run reference must come from the token the payload froze. The
        // trigger refuses a rewritten column; the read-back also refuses a task
        // whose media record no longer exists for this account, so starting it
        // can never register a reference for an unrelated file.
        NSDictionary *imageCard = [store libraryTask:imageTask account:@"account" error:NULL];
        CHECK([imageCard[@"mediaToken"] isKindOfClass:NSString.class]);
        CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
        sqlite3_stmt *dropAsset = NULL;
        CHECK(sqlite3_prepare_v2(db, "DELETE FROM media_assets WHERE token=(SELECT media_token FROM library_tasks WHERE id=?)",
            -1, &dropAsset, NULL) == SQLITE_OK);
        CHECK(sqlite3_bind_text(dropAsset, 1, imageTask.UTF8String, -1, SQLITE_TRANSIENT) == SQLITE_OK);
        CHECK(sqlite3_step(dropAsset) == SQLITE_DONE);
        sqlite3_finalize(dropAsset);
        CHECK(sqlite3_close(db) == SQLITE_OK);
        CHECK(![store libraryTask:imageTask account:@"account" error:NULL]);
        CHECK(![store startLibraryTask:imageTask account:@"account" error:NULL]);

        store = nil;
        CHECK([NSFileManager.defaultManager removeItemAtPath:root error:NULL]);
        puts("PASS: library task freeze, confirmation idempotency, immutable scope, mutual exclusion, account isolation, restart recovery and legacy-callback rejection");
    }
    return 0;
}
