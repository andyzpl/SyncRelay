#import <Foundation/Foundation.h>
#import "Core/SRRunProjection.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

/* Synthetic fixtures only: no device content, account, group or server ID is
 * used here. The projection is pure, so no store, session, database or host
 * object is constructed. */

static NSDictionary *counts(NSUInteger pending, NSUInteger submitting, NSUInteger submitted,
                            NSUInteger confirmed, NSUInteger failed, NSUInteger uncertain, NSUInteger cancelled) {
    return @{@"pending": @(pending), @"submitting": @(submitting), @"submitted": @(submitted),
        @"confirmed": @(confirmed), @"failed": @(failed), @"uncertain": @(uncertain), @"cancelled": @(cancelled)};
}

static NSDictionary *run(NSString *identifier, NSString *state, NSNumber *started, NSNumber *ended, NSDictionary *values) {
    NSMutableDictionary *dictionary = [@{@"id": identifier, @"state": state, @"counts": values} mutableCopy];
    if (started) dictionary[@"started_at"] = started;
    if (ended) dictionary[@"ended_at"] = ended;
    return dictionary;
}

static NSDictionary *card(NSString *identifier, NSString *name, NSUInteger targetCount,
                          BOOL unlocked, BOOL occupied, NSDictionary *latest) {
    return @{@"id": identifier, @"name": name, @"targetCount": @(targetCount),
        @"initialUnlocked": @(unlocked), @"accountOccupied": @(occupied),
        @"latestRun": latest ?: (id)NSNull.null};
}

/* A card shaped exactly like SRStore.ruleCardsForPlan: now returns it, with the
 * frozen target identifiers in their durable order. */
static NSDictionary *cardWithTargets(NSString *identifier, NSString *name, NSArray *targets,
                                     NSDictionary *latest) {
    return @{@"id": identifier, @"name": name, @"targetCount": @(targets.count),
        @"targetIdentifiers": targets, @"initialUnlocked": @YES, @"accountOccupied": @NO,
        @"latestRun": latest ?: (id)NSNull.null};
}

static BOOL wellFormedMinute(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length != 16) return NO;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    NSArray *fields = @[[NSValue valueWithRange:NSMakeRange(0, 4)], [NSValue valueWithRange:NSMakeRange(5, 2)],
        [NSValue valueWithRange:NSMakeRange(8, 2)], [NSValue valueWithRange:NSMakeRange(11, 2)],
        [NSValue valueWithRange:NSMakeRange(14, 2)]];
    for (NSValue *boxed in fields) {
        NSRange field = boxed.rangeValue;
        for (NSUInteger index = field.location; index < NSMaxRange(field); index++)
            if (![digits characterIsMember:[text characterAtIndex:index]]) return NO;
    }
    return [text characterAtIndex:4] == '-' && [text characterAtIndex:7] == '-' &&
        [text characterAtIndex:10] == ' ' && [text characterAtIndex:13] == ':';
}

/* Source times are rendered as "yyyy-MM-dd HH:mm:ss zzz". A minute-only text is
 * a different format, so seconds and a non-empty zone suffix are checked
 * separately instead of widening the minute check. The suffix is compared for
 * presence only: a zone may be a name ("UTC", "CST") or an offset ("GMT+8"). */
static BOOL wellFormedSecondsWithZone(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length < 20) return NO;
    if (!wellFormedMinute([text substringToIndex:16])) return NO;
    if ([text characterAtIndex:16] != ':' || [text characterAtIndex:19] != ' ') return NO;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    if (![digits characterIsMember:[text characterAtIndex:17]]) return NO;
    if (![digits characterIsMember:[text characterAtIndex:18]]) return NO;
    NSString *zone = [text substringFromIndex:20];
    if (!zone.length) return NO;
    if ([zone rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound) return YES;
    return [zone rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"+-"]].location != NSNotFound;
}

static void checkTimeTexts(void) {
    CHECK([[SRRunProjection localDateTimeText:nil] isEqual:@"未记录"]);
    CHECK([[SRRunProjection localDateTimeText:@0] isEqual:@"未记录"]);
    CHECK([[SRRunProjection localDateTimeText:@(-5)] isEqual:@"未记录"]);
    // A boolean is an NSNumber but never a time; it must not become 1970-01-01.
    CHECK([[SRRunProjection localDateTimeText:@YES] isEqual:@"未记录"]);
    CHECK([[SRRunProjection localDateTimeText:@"2026-10-22"] isEqual:@"未记录"]);
    CHECK([[SRRunProjection localDateTimeText:NSNull.null] isEqual:@"未记录"]);

    NSNumber *first = @(1792700000);           // a fixed synthetic instant
    NSNumber *nextDay = @(1792700000 + 86400);
    NSString *firstText = [SRRunProjection localDateTimeText:first];
    CHECK(wellFormedMinute(firstText));
    CHECK([firstText isEqual:[SRRunProjection localDateTimeText:first]]);
    // A day later keeps the same wall-clock minute but must show another date.
    NSString *nextText = [SRRunProjection localDateTimeText:nextDay];
    CHECK(wellFormedMinute(nextText));
    CHECK(![[firstText substringToIndex:10] isEqual:[nextText substringToIndex:10]]);
    CHECK([[firstText substringFromIndex:11] isEqual:[nextText substringFromIndex:11]]);
    // The date row and the date-time row agree, so a run that crosses midnight
    // still carries both parts.
    CHECK([[SRRunProjection localDateText:first] isEqual:[firstText substringToIndex:10]]);
    CHECK([[SRRunProjection localDateText:nil] isEqual:@"未记录"]);

    CHECK([[SRRunProjection localTimeWithZoneText:nil] isEqual:@"未记录"]);
    /* The source-time rows carry seconds and a zone; the run start/end rows keep
     * the minute format, so the two checks stay separate. */
    CHECK(wellFormedSecondsWithZone([SRRunProjection localTimeWithZoneText:first]));
    CHECK(!wellFormedSecondsWithZone([SRRunProjection localDateTimeText:first]));
    CHECK(!wellFormedSecondsWithZone(@"2026-10-22 23:33"));
    CHECK(!wellFormedSecondsWithZone(@"2026-10-22 23:33:20"));
    CHECK(!wellFormedSecondsWithZone(@"2026-10-22 23:33:20 "));
    CHECK(!wellFormedSecondsWithZone(@"未记录"));
    // A synthetic rendering of the documented format is accepted.
    CHECK(wellFormedSecondsWithZone(@"2026-10-22 23:33:20 GMT+8"));
    CHECK(wellFormedSecondsWithZone(@"2026-10-22 23:33:20 UTC"));

    CHECK([[SRRunProjection unverifiedHostTimeText:nil] isEqual:@"未记录 / 语义未验证"]);
    CHECK([[SRRunProjection unverifiedHostTimeText:@YES] isEqual:@"未记录 / 语义未验证"]);
    NSString *raw = [SRRunProjection unverifiedHostTimeText:@1710000000123];
    CHECK([raw containsString:@"1710000000123"]);
    CHECK([raw containsString:@"语义未验证"]);
    // The host value is never rendered as a date.
    CHECK(![raw containsString:@"-"]);
}

static void checkRunPhases(void) {
    NSDictionary *none = counts(3, 0, 0, 0, 0, 0, 0);
    CHECK([[SRRunProjection phaseForState:nil cancelled:NO counts:none] isEqual:SRRunPhaseNotStarted]);
    CHECK([[SRRunProjection phaseForState:@"running" cancelled:NO counts:none] isEqual:SRRunPhaseRunning]);
    CHECK([[SRRunProjection phaseForState:@"paused" cancelled:NO counts:counts(2, 0, 1, 0, 0, 0, 0)] isEqual:SRRunPhasePaused]);
    CHECK([[SRRunProjection phaseForState:@"awaiting_resume" cancelled:NO counts:none] isEqual:SRRunPhasePaused]);
    // An in-flight attempt turns a pause into a settling state, never "继续".
    CHECK([[SRRunProjection phaseForState:@"paused" cancelled:NO counts:counts(2, 1, 0, 0, 0, 0, 0)] isEqual:SRRunPhaseSettling]);
    CHECK([[SRRunProjection phaseForState:@"completed" cancelled:NO counts:counts(0, 0, 2, 1, 0, 0, 0)] isEqual:SRRunPhaseCompleted]);
    // A failure or an unknown outcome can never be masked by "completed".
    CHECK([[SRRunProjection phaseForState:@"completed" cancelled:NO counts:counts(0, 0, 2, 0, 1, 0, 0)] isEqual:SRRunPhaseAbnormal]);
    CHECK([[SRRunProjection phaseForState:@"completed" cancelled:NO counts:counts(0, 0, 2, 0, 0, 1, 0)] isEqual:SRRunPhaseAbnormal]);
    CHECK([[SRRunProjection phaseForState:@"ended" cancelled:YES counts:counts(0, 0, 1, 0, 0, 0, 2)] isEqual:SRRunPhaseCancelled]);
    CHECK([[SRRunProjection phaseForState:@"ended" cancelled:NO counts:counts(0, 0, 1, 0, 0, 0, 2)] isEqual:SRRunPhaseEnded]);
    CHECK([[SRRunProjection phaseForState:@"ended" cancelled:NO counts:counts(0, 0, 1, 0, 1, 0, 0)] isEqual:SRRunPhaseAbnormal]);
    CHECK([[SRRunProjection phaseForState:@"unknown_state" cancelled:NO counts:none] isEqual:SRRunPhaseUnknown]);

    // Only success phases may read as completion, and cancel never does.
    CHECK([[SRRunProjection phaseText:SRRunPhaseCompleted] isEqual:@"处理完成"]);
    CHECK([[SRRunProjection phaseText:SRRunPhaseCancelled] isEqual:@"已取消"]);
    CHECK([[SRRunProjection phaseText:SRRunPhaseSettling] containsString:@"收尾"]);
    CHECK([[SRRunProjection phaseText:SRRunPhaseAbnormal] containsString:@"异常"]);
    CHECK([[SRRunProjection phaseText:nil] isEqual:@"状态待核对"]);
    CHECK([[SRRunProjection phaseText:@"made_up"] isEqual:@"状态待核对"]);

    CHECK([SRRunProjection phaseIsActive:SRRunPhaseRunning]);
    CHECK([SRRunProjection phaseIsActive:SRRunPhasePaused]);
    CHECK([SRRunProjection phaseIsActive:SRRunPhaseSettling]);
    CHECK(![SRRunProjection phaseIsActive:SRRunPhaseCompleted]);
    CHECK(![SRRunProjection phaseIsActive:SRRunPhaseCancelled]);
    CHECK(![SRRunProjection phaseIsActive:nil]);
}

static void checkRunSummary(void) {
    NSNumber *started = @(1792700000), *ended = @(1792700900);
    NSDictionary *finished = [SRRunProjection runSummary:run(@"run-1", @"completed", started, ended, counts(0, 0, 2, 1, 0, 0, 0))];
    CHECK([finished[@"phase"] isEqual:SRRunPhaseCompleted]);
    CHECK([finished[@"state"] isEqual:@"completed"]);
    CHECK([finished[@"hasRun"] isEqual:@YES]);
    CHECK([finished[@"total"] isEqual:@3]);
    CHECK([finished[@"processed"] isEqual:@3]);
    CHECK([finished[@"inflight"] isEqual:@0]);
    CHECK([finished[@"abnormal"] isEqual:@0]);
    CHECK(wellFormedMinute(finished[@"startedText"]));
    CHECK(wellFormedMinute(finished[@"endedText"]));

    // A run with only a start time keeps the end as 未记录, never "now".
    NSDictionary *open = [SRRunProjection runSummary:run(@"run-2", @"running", started, nil, counts(2, 1, 0, 0, 0, 0, 0))];
    CHECK([open[@"endedText"] isEqual:@"未记录"]);
    CHECK([open[@"processed"] isEqual:@0]);
    CHECK([open[@"inflight"] isEqual:@1]);

    NSDictionary *unknown = [SRRunProjection runSummary:@{}];
    CHECK([unknown[@"phase"] isEqual:SRRunPhaseNotStarted]);
    CHECK([unknown[@"hasRun"] isEqual:@NO]);
    CHECK([unknown[@"total"] isEqual:@0]);
    CHECK([unknown[@"startedText"] isEqual:@"未记录"]);

    NSArray *lines = [SRRunProjection countLinesForSummary:finished];
    CHECK(lines.count == 7);
    CHECK([lines[2] isEqual:@"已提交 2"]);
    CHECK([lines[3] isEqual:@"已确认送达 1"]);
    CHECK([lines[0] isEqual:@"未尝试 0"]);
    CHECK([lines[6] isEqual:@"已取消 0"]);

    CHECK([[SRRunProjection progressTextForSummary:finished targetCount:3] isEqual:@"已处理 3/3"]);
    CHECK([[SRRunProjection progressTextForSummary:nil targetCount:5] isEqual:@"未开始 · 共 5 群"]);
}

static void checkGroupRows(void) {
    NSArray *cards = @[
        card(@"rule-a", @"Synthetic A", 3, YES, NO, nil),
        card(@"rule-b", @"Synthetic B", 2, NO, NO, nil),
        card(@"rule-c", @"Synthetic C", 4, YES, YES, nil),
        card(@"rule-d", @"Synthetic D", 5, YES, NO, run(@"run-d", @"running", @(1792700000), nil, counts(4, 1, 0, 0, 0, 0, 0)))];
    NSArray *rows = [SRRunProjection groupRowsForCards:cards];
    CHECK(rows.count == 4);

    CHECK([rows[0][@"phase"] isEqual:SRRunPhaseNotStarted]);
    CHECK([rows[0][@"executable"] isEqual:@YES]);
    CHECK([rows[0][@"blockedText"] isEqual:NSNull.null]);
    CHECK([rows[0][@"runID"] isEqual:NSNull.null]);
    CHECK([rows[0][@"progressText"] isEqual:@"未开始 · 共 3 群"]);

    // A later group waits for its predecessor.
    CHECK([rows[1][@"executable"] isEqual:@NO]);
    CHECK([rows[1][@"blockedText"] isEqual:@"等待前序分组结束"]);
    // An unlocked group on an occupied account is blocked by the account.
    CHECK([rows[2][@"executable"] isEqual:@NO]);
    CHECK([rows[2][@"blockedText"] isEqual:@"账号仍有活动批次，不能开始另一条"]);
    // The gate order is unchanged: a locked group is refused first, so a card
    // that is both locked and occupied still reports the predecessor.
    NSArray *locked = [SRRunProjection groupRowsForCards:@[card(@"rule-locked", @"Synthetic Locked", 2, NO, YES, nil)]];
    CHECK([locked[0][@"executable"] isEqual:@NO]);
    CHECK([locked[0][@"blockedText"] isEqual:@"等待前序分组结束"]);

    CHECK([rows[3][@"phase"] isEqual:SRRunPhaseRunning]);
    CHECK([rows[3][@"runID"] isEqual:@"run-d"]);
    CHECK([rows[3][@"executable"] isEqual:@NO]);
    CHECK([rows[3][@"progressText"] isEqual:@"已处理 0/5"]);

    // The rows never mutate the frozen cards they were built from.
    CHECK([cards[0] count] == 6);
    CHECK([cards[0][@"latestRun"] isEqual:NSNull.null]);
    CHECK([cards[3][@"latestRun"][@"id"] isEqual:@"run-d"]);
    CHECK([cards[3][@"latestRun"][@"state"] isEqual:@"running"]);

    NSDictionary *overview = [SRRunProjection overviewForGroupRows:rows];
    CHECK([overview[@"groups"] isEqual:@4]);
    CHECK([overview[@"targets"] isEqual:@14]);
    CHECK([overview[@"started"] isEqual:@1]);
    CHECK([overview[@"unstarted"] isEqual:@3]);
    // Only the started group contributes to the progress line.
    CHECK([overview[@"total"] isEqual:@5]);
    CHECK([overview[@"processed"] isEqual:@0]);
    CHECK([overview[@"limited"] isEqual:@0]);
    CHECK([overview[@"abnormal"] isEqual:@0]);

    NSDictionary *empty = [SRRunProjection overviewForGroupRows:@[]];
    CHECK([empty[@"groups"] isEqual:@0] && [empty[@"targets"] isEqual:@0]);
    CHECK([empty[@"unstarted"] isEqual:@0] && [empty[@"total"] isEqual:@0]);
    CHECK([[SRRunProjection overviewForGroupRows:nil][@"groups"] isEqual:@0]);
    CHECK([[SRRunProjection groupRowsForCards:@[]] count] == 0);
    CHECK([[SRRunProjection groupRowsForCards:nil] count] == 0);
}

static void checkTargetLimit(void) {
    CHECK(SRRunProjectionTargetLimit == 20);
    NSArray *over = [SRRunProjection groupRowsForCards:@[card(@"rule-big", @"Synthetic Big", 21, YES, NO, nil)]];
    CHECK(over.count == 1);
    CHECK([over[0][@"executable"] isEqual:@NO]);
    CHECK([over[0][@"targetCount"] isEqual:@21]);
    CHECK([over[0][@"blockedText"] isEqual:[NSString stringWithFormat:
        @"超过每条 20 群的执行范围，本组不可执行；不会截取前 20 群"]]);
    // Exactly 20 is still executable; nothing is truncated.
    NSArray *exact = [SRRunProjection groupRowsForCards:@[card(@"rule-20", @"Synthetic Twenty", 20, YES, NO, nil)]];
    CHECK([exact[0][@"executable"] isEqual:@YES]);
    CHECK([exact[0][@"blockedText"] isEqual:NSNull.null]);
    CHECK([[SRRunProjection overviewForGroupRows:over][@"limited"] isEqual:@1]);
}

static void checkConfigurationRows(void) {
    NSDictionary *configuration = @{@"schema": @1, @"rules": @[
        @{@"id": @"draft-a", @"name": @"Synthetic Draft A", @"targets": @[
            @{@"id": @"1@chatroom", @"name": @"Synthetic One"}, @{@"id": @"2@chatroom", @"name": @"Synthetic Two"}]},
        @{@"id": @"draft-b", @"name": @"Synthetic Draft B", @"targets": @[
            @{@"id": @"3@chatroom", @"name": @"Synthetic Three"}]}]};
    NSArray *rows = [SRRunProjection groupRowsForConfiguration:configuration];
    CHECK(rows.count == 2);
    CHECK([rows[0][@"targetCount"] isEqual:@2]);
    CHECK([rows[0][@"targets"][1] isEqual:@"2@chatroom"]);
    CHECK([rows[0][@"targetNames"][1] isEqual:@"Synthetic Two"]);
    // Nothing from a saved configuration may be executable.
    CHECK([rows[0][@"executable"] isEqual:@NO]);
    CHECK([rows[1][@"executable"] isEqual:@NO]);
    CHECK([[rows[0][@"blockedText"] description] containsString:@"不能发送"]);
    CHECK([[SRRunProjection groupRowsForConfiguration:@{}] count] == 0);
    CHECK([[SRRunProjection groupRowsForConfiguration:nil] count] == 0);
}

static void checkSearchAndFilter(void) {
    NSArray *cards = @[
        card(@"rule-a", @"Alpha", 2, YES, NO, nil),
        card(@"rule-b", @"Beta", 2, NO, NO, run(@"run-b", @"paused", @(1792700000), nil, counts(1, 0, 1, 0, 0, 0, 0))),
        card(@"rule-c", @"Gamma", 2, NO, NO, run(@"run-c", @"completed", @(1792700000), @(1792700100), counts(0, 0, 1, 1, 0, 0, 0))),
        card(@"rule-d", @"Delta", 2, NO, NO, run(@"run-d", @"completed", @(1792700000), @(1792700100), counts(0, 0, 1, 0, 1, 0, 0)))];
    NSArray *rows = [SRRunProjection groupRowsForCards:cards];
    NSArray *snapshot = [rows copy];

    CHECK([SRRunProjection filterIdentifiers].count == 5);
    CHECK([[SRRunProjection titleForFilter:SRGroupFilterAll] isEqual:@"全部"]);

    CHECK([[SRRunProjection rows:rows matchingText:nil filter:SRGroupFilterAll] count] == 4);
    CHECK([[SRRunProjection rows:rows matchingText:@"" filter:SRGroupFilterNotStarted] count] == 1);
    CHECK([[SRRunProjection rows:rows matchingText:nil filter:SRGroupFilterActive] count] == 1);
    CHECK([[SRRunProjection rows:rows matchingText:nil filter:SRGroupFilterCompleted] count] == 1);
    CHECK([[SRRunProjection rows:rows matchingText:nil filter:SRGroupFilterAbnormal] count] == 1);
    // An unknown filter falls back to showing everything, not to a crash.
    CHECK([[SRRunProjection rows:rows matchingText:nil filter:@"nonsense"] count] == 4);
    CHECK([[SRRunProjection rows:rows matchingText:nil filter:nil] count] == 4);

    // Search is case- and diacritic-insensitive over the group name and the
    // target identifiers of a configuration row.
    CHECK([[SRRunProjection rows:rows matchingText:@"bet" filter:SRGroupFilterAll] count] == 1);
    CHECK([[SRRunProjection rows:rows matchingText:@"GAMMA" filter:SRGroupFilterAll] count] == 1);
    CHECK([[SRRunProjection rows:rows matchingText:@"nothing" filter:SRGroupFilterAll] count] == 0);
    NSArray *configurationRows = [SRRunProjection groupRowsForConfiguration:@{@"schema": @1, @"rules": @[
        @{@"id": @"draft-a", @"name": @"Alpha", @"targets": @[@{@"id": @"9@chatroom", @"name": @"Synthetic Nine"}]}]}];
    CHECK([[SRRunProjection rows:configurationRows matchingText:@"nine" filter:SRGroupFilterAll] count] == 1);
    CHECK([[SRRunProjection rows:configurationRows matchingText:@"9@chatroom" filter:SRGroupFilterAll] count] == 1);

    // A completed run with a failure is listed under 有异常, not 已完成.
    CHECK(![[SRRunProjection rows:@[rows[3]] matchingText:nil filter:SRGroupFilterCompleted] count]);
    CHECK([[SRRunProjection rows:@[rows[3]] matchingText:nil filter:SRGroupFilterAbnormal] count] == 1);

    // Filtering and searching never rewrite the frozen rows.
    CHECK([rows isEqualToArray:snapshot]);
    CHECK([rows[3][@"phase"] isEqual:SRRunPhaseAbnormal]);
    CHECK([rows[3][@"executable"] isEqual:@NO]);
    CHECK([[SRRunProjection rows:nil matchingText:@"x" filter:SRGroupFilterAll] count] == 0);
}

static void checkLatestRunSelection(void) {
    NSDictionary *older = run(@"run-old", @"completed", @(1792700000), @(1792700100), counts(0, 0, 1, 0, 0, 0, 0));
    NSMutableDictionary *olderWithOrder = [older mutableCopy];
    olderWithOrder[@"creationOrder"] = @7;
    NSDictionary *newer = run(@"run-new", @"ended", @(1792710000), @(1792710100), counts(0, 0, 0, 0, 0, 0, 2));
    NSMutableDictionary *newerWithOrder = [newer mutableCopy];
    newerWithOrder[@"creationOrder"] = @9;
    NSArray *cards = @[card(@"rule-a", @"Alpha", 2, NO, NO, olderWithOrder),
                       card(@"rule-b", @"Beta", 2, NO, NO, newerWithOrder),
                       // A running group must not become the "latest result".
                       card(@"rule-c", @"Gamma", 2, NO, NO, run(@"run-live", @"running", @(1792720000), nil, counts(2, 0, 0, 0, 0, 0, 0)))];
    NSDictionary *latest = [SRRunProjection latestRunInCards:cards];
    CHECK([latest[@"id"] isEqual:@"run-new"]);
    CHECK([SRRunProjection latestRunInCards:@[]] == nil);
    CHECK([SRRunProjection latestRunInCards:nil] == nil);
    CHECK([SRRunProjection latestRunInCards:@[card(@"rule-a", @"Alpha", 2, YES, NO, nil)]] == nil);
}

static void checkFrozenTargetSearch(void) {
    NSArray *targets = @[@"first@chatroom", @"second@chatroom", @"third@chatroom"];
    NSArray *cards = @[cardWithTargets(@"rule-a", @"Synthetic A", targets, nil),
                       // A card that carries no identifiers stays empty rather
                       // than borrowing another row's targets.
                       card(@"rule-b", @"Synthetic B", 2, NO, NO, nil)];
    NSArray *rows = [SRRunProjection groupRowsForCards:cards];
    CHECK(rows.count == 2);
    // The frozen identifiers survive in position order.
    CHECK([rows[0][@"targets"] isEqual:targets]);
    CHECK([rows[0][@"targets"][0] isEqual:@"first@chatroom"]);
    CHECK([rows[0][@"targets"][2] isEqual:@"third@chatroom"]);
    CHECK([rows[0][@"targetCount"] isEqual:@3]);
    // Names are never invented for a frozen plan.
    CHECK([rows[0][@"targetNames"] isEqual:@[]]);
    CHECK([rows[1][@"targets"] isEqual:@[]]);

    // Search reaches the frozen identifiers of the row and nothing else.
    CHECK([[SRRunProjection rows:rows matchingText:@"second@" filter:SRGroupFilterAll] count] == 1);
    CHECK([[SRRunProjection rows:rows matchingText:@"THIRD@chat" filter:SRGroupFilterAll] count] == 1);
    CHECK([[SRRunProjection rows:rows matchingText:@"no-such-target" filter:SRGroupFilterAll] count] == 0);
    CHECK([[SRRunProjection rows:rows matchingText:@"Synthetic A" filter:SRGroupFilterAll] count] == 1);

    // The projection copies instead of exposing the card's own array.
    NSMutableArray *mutable = [targets mutableCopy];
    NSDictionary *mutableCard = cardWithTargets(@"rule-c", @"Synthetic C", mutable, nil);
    NSArray *copied = [SRRunProjection groupRowsForCards:@[mutableCard]][0][@"targets"];
    [mutable addObject:@"late@chatroom"];
    CHECK(copied.count == 3);
    CHECK(![copied containsObject:@"late@chatroom"]);

    // Filtering still does not rewrite the card it came from.
    (void)[SRRunProjection rows:rows matchingText:@"first@" filter:SRGroupFilterNotStarted];
    CHECK([cards[0][@"targetIdentifiers"] isEqual:targets]);
    CHECK([cards[0][@"targetCount"] isEqual:@3]);
}

/* The identity decision the run-detail page uses. It is pure, so the four
 * regression shapes are executed here rather than asserted as source text. */
static void checkStalePageBinding(void) {
    // 1. A "no run" page after a run appeared is stale.
    CHECK([SRRunProjection pageIsStaleForBoundRun:nil currentRunID:@"run-new"]);
    // ... and stays usable while no run exists.
    CHECK(![SRRunProjection pageIsStaleForBoundRun:nil currentRunID:nil]);
    // 2. A page bound to an old run is stale once the current run differs.
    CHECK([SRRunProjection pageIsStaleForBoundRun:@"run-old" currentRunID:@"run-new"]);
    // 3. A page bound to a run that is now missing is stale.
    CHECK([SRRunProjection pageIsStaleForBoundRun:@"run-old" currentRunID:nil]);
    // 4. After this page's own successful start it adopts the new id and is
    //    current again, so its controls stay available.
    NSString *adopted = @"run-new";
    CHECK(![SRRunProjection pageIsStaleForBoundRun:adopted currentRunID:@"run-new"]);
    // 5. The same id on both sides is never stale, whatever the ordering.
    CHECK(![SRRunProjection pageIsStaleForBoundRun:@"run-same" currentRunID:@"run-same"]);
    // Empty strings are treated as "no run", never as a real identity.
    CHECK(![SRRunProjection pageIsStaleForBoundRun:@"" currentRunID:@""]);
    CHECK([SRRunProjection pageIsStaleForBoundRun:@"" currentRunID:@"run-x"]);
    // Non-string junk cannot masquerade as a bound run.
    CHECK(![SRRunProjection pageIsStaleForBoundRun:(id)NSNull.null currentRunID:nil]);
}

static void checkContentProjection(void) {
    NSDictionary *text = @{@"type": @"text", @"group": @"synthetic@chatroom", @"payload": @{@"text": @"Synthetic body"}};
    CHECK([[SRRunProjection excerptForEnvelope:text limit:0] isEqual:@"Synthetic body"]);
    /* An ASCII excerpt stops exactly at the limit: 8 characters, not 8 then the
     * rest of the first word. */
    CHECK([[SRRunProjection excerptForEnvelope:text limit:8] isEqual:@"Syntheti"]);
    CHECK([[SRRunProjection excerptForEnvelope:text limit:8] length] == 8);
    // Boundary: at the limit the text is returned whole, one more is trimmed.
    NSDictionary *exact = @{@"type": @"text", @"payload": @{@"text": @"ABCDEFGH"}};
    NSDictionary *over = @{@"type": @"text", @"payload": @{@"text": @"ABCDEFGHI"}};
    CHECK([[SRRunProjection excerptForEnvelope:exact limit:8] isEqual:@"ABCDEFGH"]);
    CHECK([[SRRunProjection excerptForEnvelope:over limit:8] isEqual:@"ABCDEFGH"]);
    CHECK([[SRRunProjection excerptForEnvelope:over limit:9] isEqual:@"ABCDEFGHI"]);
    CHECK([[SRRunProjection excerptForEnvelope:over limit:100] isEqual:@"ABCDEFGHI"]);
    CHECK([[SRRunProjection typeTextForEnvelope:text] isEqual:@"文字"]);
    CHECK([[SRRunProjection typeTextForEnvelope:nil] isEqual:@"未记录"]);
    CHECK([[SRRunProjection typeTextForEnvelope:@{@"type": @"video"}] containsString:@"未支持"]);
    CHECK([[SRRunProjection excerptForEnvelope:@{} limit:40] containsString:@"没有可用的内容摘要"]);
    CHECK([[SRRunProjection excerptForEnvelope:nil limit:40] containsString:@"没有可用的内容摘要"]);

    NSDictionary *image = @{@"type": @"image", @"payload": @{@"pixelWidth": @640, @"pixelHeight": @480, @"byteCount": @2048}};
    NSString *described = [SRRunProjection excerptForEnvelope:image limit:40];
    CHECK([described containsString:@"640"]);
    CHECK([described containsString:@"480"]);
    CHECK([described containsString:@"2.0 KB"]);

    // Source times keep their separate meanings: only the two plugin-measured
    // values become a wall clock, the host value stays raw.
    NSDictionary *envelope = @{@"type": @"text", @"sourceTime": @{@"receivedAt": @(1792700000),
        @"previewFrozenAt": @(1792700005), @"createdAt": @1710000000123}};
    CHECK(wellFormedSecondsWithZone([SRRunProjection observedTimeTextForEnvelope:envelope]));
    CHECK(wellFormedSecondsWithZone([SRRunProjection frozenTimeTextForEnvelope:envelope]));
    CHECK(![[SRRunProjection observedTimeTextForEnvelope:envelope] isEqual:[SRRunProjection frozenTimeTextForEnvelope:envelope]]);
    CHECK([[SRRunProjection hostTimeTextForEnvelope:envelope] containsString:@"1710000000123"]);
    CHECK([[SRRunProjection hostTimeTextForEnvelope:envelope] containsString:@"语义未验证"]);
    CHECK([[SRRunProjection hostTimeTextForEnvelope:@{}] isEqual:@"未记录 / 语义未验证"]);
    CHECK([[SRRunProjection observedTimeTextForEnvelope:@{}] isEqual:@"未记录"]);
    CHECK([[SRRunProjection frozenTimeTextForEnvelope:nil] isEqual:@"未记录"]);
    CHECK([[SRRunProjection observedTimeTextForEnvelope:@{@"sourceTime": @{@"receivedAt": @YES}}] isEqual:@"未记录"]);
}

int main(void) {
    @autoreleasepool {
        checkTimeTexts();
        checkRunPhases();
        checkRunSummary();
        checkGroupRows();
        checkTargetLimit();
        checkConfigurationRows();
        checkSearchAndFilter();
        checkLatestRunSelection();
        checkFrozenTargetSearch();
        checkStalePageBinding();
        checkContentProjection();
        puts("PASS: pure Phase B projections cover empty/preview/confirmed inputs, per-run phase and count "
             "separation, the 20-group limit, read-only search and filter, frozen target identifiers, "
             "stale page binding, missing/cross-day time text, and unverified host-time semantics");
    }
    return 0;
}
