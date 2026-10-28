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
        NSDictionary *changed = [SRGroupPlanner configurationBySettingSourceGroup:candidate[@"rules"][0][@"targets"][0]
            inDraft:candidate error:NULL];
        CHECK(changed && targetIDs(changed).count == 2999 && [changed[@"senders"] count] == 0);
        CHECK([changed[@"rules"] count] == 20 && [candidate[@"senders"] count] == 2);
        CHECK(![targetIDs(changed) containsObject:changed[@"sourceGroup"][@"id"]]);
        NSDictionary *same = [SRGroupPlanner configurationBySettingSourceGroup:candidate[@"sourceGroup"] inDraft:candidate error:NULL];
        CHECK([same isEqual:candidate]);
        NSMutableDictionary *oneTarget = draft();
        oneTarget[@"rules"] = @[@{@"id": @"single", @"name": @"Single", @"targets": @[group(0)]}];
        NSDictionary *emptied = [SRGroupPlanner configurationBySettingSourceGroup:group(0) inDraft:oneTarget error:NULL];
        CHECK(emptied && [emptied[@"rules"] count] == 0 && [emptied[@"senders"] count] == 0);
        CHECK(![SRGroupPlanner configurationBySettingSourceGroup:@{@"id": @"wxid_not_group", @"name": @"Invalid"} inDraft:candidate error:NULL]);
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
        NSDictionary *existing = @{@"id": @"existing", @"name": @"Rule 2", @"targets": @[group(0), group(1)],
            @"origin": @"custom"};
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
        // Under the top-up algorithm the first released group fills the single
        // existing deficit first; only the remaining pool builds the new rule.
        CHECK([released[@"topUpRuleCount"] isEqual:@1] && [released[@"topUpCount"] isEqual:@1]);
        CHECK([released[@"topUpRules"][0][@"added"] isEqual:@1]);
        NSDictionary *topped = nil;
        for (NSDictionary *rule in released[@"configuration"][@"rules"])
            if ([rule[@"id"] isEqual:released[@"topUpRules"][0][@"ruleID"]]) topped = rule;
        CHECK(topped && [[topped[@"targets"] valueForKey:@"id"] containsObject:group(0)[@"id"]]);
        NSDictionary *recreated = [released[@"configuration"][@"rules"] lastObject];
        CHECK([recreated[@"targets"] count] == 100);
        CHECK(![[recreated[@"targets"] valueForKey:@"id"] containsObject:group(0)[@"id"]]);
        CHECK([released[@"assignedCount"] isEqual:@100]);
        // Every released group is allocated exactly once across all rules:
        // targetIDs also fails on a duplicate ID.
        CHECK(targetIDs(released[@"configuration"]).count == 3100);

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

        // --- Automatic rules top up; custom rules never do. ---
        NSMutableDictionary *topping = draft();
        NSDictionary *autoRule = @{@"id": @"auto-1", @"name": @"Auto", @"targets": @[group(10), group(11), group(12)],
            @"origin": @"auto", @"capacity": @100};
        NSDictionary *customRule = @{@"id": @"custom-1", @"name": @"Mine", @"targets": @[group(20), group(21)],
            @"origin": @"custom"};
        topping[@"rules"] = @[autoRule, customRule];
        NSDictionary *toppingBefore = [SRSourceMessage frozenJSON:topping];
        // 30 groups minus the 5 already allocated = 25 eligible.
        NSDictionary *topUp = [SRGroupPlanner previewWithRows:groups(30) draft:topping
            recipe:@[@{@"size": @100, @"count": @1}] executionLimit:20 error:NULL];
        CHECK(topUp && [topping isEqual:toppingBefore]);
        // The automatic rule is filled to the caller's limit (20), not to 100 and
        // not by a number baked into the planner.
        CHECK([topUp[@"topUpCount"] isEqual:@17] && [topUp[@"topUpRuleCount"] isEqual:@1]);
        CHECK([topUp[@"topUpRules"][0][@"added"] isEqual:@17]);
        CHECK([topUp[@"topUpRules"][0][@"before"] isEqual:@3] && [topUp[@"topUpRules"][0][@"after"] isEqual:@20]);
        CHECK([topUp[@"topUpRules"][0][@"target"] isEqual:@20] && [topUp[@"topUpRules"][0][@"capacity"] isEqual:@100]);
        CHECK([topUp[@"configuration"][@"rules"][0][@"targets"] count] == 20);
        CHECK([topUp[@"configuration"][@"rules"][0][@"origin"] isEqual:@"auto"]);
        // The custom rule is byte-for-byte untouched.
        CHECK([topUp[@"configuration"][@"rules"][1] isEqual:customRule]);
        // Top-up consumes the pool first: 25 - 17 = 8 left for the request.
        CHECK([topUp[@"assignedCount"] isEqual:@8] && [topUp[@"generatedRuleCount"] isEqual:@1]);
        CHECK([topUp[@"remainingCount"] isEqual:@0]);
        // With no clamp the same rule fills to its own spec.
        NSDictionary *unclamped = [SRGroupPlanner previewWithRows:groups(300) draft:topping
            recipe:@[@{@"size": @100, @"count": @1}] executionLimit:0 error:NULL];
        CHECK([unclamped[@"topUpRules"][0][@"target"] isEqual:@100]);
        CHECK([unclamped[@"topUpRules"][0][@"added"] isEqual:@97]);
        CHECK([unclamped[@"configuration"][@"rules"][0][@"targets"] count] == 100);
        // A rule already at the clamp is left alone and generation still runs.
        NSMutableDictionary *atLimit = draft();
        atLimit[@"rules"] = @[@{@"id": @"l", @"name": @"L", @"targets": groups(20),
            @"origin": @"auto", @"capacity": @100}];
        NSDictionary *capped = [SRGroupPlanner previewWithRows:groups(25) draft:atLimit
            recipe:@[@{@"size": @100, @"count": @1}] executionLimit:20 error:NULL];
        CHECK([capped[@"topUpCount"] isEqual:@0]);
        CHECK([capped[@"configuration"][@"rules"][0][@"targets"] count] == 20);
        CHECK([capped[@"generatedRuleCount"] isEqual:@1]);

        // A zero-count recipe is a pure top-up: nothing is created, and any
        // leftover stays unassigned instead of becoming a fragment rule.
        NSDictionary *pureTopUp = [SRGroupPlanner previewWithRows:groups(30) draft:topping
            recipe:@[@{@"size": @100, @"count": @0}] executionLimit:20 error:NULL];
        CHECK(pureTopUp && [pureTopUp[@"generatedRuleCount"] isEqual:@0]);
        CHECK([pureTopUp[@"topUpCount"] isEqual:@17] && [pureTopUp[@"topUpRuleCount"] isEqual:@1]);
        CHECK([pureTopUp[@"assignedCount"] isEqual:@0] && [pureTopUp[@"remainingCount"] isEqual:@8]);
        // Nothing to do at all is still refused: no rule created, no room to fill.
        CHECK(![SRGroupPlanner previewWithRows:groups(30) draft:atLimit
            recipe:@[@{@"size": @100, @"count": @0}] executionLimit:20 error:NULL]);

        // Grouping spec: stored capacity wins; a legacy rule is inferred from its
        // size, and an unreadable capacity falls back to the inference.
        CHECK([SRGroupPlanner capacityForRule:autoRule] == 100);
        CHECK([SRGroupPlanner capacityForRule:@{@"targets": @[], @"capacity": @200}] == 200);
        CHECK([SRGroupPlanner capacityForRule:@{@"targets": @[group(0)], @"capacity": @20}] == 100);
        CHECK([SRGroupPlanner capacityForRule:@{@"targets": @[group(0)]}] == 100);
        CHECK([SRGroupPlanner capacityForRule:@{@"targets": groups(150)}] == 200);
        CHECK([SRGroupPlanner capacityForRule:@{}] == 100);

        // The hand-picked entry produces custom rules with no capacity, and a
        // later automatic pass leaves them alone.
        NSDictionary *manual = [SRGroupPlanner previewWithRows:groups(40) draft:draft()
            recipe:@[@{@"size": @100, @"count": @1}] intent:SRGroupingIntentCustom
            executionLimit:20 error:NULL];
        CHECK([manual[@"configuration"][@"rules"][0][@"origin"] isEqual:@"custom"]);
        CHECK(manual[@"configuration"][@"rules"][0][@"capacity"] == nil);
        CHECK([manual[@"topUpCount"] isEqual:@0]);
        NSDictionary *manualAgain = [SRGroupPlanner previewWithRows:groups(45) draft:manual[@"configuration"]
            recipe:@[@{@"size": @100, @"count": @1}] executionLimit:20 error:NULL];
        CHECK([manualAgain[@"topUpCount"] isEqual:@0]);
        CHECK([manualAgain[@"configuration"][@"rules"][0][@"targets"] count] == 40);
        CHECK([manualAgain[@"generatedRuleCount"] isEqual:@1]);

        // --- The two intents are kept apart in Core. ---
        // An existing automatic rule with a deficit must not swallow the rows a
        // hand-picked request reserved for itself.
        NSMutableDictionary *picking = draft();
        NSDictionary *autoDeficit = @{@"id": @"auto17", @"name": @"Auto17", @"targets": groups(17),
            @"origin": @"auto", @"capacity": @100};
        picking[@"rules"] = @[autoDeficit];
        NSDictionary *pickingBefore = [SRSourceMessage frozenJSON:picking];
        NSArray *pickedTwo = @[group(200), group(201)];
        NSDictionary *picked = [SRGroupPlanner previewWithRows:pickedTwo draft:picking
            recipe:@[@{@"size": @100, @"count": @1}] intent:SRGroupingIntentCustom
            executionLimit:20 error:NULL];
        CHECK(picked && [picking isEqual:pickingBefore]);
        // The old automatic rule is byte-for-byte unchanged and nothing was topped up.
        CHECK([picked[@"configuration"][@"rules"][0] isEqual:autoDeficit]);
        CHECK([picked[@"topUpCount"] isEqual:@0] && [picked[@"topUpRuleCount"] isEqual:@0]);
        CHECK([picked[@"topUpRules"] count] == 0);
        // The new custom rule holds exactly the two picked groups, in order.
        CHECK([picked[@"configuration"][@"rules"] count] == 2);
        NSDictionary *pickedRule = picked[@"configuration"][@"rules"][1];
        CHECK([pickedRule[@"origin"] isEqual:@"custom"] && pickedRule[@"capacity"] == nil);
        CHECK([[pickedRule[@"targets"] valueForKey:@"id"]
            isEqual:(@[group(200)[@"id"], group(201)[@"id"]])]);
        // Picking more than the old deficit still keeps every picked group.
        NSArray *pickedFive = @[group(300), group(301), group(302), group(303), group(304)];
        NSDictionary *pickedMore = [SRGroupPlanner previewWithRows:pickedFive draft:picking
            recipe:@[@{@"size": @100, @"count": @1}] intent:SRGroupingIntentCustom
            executionLimit:20 error:NULL];
        CHECK(pickedMore && [pickedMore[@"topUpCount"] isEqual:@0]);
        CHECK([pickedMore[@"configuration"][@"rules"][0] isEqual:autoDeficit]);
        CHECK([pickedMore[@"configuration"][@"rules"][1][@"targets"] count] == 5);
        CHECK([[pickedMore[@"configuration"][@"rules"][1][@"targets"] valueForKey:@"id"]
            isEqual:[pickedFive valueForKey:@"id"]]);
        // The same draft under the automatic intent does top the rule up, so the
        // difference above comes from the intent, not from the data.
        NSDictionary *automaticSame = [SRGroupPlanner previewWithRows:pickedFive draft:picking
            recipe:@[@{@"size": @100, @"count": @0}] intent:SRGroupingIntentAutomatic
            executionLimit:20 error:NULL];
        CHECK([automaticSame[@"topUpCount"] isEqual:@3]);
        CHECK([automaticSame[@"generatedRuleCount"] isEqual:@0]);
        CHECK([automaticSame[@"configuration"][@"rules"][0][@"targets"] count] == 20);

        // Provenance is validated: unknown origin, non-spec capacity and a
        // custom rule that claims a capacity are all refused.
        NSMutableDictionary *bad = draft();
        bad[@"rules"] = @[@{@"id": @"r", @"name": @"R", @"targets": @[group(0)], @"origin": @"mystery"}];
        CHECK(![SRConfiguration validateDraft:bad error:NULL]);
        bad[@"rules"] = @[@{@"id": @"r", @"name": @"R", @"targets": @[group(0)], @"capacity": @50}];
        CHECK(![SRConfiguration validateDraft:bad error:NULL]);
        bad[@"rules"] = @[@{@"id": @"r", @"name": @"R", @"targets": @[group(0)], @"capacity": @YES}];
        CHECK(![SRConfiguration validateDraft:bad error:NULL]);
        bad[@"rules"] = @[@{@"id": @"r", @"name": @"R", @"targets": @[group(0)], @"origin": @"custom", @"capacity": @100}];
        CHECK(![SRConfiguration validateDraft:bad error:NULL]);
        bad[@"rules"] = @[@{@"id": @"r", @"name": @"R", @"targets": @[group(0)], @"origin": @"custom"}];
        CHECK([SRConfiguration validateDraft:bad error:NULL]);
        bad[@"rules"] = @[@{@"id": @"r", @"name": @"R", @"targets": @[group(0)], @"origin": @"auto", @"capacity": @200}];
        CHECK([SRConfiguration validateDraft:bad error:NULL]);
        before = [SRSourceMessage frozenJSON:original];
        // A hand-picked request that creates no rule has nothing to do: it is
        // refused instead of silently turning into a top-up.
        CHECK(![SRGroupPlanner previewWithRows:groups(5) draft:original
            recipe:@[@{@"size": @100, @"count": @0}] intent:SRGroupingIntentCustom
            executionLimit:20 error:NULL]);
        CHECK([original isEqual:before]);

        // An explicit request against an empty pool is a valid zero result, not
        // an error: the caller shows "no change" and keeps the draft. Only a
        // pure top-up with nothing to fill is refused.
        NSDictionary *emptyPool = [SRGroupPlanner previewWithRows:@[] draft:original
            recipe:@[@{@"size": @100, @"count": @1}] intent:SRGroupingIntentAutomatic
            executionLimit:20 error:NULL];
        CHECK(emptyPool && [emptyPool[@"generatedRuleCount"] isEqual:@0]);
        CHECK([emptyPool[@"assignedCount"] isEqual:@0] && [emptyPool[@"remainingCount"] isEqual:@0]);
        CHECK([emptyPool[@"topUpCount"] isEqual:@0]);
        NSDictionary *motherOnly = [SRGroupPlanner previewWithRows:@[original[@"sourceGroup"]]
            draft:original recipe:@[@{@"size": @100, @"count": @1}] intent:SRGroupingIntentAutomatic
            executionLimit:20 error:NULL];
        CHECK(motherOnly && [motherOnly[@"assignedCount"] isEqual:@0]);
        CHECK([motherOnly[@"generatedRuleCount"] isEqual:@0]);
        CHECK(![SRGroupPlanner previewWithRows:@[] draft:original
            recipe:@[@{@"size": @100, @"count": @0}] intent:SRGroupingIntentAutomatic
            executionLimit:20 error:NULL]);
        CHECK([original isEqual:before]);

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
        puts("PASS: automatic 100/200 grouping with automatic-only top-up, custom rules left untouched, "
             "partial shortages, shared conditions, ID exclusions, 12345-row pool and no automatic starts");
    }
    return 0;
}
