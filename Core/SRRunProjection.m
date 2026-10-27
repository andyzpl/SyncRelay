#import "SRRunProjection.h"
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>

NSString *const SRRunPhaseNotStarted = @"not_started";
NSString *const SRRunPhaseRunning = @"running";
NSString *const SRRunPhasePaused = @"paused";
NSString *const SRRunPhaseSettling = @"settling";
NSString *const SRRunPhaseCompleted = @"completed";
NSString *const SRRunPhaseAbnormal = @"abnormal";
NSString *const SRRunPhaseEnded = @"ended";
NSString *const SRRunPhaseCancelled = @"cancelled";
NSString *const SRRunPhaseUnknown = @"unknown";

NSString *const SRGroupFilterAll = @"all";
NSString *const SRGroupFilterNotStarted = @"not_started";
NSString *const SRGroupFilterActive = @"active";
NSString *const SRGroupFilterCompleted = @"completed";
NSString *const SRGroupFilterAbnormal = @"abnormal";

NSUInteger const SRRunProjectionTargetLimit = 20;

static NSArray<NSString *> *SRProjectionCountKeys(void) {
    return @[@"pending", @"submitting", @"submitted", @"confirmed", @"failed", @"uncertain", @"cancelled"];
}

/* A boolean is an NSNumber but never a time, so it must stay "未记录" instead
 * of being rendered as 1970-01-01. */
static BOOL SRProjectionTimeValue(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number > 0;
}

static NSString *SRProjectionFormat(id value, NSString *format, NSString *missing) {
    if (!SRProjectionTimeValue(value)) return missing;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = NSTimeZone.localTimeZone;
    formatter.dateFormat = format;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[(NSNumber *)value doubleValue]];
    return [formatter stringFromDate:date] ?: missing;
}

static NSDictionary *SRProjectionCounts(id value) {
    NSMutableDictionary *counts = [NSMutableDictionary dictionaryWithCapacity:SRProjectionCountKeys().count];
    for (NSString *key in SRProjectionCountKeys()) {
        id number = [value isKindOfClass:NSDictionary.class] ? ((NSDictionary *)value)[key] : nil;
        BOOL usable = [number isKindOfClass:NSNumber.class] && isfinite([number doubleValue]) && [number doubleValue] >= 0;
        counts[key] = usable ? @([number unsignedLongLongValue]) : @0;
    }
    return counts;
}

static NSUInteger SRProjectionTotal(NSDictionary *counts) {
    NSUInteger total = 0;
    for (NSString *key in SRProjectionCountKeys()) total += [counts[key] unsignedIntegerValue];
    return total;
}

static NSUInteger SRProjectionValue(NSDictionary *counts, NSString *key) {
    return [counts[key] unsignedIntegerValue];
}

static NSUInteger SRProjectionAbnormal(NSDictionary *counts) {
    return SRProjectionValue(counts, @"failed") + SRProjectionValue(counts, @"uncertain");
}

static NSDictionary *SRProjectionSourceTime(id envelope) {
    if (![envelope isKindOfClass:NSDictionary.class]) return @{};
    id time = ((NSDictionary *)envelope)[@"sourceTime"];
    return [time isKindOfClass:NSDictionary.class] ? time : @{};
}

static NSString *SRProjectionString(id value, NSString *fallback) {
    return [value isKindOfClass:NSString.class] && [(NSString *)value length] ? value : fallback;
}

@interface SRRunProjection ()
+ (BOOL)phase:(NSString *)phase matchesFilter:(NSString *)filter;
@end

@implementation SRRunProjection

+ (NSString *)localDateTimeText:(id)value {
    return SRProjectionFormat(value, @"yyyy-MM-dd HH:mm", @"未记录");
}

+ (NSString *)localDateText:(id)value {
    return SRProjectionFormat(value, @"yyyy-MM-dd", @"未记录");
}

+ (NSString *)localTimeWithZoneText:(id)value {
    return SRProjectionFormat(value, @"yyyy-MM-dd HH:mm:ss zzz", @"未记录");
}

+ (NSString *)unverifiedHostTimeText:(id)value {
    if (!SRProjectionTimeValue(value)) return @"未记录 / 语义未验证";
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator = NO;
    formatter.minimumFractionDigits = 0;
    formatter.maximumFractionDigits = 3;
    NSString *raw = [formatter stringFromNumber:(NSNumber *)value] ?: @"未记录";
    return [NSString stringWithFormat:@"%@（原始值 · 单位/语义未验证）", raw];
}

+ (NSString *)observedTimeTextForEnvelope:(NSDictionary *)envelope {
    return [self localTimeWithZoneText:SRProjectionSourceTime(envelope)[@"receivedAt"]];
}

+ (NSString *)frozenTimeTextForEnvelope:(NSDictionary *)envelope {
    return [self localTimeWithZoneText:SRProjectionSourceTime(envelope)[@"previewFrozenAt"]];
}

+ (NSString *)hostTimeTextForEnvelope:(NSDictionary *)envelope {
    return [self unverifiedHostTimeText:SRProjectionSourceTime(envelope)[@"createdAt"]];
}

+ (NSString *)typeTextForEnvelope:(NSDictionary *)envelope {
    NSString *type = SRProjectionString([envelope isKindOfClass:NSDictionary.class] ? envelope[@"type"] : nil, nil);
    if ([type isEqual:@"text"]) return @"文字";
    if ([type isEqual:@"image"]) return @"图片";
    return type ? [NSString stringWithFormat:@"未支持的类型（%@）", type] : @"未记录";
}

+ (NSString *)excerptForEnvelope:(NSDictionary *)envelope limit:(NSUInteger)limit {
    NSDictionary *source = [envelope isKindOfClass:NSDictionary.class] ? envelope : @{};
    id payload = source[@"payload"];
    if ([SRProjectionString(source[@"type"], nil) isEqual:@"image"]) {
        NSDictionary *image = [payload isKindOfClass:NSDictionary.class] ? payload : @{};
        return [NSString stringWithFormat:@"图片快照 · %@ × %@ · %.1f KB",
            image[@"pixelWidth"] ?: @"未记录", image[@"pixelHeight"] ?: @"未记录",
            [image[@"byteCount"] isKindOfClass:NSNumber.class] ? [image[@"byteCount"] doubleValue] / 1024.0 : 0.0];
    }
    NSString *text = ([payload isKindOfClass:NSDictionary.class] && [payload[@"text"] isKindOfClass:NSString.class])
        ? payload[@"text"] : nil;
    if (!text.length) return @"没有可用的内容摘要，请重新捕获。";
    if (limit == 0 || text.length <= limit) return text;
    NSRange range = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, limit)];
    return [text substringWithRange:range];
}

+ (NSString *)phaseForState:(NSString *)state cancelled:(BOOL)cancelled counts:(NSDictionary *)counts {
    if (![state isKindOfClass:NSString.class] || ![(NSString *)state length]) return SRRunPhaseNotStarted;
    NSDictionary *normalized = SRProjectionCounts(counts);
    NSUInteger inflight = SRProjectionValue(normalized, @"submitting");
    BOOL abnormal = SRProjectionAbnormal(normalized) > 0;
    if ([@[@"paused", @"awaiting_resume"] containsObject:state])
        return inflight ? SRRunPhaseSettling : SRRunPhasePaused;
    if ([state isEqual:@"running"]) return SRRunPhaseRunning;
    if ([state isEqual:@"completed"]) return abnormal ? SRRunPhaseAbnormal : SRRunPhaseCompleted;
    if ([state isEqual:@"ended"]) {
        // A cancelled run is reported as cancelled even when unattempted targets
        // were also recorded as cancelled deliveries; it never reads as success.
        if (cancelled) return SRRunPhaseCancelled;
        return abnormal ? SRRunPhaseAbnormal : SRRunPhaseEnded;
    }
    return SRRunPhaseUnknown;
}

+ (NSString *)phaseText:(NSString *)phase {
    NSDictionary *texts = @{SRRunPhaseNotStarted: @"未开始", SRRunPhaseRunning: @"执行中",
        SRRunPhasePaused: @"已暂停 · 等待继续未发", SRRunPhaseSettling: @"收尾中 · 等待在途结果",
        SRRunPhaseCompleted: @"处理完成", SRRunPhaseAbnormal: @"有异常 · 处理已结束",
        SRRunPhaseEnded: @"已结束 · 未完成", SRRunPhaseCancelled: @"已取消",
        SRRunPhaseUnknown: @"状态待核对"};
    if (![phase isKindOfClass:NSString.class]) return texts[SRRunPhaseUnknown];
    return texts[phase] ?: texts[SRRunPhaseUnknown];
}

+ (BOOL)phaseIsActive:(NSString *)phase {
    if (![phase isKindOfClass:NSString.class]) return NO;
    return [@[SRRunPhaseRunning, SRRunPhasePaused, SRRunPhaseSettling] containsObject:phase];
}

+ (BOOL)pageIsStaleForBoundRun:(NSString *)boundRunID currentRunID:(NSString *)currentRunID {
    NSString *bound = SRProjectionString(boundRunID, nil);
    NSString *current = SRProjectionString(currentRunID, nil);
    // A page that displayed "no run" is stale as soon as any run exists.
    if (!bound) return current != nil;
    // A page bound to one run is stale when that run is gone or replaced.
    return !(current && [current isEqual:bound]);
}

+ (NSDictionary *)runSummary:(NSDictionary *)run {
    NSDictionary *source = [run isKindOfClass:NSDictionary.class] ? run : @{};
    NSDictionary *counts = SRProjectionCounts(source[@"counts"]);
    NSString *state = SRProjectionString(source[@"state"], nil);
    BOOL cancelled = [source[@"cancelled"] isEqual:@YES];
    NSString *phase = [self phaseForState:state cancelled:cancelled counts:counts];
    NSUInteger total = SRProjectionTotal(counts);
    NSUInteger inflight = SRProjectionValue(counts, @"submitting");
    NSUInteger pending = SRProjectionValue(counts, @"pending");
    NSUInteger processed = total > (inflight + pending) ? total - inflight - pending : 0;
    return @{@"state": state ?: NSNull.null, @"phase": phase, @"phaseText": [self phaseText:phase],
        @"counts": counts, @"total": @(total), @"processed": @(processed), @"inflight": @(inflight),
        @"abnormal": @(SRProjectionAbnormal(counts)), @"cancelled": @(cancelled),
        @"startedText": [self localDateTimeText:source[@"started_at"]],
        @"endedText": [self localDateTimeText:source[@"ended_at"]],
        @"hasRun": @(state != nil)};
}

+ (NSArray<NSString *> *)countLinesForSummary:(NSDictionary *)summary {
    NSDictionary *counts = [summary isKindOfClass:NSDictionary.class] ? summary[@"counts"] : nil;
    NSDictionary *normalized = SRProjectionCounts(counts);
    return @[
        [NSString stringWithFormat:@"未尝试 %lu", (unsigned long)SRProjectionValue(normalized, @"pending")],
        [NSString stringWithFormat:@"在途 %lu", (unsigned long)SRProjectionValue(normalized, @"submitting")],
        [NSString stringWithFormat:@"已提交 %lu", (unsigned long)SRProjectionValue(normalized, @"submitted")],
        [NSString stringWithFormat:@"已确认送达 %lu", (unsigned long)SRProjectionValue(normalized, @"confirmed")],
        [NSString stringWithFormat:@"失败 %lu", (unsigned long)SRProjectionValue(normalized, @"failed")],
        [NSString stringWithFormat:@"结果未知 %lu", (unsigned long)SRProjectionValue(normalized, @"uncertain")],
        [NSString stringWithFormat:@"已取消 %lu", (unsigned long)SRProjectionValue(normalized, @"cancelled")]];
}

+ (NSString *)progressTextForSummary:(NSDictionary *)summary targetCount:(NSUInteger)targetCount {
    if (![summary isKindOfClass:NSDictionary.class]) {
        return [NSString stringWithFormat:@"未开始 · 共 %lu 群", (unsigned long)targetCount];
    }
    NSUInteger total = [summary[@"total"] unsignedIntegerValue] ?: targetCount;
    return [NSString stringWithFormat:@"已处理 %lu/%lu", (unsigned long)[summary[@"processed"] unsignedIntegerValue],
        (unsigned long)total];
}

+ (NSArray<NSDictionary *> *)groupRowsForCards:(NSArray<NSDictionary *> *)cards {
    NSMutableArray *rows = [NSMutableArray array];
    if (![cards isKindOfClass:NSArray.class]) return rows;
    for (id entry in cards) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *card = entry;
        NSUInteger targetCount = [card[@"targetCount"] unsignedIntegerValue];
        NSDictionary *run = [card[@"latestRun"] isKindOfClass:NSDictionary.class] ? card[@"latestRun"] : nil;
        NSDictionary *summary = run ? [self runSummary:run] : nil;
        NSString *phase = summary ? summary[@"phase"] : SRRunPhaseNotStarted;
        BOOL unlocked = [card[@"initialUnlocked"] isEqual:@YES];
        BOOL occupied = [card[@"accountOccupied"] isEqual:@YES];
        NSString *blocked = nil;
        if (targetCount > SRRunProjectionTargetLimit)
            blocked = [NSString stringWithFormat:@"超过每条 %lu 群的执行范围，本组不可执行；不会截取前 %lu 群",
                (unsigned long)SRRunProjectionTargetLimit, (unsigned long)SRRunProjectionTargetLimit];
        else if (!run && !unlocked) blocked = @"等待前序分组结束";
        else if (!run && occupied) blocked = @"账号仍有活动批次，不能开始另一条";
        NSString *title = SRProjectionString(card[@"name"], @"未命名分组");
        // Only what the frozen plan actually stored: identifiers in position
        // order. Target names are never present in a freeze, so they stay empty.
        NSArray *identifiers = [card[@"targetIdentifiers"] isKindOfClass:NSArray.class]
            ? [card[@"targetIdentifiers"] copy] : @[];
        [rows addObject:@{
            @"identifier": SRProjectionString(card[@"id"], @""),
            @"name": title,
            @"targetCount": @(targetCount),
            @"targets": identifiers,
            @"targetNames": @[],
            @"phase": phase,
            @"statusText": [self phaseText:phase],
            @"progressText": [self progressTextForSummary:summary targetCount:targetCount],
            @"blockedText": blocked ?: (id)NSNull.null,
            @"executable": @(!blocked && !run),
            @"runID": summary ? (run[@"id"] ?: (id)NSNull.null) : (id)NSNull.null,
            @"run": summary ?: (id)NSNull.null}];
    }
    return rows;
}

+ (NSArray<NSDictionary *> *)groupRowsForConfiguration:(NSDictionary *)configuration {
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *rules = [configuration isKindOfClass:NSDictionary.class] ? configuration[@"rules"] : nil;
    if (![rules isKindOfClass:NSArray.class]) return rows;
    for (id entry in rules) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *rule = entry;
        NSArray *targets = [rule[@"targets"] isKindOfClass:NSArray.class] ? rule[@"targets"] : @[];
        NSMutableArray *identifiers = [NSMutableArray array], *names = [NSMutableArray array];
        for (id row in targets) {
            if (![row isKindOfClass:NSDictionary.class]) continue;
            NSString *identifier = SRProjectionString(row[@"id"], nil);
            if (identifier) [identifiers addObject:identifier];
            NSString *name = SRProjectionString(row[@"name"], nil);
            if (name) [names addObject:name];
        }
        NSString *blocked = targets.count > SRRunProjectionTargetLimit ?
            [NSString stringWithFormat:@"超过每条 %lu 群的执行范围，本组不可执行；不会截取前 %lu 群",
                (unsigned long)SRRunProjectionTargetLimit, (unsigned long)SRRunProjectionTargetLimit] :
            @"尚未确认内容，只能查看分组和群名单，不能发送";
        [rows addObject:@{
            @"identifier": SRProjectionString(rule[@"id"], @""),
            @"name": SRProjectionString(rule[@"name"], @"未命名分组"),
            @"targetCount": @(targets.count),
            @"targets": identifiers,
            @"targetNames": names,
            @"phase": SRRunPhaseNotStarted,
            @"statusText": [self phaseText:SRRunPhaseNotStarted],
            @"progressText": [self progressTextForSummary:nil targetCount:targets.count],
            @"blockedText": blocked,
            @"executable": @NO,
            @"runID": NSNull.null,
            @"run": NSNull.null}];
    }
    return rows;
}

+ (NSArray<NSString *> *)filterIdentifiers {
    return @[SRGroupFilterAll, SRGroupFilterNotStarted, SRGroupFilterActive,
        SRGroupFilterCompleted, SRGroupFilterAbnormal];
}

+ (NSString *)titleForFilter:(NSString *)filter {
    NSDictionary *titles = @{SRGroupFilterAll: @"全部", SRGroupFilterNotStarted: @"未开始",
        SRGroupFilterActive: @"进行中", SRGroupFilterCompleted: @"已完成",
        SRGroupFilterAbnormal: @"有异常"};
    return titles[filter] ?: titles[SRGroupFilterAll];
}

+ (BOOL)phase:(NSString *)phase matchesFilter:(NSString *)filter {
    if ([filter isEqual:SRGroupFilterNotStarted]) return [phase isEqual:SRRunPhaseNotStarted];
    if ([filter isEqual:SRGroupFilterActive]) return [self phaseIsActive:phase];
    // A run with failures or unknown outcomes is never listed as completed.
    if ([filter isEqual:SRGroupFilterCompleted]) return [phase isEqual:SRRunPhaseCompleted];
    if ([filter isEqual:SRGroupFilterAbnormal])
        return [@[SRRunPhaseAbnormal, SRRunPhaseUnknown] containsObject:phase];
    return YES;
}

+ (NSArray<NSDictionary *> *)rows:(NSArray<NSDictionary *> *)rows
                     matchingText:(NSString *)text filter:(NSString *)filter {
    if (![rows isKindOfClass:NSArray.class]) return @[];
    NSString *query = [text isKindOfClass:NSString.class] ? [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    NSString *selected = [filter isKindOfClass:NSString.class] &&
        [[self filterIdentifiers] containsObject:filter] ? filter : SRGroupFilterAll;
    NSMutableArray *visible = [NSMutableArray array];
    for (id entry in rows) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = entry;
        if (![self phase:SRProjectionString(row[@"phase"], SRRunPhaseNotStarted) matchesFilter:selected]) continue;
        if (query.length) {
            NSMutableArray *fields = [NSMutableArray array];
            NSString *name = SRProjectionString(row[@"name"], nil);
            if (name) [fields addObject:name];
            for (NSString *key in @[@"targets", @"targetNames"])
                if ([row[key] isKindOfClass:NSArray.class]) [fields addObjectsFromArray:row[key]];
            BOOL matched = NO;
            for (NSString *field in fields) {
                if (![field isKindOfClass:NSString.class]) continue;
                if ([field rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
                    matched = YES; break;
                }
            }
            if (!matched) continue;
        }
        [visible addObject:row];
    }
    return visible;
}

+ (NSDictionary *)overviewForGroupRows:(NSArray<NSDictionary *> *)rows {
    NSUInteger groups = 0, targets = 0, started = 0, processed = 0, total = 0, abnormal = 0, limited = 0;
    if ([rows isKindOfClass:NSArray.class]) for (id entry in rows) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = entry;
        groups++;
        targets += [row[@"targetCount"] unsignedIntegerValue];
        if ([row[@"targetCount"] unsignedIntegerValue] > SRRunProjectionTargetLimit) limited++;
        NSDictionary *summary = [row[@"run"] isKindOfClass:NSDictionary.class] ? row[@"run"] : nil;
        if (summary) {
            started++;
            processed += [summary[@"processed"] unsignedIntegerValue];
            total += [summary[@"total"] unsignedIntegerValue];
        }
        NSString *phase = SRProjectionString(row[@"phase"], SRRunPhaseNotStarted);
        if ([@[SRRunPhaseAbnormal, SRRunPhaseUnknown] containsObject:phase]) abnormal++;
    }
    return @{@"groups": @(groups), @"targets": @(targets), @"started": @(started),
        @"unstarted": @(groups > started ? groups - started : 0), @"processed": @(processed),
        @"total": @(total), @"abnormal": @(abnormal), @"limited": @(limited)};
}

+ (NSDictionary *)latestRunInCards:(NSArray<NSDictionary *> *)cards {
    if (![cards isKindOfClass:NSArray.class]) return nil;
    NSDictionary *best = nil;
    NSNumber *bestOrder = nil;
    for (id entry in cards) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *run = [entry[@"latestRun"] isKindOfClass:NSDictionary.class] ? entry[@"latestRun"] : nil;
        if (!run) continue;
        NSString *state = SRProjectionString(run[@"state"], nil);
        if (![@[@"completed", @"ended"] containsObject:state]) continue;
        NSNumber *order = [run[@"creationOrder"] isKindOfClass:NSNumber.class] ? run[@"creationOrder"] : @0;
        if (!best || [order compare:bestOrder ?: @0] == NSOrderedDescending) { best = run; bestOrder = order; }
    }
    return best;
}

@end
