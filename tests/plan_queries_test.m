#import <Foundation/Foundation.h>
#import "Core/SRConfiguration.h"
#import "Core/SRStore.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

static NSDictionary *configuration(void) {
    NSMutableDictionary *draft = [SRConfiguration emptyDraft];
    draft[@"sourceGroup"] = @{@"id": @"mother@chatroom", @"name": @"Mother"};
    draft[@"senders"] = @[@{@"id": @"wxid_sender", @"name": @"Sender"}];
    NSMutableArray *rules = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        NSMutableArray *targets = [NSMutableArray array];
        for (int j = 0; j < (i < 2 ? 2 : 1); j++) [targets addObject:@{
            @"id": [NSString stringWithFormat:@"group-%d-%d@chatroom", i, j], @"name": @"Group"}];
        [rules addObject:@{@"id": [NSString stringWithFormat:@"draft-%d", i], @"name": @"Rule", @"targets": targets}];
    }
    draft[@"rules"] = rules; return draft;
}
static NSDictionary *envelope(NSString *account, NSString *identifier) {
    return @{@"account": account, @"group": @"mother@chatroom", @"sender": @"wxid_sender", @"messageID": identifier,
        @"type": @"text", @"generatedByRelay": @NO, @"payload": @{@"text": @"secret message body"}};
}
static BOOL result(SRStore *store, NSDictionary *delivery, NSString *state) {
    return [store recordResultForDelivery:delivery[@"id"] attempt:delivery[@"attempt_id"] state:state
        messageID:[state isEqual:@"confirmed"] ? @"server" : nil reason:[state isEqual:@"failed"] ? @"Network failure" : nil error:NULL];
}
int main(void) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *path = [directory stringByAppendingPathComponent:@"queries.sqlite3"];
        SRStore *store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        NSString *plan = [store createPlanFromConfiguration:configuration() envelope:envelope(@"account", @"first") account:@"account" error:NULL]; CHECK(plan);
        NSString *newer = [store createPlanFromConfiguration:configuration() envelope:envelope(@"account", @"second") account:@"account" error:NULL]; CHECK(newer);
        CHECK([store createPlanFromConfiguration:configuration() envelope:envelope(@"other", @"first") account:@"other" error:NULL]);
        NSArray *plans = [store plansForAccount:@"account" limit:1 offset:0 error:NULL];
        CHECK(plans.count == 1 && [plans[0][@"id"] isEqual:newer] && [plans[0][@"targetCount"] isEqual:@5]);
        CHECK([[store plansForAccount:@"account" limit:1 offset:1 error:NULL][0][@"id"] isEqual:plan]);
        CHECK([store plansForAccount:@"account" limit:1 offset:2 error:NULL].count == 0);
        CHECK([store plansForAccount:@"absent" limit:50 offset:0 error:NULL].count == 0);
        CHECK(![store plansForAccount:@"account" limit:0 offset:0 error:NULL]);
        CHECK(![store plansForAccount:@"account" limit:101 offset:0 error:NULL]);
        CHECK(![store plansForAccount:@"account" limit:1 offset:NSUIntegerMax error:NULL]);
        CHECK(![store plan:plan account:@"other" error:NULL]);
        CHECK(![store ruleCardsForPlan:plan account:@"other" error:NULL]);
        CHECK([[store plan:plan account:@"account" error:NULL][@"snapshot"][@"payload"][@"text"] isEqual:@"secret message body"]);
        NSArray *cards = [store ruleCardsForPlan:plan account:@"account" error:NULL]; CHECK(cards.count == 3);
        // Frozen target identifiers are returned per rule, in position order.
        CHECK([cards[0][@"targetIdentifiers"] isEqual:(@[@"group-0-0@chatroom", @"group-0-1@chatroom"])]);
        CHECK([cards[1][@"targetIdentifiers"] isEqual:(@[@"group-1-0@chatroom", @"group-1-1@chatroom"])]);
        CHECK([cards[2][@"targetIdentifiers"] isEqual:@[@"group-2-0@chatroom"]]);
        CHECK([cards[0][@"targetIdentifiers"] count] == [cards[0][@"targetCount"] unsignedIntegerValue]);
        CHECK([cards[0][@"initialUnlocked"] boolValue] && ![cards[1][@"initialUnlocked"] boolValue]);
        CHECK([cards[0][@"latestRun"] isEqual:NSNull.null] && ![cards[0][@"accountOccupied"] boolValue]);
        NSString *first = cards[0][@"id"], *second = cards[1][@"id"], *third = cards[2][@"id"];
        CHECK(![store historyForRule:first account:@"other" limit:50 offset:0 error:NULL]);
        CHECK(![store historyForRule:first account:@"account" limit:101 offset:0 error:NULL]);
        CHECK([store historyForRule:first account:@"account" limit:50 offset:0 error:NULL].count == 0);
        NSString *run = [store startRule:first replay:NO error:NULL]; CHECK(run);
        cards = [store ruleCardsForPlan:plan account:@"account" error:NULL];
        CHECK([cards[0][@"accountOccupied"] boolValue] && [cards[0][@"latestRun"][@"counts"][@"pending"] isEqual:@2]);
        CHECK(![cards[0][@"initialUnlocked"] boolValue] && ![cards[1][@"initialUnlocked"] boolValue]);
        for (int i = 0; i < 2; i++) CHECK(result(store, [store claimNextForRun:run error:NULL], @"confirmed"));
        NSDictionary *completed = [store historyForRule:first account:@"account" limit:1 offset:0 error:NULL][0];
        CHECK([completed[@"state"] isEqual:@"completed"] && [completed[@"ended_at"] doubleValue] > 0);
        NSNumber *endedAt = completed[@"ended_at"];
        CHECK(!completed[@"snapshot"] && ![completed.description containsString:@"secret message body"]);
        CHECK([store exceptionsForRun:run account:@"account" limit:50 offset:0 error:NULL].count == 0);
        CHECK(![store exceptionsForRun:run account:@"other" limit:50 offset:0 error:NULL]);
        CHECK(![store exceptionsForRun:run account:@"account" limit:0 offset:0 error:NULL]);
        cards = [store ruleCardsForPlan:plan account:@"account" error:NULL];
        CHECK([cards[1][@"initialUnlocked"] boolValue] && ![cards[2][@"initialUnlocked"] boolValue]);
        CHECK(![cards.description containsString:@"secret message body"]);
        NSString *secondRun = [store startRule:second replay:NO error:NULL]; CHECK(secondRun);
        CHECK(result(store, [store claimNextForRun:secondRun error:NULL], @"failed"));
        CHECK(result(store, [store claimNextForRun:secondRun error:NULL], @"uncertain"));
        NSArray *exceptions = [store exceptionsForRun:secondRun account:@"account" limit:1 offset:0 error:NULL];
        CHECK(exceptions.count == 1 && [exceptions[0][@"state"] isEqual:@"failed"] && [exceptions[0][@"reason"] isEqual:@"Network failure"]);
        CHECK([[store exceptionsForRun:secondRun account:@"account" limit:1 offset:1 error:NULL][0][@"state"] isEqual:@"uncertain"]);
        CHECK([store exceptionsForRun:secondRun account:@"account" limit:1 offset:2 error:NULL].count == 0);
        CHECK([[store summaryForRun:secondRun error:NULL][@"state"] isEqual:@"completed"]);
        CHECK([[store ruleCardsForPlan:plan account:@"account" error:NULL][2][@"initialUnlocked"] boolValue]);
        NSString *thirdRun = [store startRule:third replay:NO error:NULL]; CHECK(thirdRun); CHECK([store endRun:thirdRun error:NULL]);
        CHECK([[store exceptionsForRun:thirdRun account:@"account" limit:50 offset:0 error:NULL][0][@"state"] isEqual:@"cancelled"]);
        NSString *replay = [store startRule:first replay:YES error:NULL]; CHECK(replay);
        NSArray *history = [store historyForRule:first account:@"account" limit:1 offset:0 error:NULL];
        CHECK(history.count == 1 && [history[0][@"id"] isEqual:replay]);
        CHECK([[store historyForRule:first account:@"account" limit:1 offset:1 error:NULL][0][@"ended_at"] isEqual:endedAt]);
        CHECK([store historyForRule:first account:@"account" limit:1 offset:2 error:NULL].count == 0);
        CHECK(![history.description containsString:@"secret message body"] && ![plans.description containsString:@"secret message body"]);
        store = nil; store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store && [store recoverInterruptedRuns:NULL]);
        history = [store historyForRule:first account:@"account" limit:50 offset:0 error:NULL];
        CHECK(history.count == 2 && [history[0][@"state"] isEqual:@"awaiting_resume"]);
        CHECK([history[1][@"ended_at"] isEqual:endedAt]);
        for (int i = 0; i < 3; i++) {
            (void)[store plansForAccount:@"account" limit:50 offset:0 error:NULL];
            (void)[store ruleCardsForPlan:plan account:@"account" error:NULL];
        }
        CHECK([store historyForRule:first account:@"account" limit:50 offset:0 error:NULL].count == 2);
        store = nil; CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: account-scoped paged plan/rule/history/exception queries, frozen target identifiers in "
             "position order, real completion timestamps, replay isolation and read-only recovery views");
    }
    return 0;
}
