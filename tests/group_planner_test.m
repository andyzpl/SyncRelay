#import <Foundation/Foundation.h>
#import "Core/SRConfiguration.h"
#import "Core/SRGroupPlanner.h"
#import "Core/SRSelection.h"
#import "Core/SRSourceMessage.h"
#import "Core/SRStore.h"
#import <sqlite3.h>
#include <assert.h>
#include <limits.h>
#define CHECK(...) assert((__VA_ARGS__))

static NSDictionary *group(NSUInteger number) {
    return @{@"id": [NSString stringWithFormat:@"group-%05lu@chatroom", (unsigned long)number], @"name": @"Same name"};
}
static NSArray *groups(NSUInteger count) {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) [rows addObject:group(i)];
    return rows;
}
static NSMutableDictionary *draft(void) {
    NSMutableDictionary *value = [SRConfiguration emptyDraft];
    value[@"sourceGroup"] = @{@"id": @"mother@chatroom", @"name": @"Mother"};
    value[@"senders"] = @[@{@"id": @"wxid_a", @"name": @"Same name"}, @{@"id": @"wxid_b", @"name": @"Same name"}];
    value[@"types"] = @[@"text"]; value[@"minimum"] = @12; value[@"maximum"] = @18;
    return value;
}
static NSSet *targetIDs(NSDictionary *configuration) {
    NSMutableSet *identifiers = [NSMutableSet set];
    NSMutableSet *ruleIDs = [NSMutableSet set], *ruleNames = [NSMutableSet set];
    for (NSDictionary *rule in configuration[@"rules"]) {
        CHECK([rule[@"targets"] count] > 0 && [rule[@"targets"] count] <= 200);
        CHECK(![ruleIDs containsObject:rule[@"id"]] && ![ruleNames containsObject:rule[@"name"]]);
        [ruleIDs addObject:rule[@"id"]]; [ruleNames addObject:rule[@"name"]];
        for (NSDictionary *target in rule[@"targets"]) {
            CHECK(![identifiers containsObject:target[@"id"]]); [identifiers addObject:target[@"id"]];
        }
    }
    return identifiers;
}
static NSUInteger scalar(sqlite3 *database, const char *sql) {
    sqlite3_stmt *statement = NULL; CHECK(sqlite3_prepare_v2(database, sql, -1, &statement, NULL) == SQLITE_OK);
    CHECK(sqlite3_step(statement) == SQLITE_ROW); NSUInteger value = (NSUInteger)sqlite3_column_int64(statement, 0);
    CHECK(sqlite3_finalize(statement) == SQLITE_OK); return value;
}

int main(void) {
    @autoreleasepool {
        NSArray *recipe = @[@{@"size": @100, @"count": @10}, @{@"size": @200, @"count": @10}];
        NSMutableDictionary *original = draft(); NSDictionary *before = [SRSourceMessage frozenJSON:original];
        NSDictionary *preview = [SRGroupPlanner previewWithRows:groups(3000) draft:original recipe:recipe error:NULL];
        CHECK(preview && [original isEqual:before]);
        CHECK([preview[@"generatedRuleCount"] isEqual:@20] && [preview[@"assignedCount"] isEqual:@3000]);
        CHECK([preview[@"shortfallCount"] isEqual:@0] && [preview[@"remainingCount"] isEqual:@0]);
        NSDictionary *candidate = preview[@"configuration"];
        CHECK(targetIDs(candidate).count == 3000);
        // Automatic source exclusion does not depend on the manual exclusion list.
        NSDictionary *sourceOnly = [SRGroupPlanner previewWithRows:@[original[@"sourceGroup"]]
            draft:original recipe:recipe error:NULL];
        CHECK(sourceOnly && [sourceOnly[@"assignedCount"] isEqual:@0]);
        NSMutableDictionary *conflicting = [candidate mutableCopy];
        conflicting[@"sourceGroup"] = candidate[@"rules"][0][@"targets"][0];
        CHECK(![SRConfiguration validateDraft:conflicting error:NULL]);
        for (NSUInteger i = 0; i < 20; i++) CHECK([candidate[@"rules"][i][@"targets"] count] == (i < 10 ? 100 : 200));
        for (NSString *key in @[@"sourceGroup", @"senders", @"types", @"minimum", @"maximum"])
            CHECK([candidate[key] isEqual:original[key]]);
        CHECK([SRSourceMessage matchesEnvelope:@{@"account": @"account", @"group": @"mother@chatroom", @"sender": @"wxid_b",
            @"messageID": @"test", @"type": @"text", @"generatedByRelay": @NO, @"payload": @{@"text": @"One message"}}
            configuration:candidate account:@"account"]);
        NSDictionary *fifteen = [SRGroupPlanner previewWithRows:groups(3000) draft:original
            recipe:@[@{@"size": @200, @"count": @15}] error:NULL];
        CHECK([fifteen[@"generatedRuleCount"] isEqual:@15] && targetIDs(fifteen[@"configuration"]).count == 3000);
        NSMutableDictionary *mutableGroup = [group(0) mutableCopy], *mutableDraft = draft();
        NSDictionary *frozen = [SRGroupPlanner previewWithRows:@[mutableGroup] draft:mutableDraft recipe:recipe error:NULL];
        mutableGroup[@"id"] = @"changed@chatroom"; mutableDraft[@"types"] = @[@"image"];
        CHECK([frozen[@"configuration"][@"rules"][0][@"targets"][0][@"id"] isEqual:group(0)[@"id"]]);
        CHECK([frozen[@"configuration"][@"types"] isEqual:@[@"text"]]);

        // A shortage is a valid preview: one partial final rule, never empty padding rules.
        NSDictionary *shortage = [SRGroupPlanner previewWithRows:groups(2450) draft:original recipe:recipe error:NULL];
        CHECK([shortage[@"generatedRuleCount"] isEqual:@18] && [shortage[@"partialRuleCount"] isEqual:@1]);
        CHECK([shortage[@"assignedCount"] isEqual:@2450] && [shortage[@"shortfallCount"] isEqual:@550]);
        CHECK([shortage[@"configuration"][@"rules"] lastObject][@"targets"] != nil);
        CHECK([[shortage[@"configuration"][@"rules"] lastObject][@"targets"] count] == 50);
        CHECK(targetIDs(shortage[@"configuration"]).count == 2450);
        NSDictionary *tiny = [SRGroupPlanner previewWithRows:groups(35) draft:original recipe:recipe error:NULL];
        CHECK([tiny[@"generatedRuleCount"] isEqual:@1] && [tiny[@"partialRuleCount"] isEqual:@1]);
        CHECK([tiny[@"assignedCount"] isEqual:@35] && [tiny[@"shortfallCount"] isEqual:@2965]);
        NSDictionary *empty = [SRGroupPlanner previewWithRows:@[] draft:original recipe:recipe error:NULL];
        CHECK(empty && [empty[@"generatedRuleCount"] isEqual:@0] && ![empty[@"configuration"][@"rules"] count]);

        // Exclusion and allocation use stable IDs even when every nickname is identical.
        NSMutableArray *pool = [groups(3100) mutableCopy];
        [pool addObject:original[@"sourceGroup"]]; [pool addObject:group(0)];
        NSDictionary *existing = @{@"id": @"existing", @"name": @"Rule 2", @"targets": @[group(0), group(1)]};
        original[@"rules"] = @[existing]; original[@"excludedGroups"] = @[group(2), group(3)];
        NSDictionary *filtered = [SRGroupPlanner previewWithRows:pool draft:original recipe:recipe error:NULL];
        CHECK([filtered[@"availableCount"] isEqual:@3096] && [filtered[@"remainingCount"] isEqual:@96]);
        CHECK(targetIDs(filtered[@"configuration"]).count == 3002);
        CHECK([filtered[@"configuration"][@"rules"][0] isEqual:existing]);
        CHECK([filtered[@"configuration"][@"rules"][1][@"targets"][0][@"id"] isEqual:group(4)[@"id"]]);
        CHECK(![targetIDs(filtered[@"configuration"]) containsObject:group(2)[@"id"]]);
        CHECK(![targetIDs(filtered[@"configuration"]) containsObject:@"mother@chatroom"]);
        NSDictionary *second = [SRGroupPlanner previewWithRows:pool draft:filtered[@"configuration"] recipe:recipe error:NULL];
        CHECK([second[@"assignedCount"] isEqual:@96] && [second[@"generatedRuleCount"] isEqual:@1]);
        CHECK(targetIDs(second[@"configuration"]).count == 3098);

        SRSelection *selection = [[SRSelection alloc] initWithRows:pool excludedIDs:[NSSet setWithObject:@"mother@chatroom"]
            selectedIDs:[NSSet setWithObject:group(3)[@"id"]]];
        [selection setRowsMatching:@"group-00002" selected:YES]; CHECK(selection.selectedCount == 2);
        [selection setRowsMatching:@"group-00003" selected:NO]; CHECK(selection.selectedCount == 1);
        CHECK([selection.selectedRows[0][@"id"] isEqual:group(2)[@"id"]]);
        [selection setRowsMatching:@"not-present" selected:YES]; CHECK(selection.selectedCount == 1);
        [selection selectFirst:NSUIntegerMax]; CHECK(selection.selectedCount == 3100);
        [selection selectFirst:0]; CHECK(selection.selectedCount == 0);

        NSDictionary *pruned = [SRGroupPlanner configurationBySettingExcludedGroups:@[group(0), group(1), group(4)]
            inDraft:filtered[@"configuration"] error:NULL];
        CHECK(pruned && [pruned[@"rules"] count] == 20 && targetIDs(pruned).count == 2999);
        CHECK([filtered[@"configuration"][@"rules"] count] == 21);
        CHECK(![targetIDs(pruned) containsObject:group(4)[@"id"]]);
        NSDictionary *restored = [SRGroupPlanner configurationBySettingExcludedGroups:@[] inDraft:pruned error:NULL];
        CHECK(restored && ![restored[@"excludedGroups"] count] && targetIDs(restored).count == 2999);
        NSDictionary *released = [SRGroupPlanner previewWithRows:pool draft:restored
            recipe:@[@{@"size": @100, @"count": @1}] error:NULL];
        CHECK([released[@"assignedCount"] isEqual:@100]);
        CHECK([released[@"configuration"][@"rules"] lastObject][@"targets"][0] != nil);
        CHECK([[[released[@"configuration"][@"rules"] lastObject][@"targets"] firstObject][@"id"] isEqual:group(0)[@"id"]]);

        NSMutableDictionary *legacy = draft(); [legacy removeObjectForKey:@"excludedGroups"];
        CHECK([SRConfiguration validateDraft:legacy error:NULL]);
        CHECK([SRGroupPlanner previewWithRows:groups(100) draft:legacy recipe:recipe error:NULL]);
        NSMutableDictionary *invalid = [pruned mutableCopy]; invalid[@"excludedGroups"] = @[group(10), group(10)];
        CHECK(![SRConfiguration validateDraft:invalid error:NULL]);
        invalid[@"excludedGroups"] = @[group(10)]; CHECK(![SRConfiguration validateDraft:invalid error:NULL]);
        CHECK(![SRGroupPlanner configurationBySettingExcludedGroups:@[group(0), group(0)] inDraft:pruned error:NULL]);

        NSDictionary *large = [SRGroupPlanner previewWithRows:groups(12345) draft:draft()
            recipe:@[@{@"size": @100, @"count": @10}, @{@"size": @200, @"count": @45}] error:NULL];
        CHECK([large[@"assignedCount"] isEqual:@10000] && [large[@"remainingCount"] isEqual:@2345]);
        CHECK([large[@"generatedRuleCount"] isEqual:@55] && targetIDs(large[@"configuration"]).count == 10000);
        before = [SRSourceMessage frozenJSON:original];
        for (id invalidRecipe in @[@[], @[@{@"size": @100, @"count": @0}], @[@{@"size": @201, @"count": @1}],
            @[@{@"size": @100, @"count": @-1}], @[@{@"size": @100, @"count": @1.5}],
            @[@{@"size": @100, @"count": @YES}], @[@{@"size": @100, @"count": @"10"}],
            @[@{@"size": @200, @"count": @(ULLONG_MAX)}],
            @[@{@"size": @200, @"count": @(NSUIntegerMax / 200)}, @{@"size": @100, @"count": @1}]]) {
            NSError *error = nil;
            CHECK(![SRGroupPlanner previewWithRows:pool draft:original recipe:invalidRecipe error:&error] && error);
            CHECK([original isEqual:before]);
        }
        CHECK(![SRGroupPlanner previewWithRows:@[@{@"id": @"wxid_person", @"name": @"Not a group"}]
            draft:original recipe:recipe error:NULL]);
        CHECK(![SRGroupPlanner previewWithRows:pool draft:[SRConfiguration emptyDraft] recipe:recipe error:NULL]);
        NSDictionary *zeroFirst = [SRGroupPlanner previewWithRows:groups(250) draft:draft()
            recipe:@[@{@"size": @100, @"count": @0}, @{@"size": @200, @"count": @2}] error:NULL];
        CHECK([zeroFirst[@"generatedRuleCount"] isEqual:@2] && [zeroFirst[@"partialRuleCount"] isEqual:@1]);

        // Saving/generated rules alone must create no plan, run or delivery.
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *path = [directory stringByAppendingPathComponent:@"grouping.sqlite3"];
        SRStore *store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        CHECK([store saveConfiguration:filtered[@"configuration"] account:@"account" error:NULL]);
        store = nil; store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        CHECK([[store configurationForAccount:@"account" error:NULL] isEqual:filtered[@"configuration"]]);
        CHECK(![[store configurationForAccount:@"other-account" error:NULL][@"excludedGroups"] count]);
        sqlite3 *database = NULL; CHECK(sqlite3_open(path.fileSystemRepresentation, &database) == SQLITE_OK);
        CHECK(scalar(database, "SELECT COUNT(*) FROM plans") == 0);
        CHECK(scalar(database, "SELECT COUNT(*) FROM runs") == 0);
        CHECK(scalar(database, "SELECT COUNT(*) FROM deliveries") == 0);
        CHECK([store saveConfiguration:candidate account:@"account" error:NULL]);
        NSString *plan = [store createPlanFromConfiguration:candidate envelope:@{@"account": @"account", @"group": @"mother@chatroom",
            @"sender": @"wxid_a", @"messageID": @"one-message", @"type": @"text", @"generatedByRelay": @NO,
            @"payload": @{@"text": @"One message for every rule"}} account:@"account" error:NULL];
        CHECK(plan && [store allocatedTargetsForPlan:plan error:NULL].count == 3000);
        NSArray *rules = [store rulesForPlan:plan error:NULL]; CHECK(rules.count == 20);
        for (NSDictionary *rule in rules) CHECK([rule[@"minimum"] isEqual:@12] && [rule[@"maximum"] isEqual:@18]);
        CHECK(scalar(database, "SELECT COUNT(*) FROM runs") == 0);
        CHECK(scalar(database, "SELECT COUNT(*) FROM plans WHERE senders='[\"wxid_a\",\"wxid_b\"]' AND types='[\"text\"]'") == 1);
        NSString *run = [store startRule:rules[0][@"id"] replay:NO error:NULL]; CHECK(run);
        CHECK(![store startRule:rules[1][@"id"] replay:NO error:NULL]);
        CHECK([store endRun:run error:NULL]);
        CHECK(scalar(database, "SELECT COUNT(*) FROM runs") == 1);
        CHECK([store startRule:rules[1][@"id"] replay:NO error:NULL]);
        CHECK(scalar(database, "SELECT COUNT(*) FROM runs") == 2);
        CHECK(sqlite3_close(database) == SQLITE_OK); store = nil;
        CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: automatic 100/200 grouping, partial shortages, shared conditions, ID exclusions, 12345-row pool and no automatic starts");
    }
    return 0;
}
