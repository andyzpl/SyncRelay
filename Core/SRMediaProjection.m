#import "SRMediaProjection.h"
#include <math.h>

static BOOL SRMediaNumber(id value, double *result) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double number = [value doubleValue];
    if (!isfinite(number)) return NO;
    if (result) *result = number;
    return YES;
}

static NSString *SRMediaString(id value, NSString *fallback) {
    return [value isKindOfClass:NSString.class] && [(NSString *)value length] ? value : fallback;
}

@implementation SRMediaProjection

+ (NSString *)bytesText:(id)value {
    double number = 0;
    if (!SRMediaNumber(value, &number) || number < 0) return @"未知";
    unsigned long long bytes = (unsigned long long)number;
    if (bytes < 1024ULL) return [NSString stringWithFormat:@"%llu B", bytes];
    double kib = (double)bytes / 1024.0;
    if (kib < 1024.0) return [NSString stringWithFormat:@"%.1f KB", kib];
    double mib = kib / 1024.0;
    if (mib < 1024.0) return [NSString stringWithFormat:@"%.1f MB", mib];
    return [NSString stringWithFormat:@"%.2f GB", mib / 1024.0];
}

+ (NSString *)levelText:(NSString *)level {
    if ([level isEqual:@"warning"]) return @"接近上限";
    if ([level isEqual:@"full"]) return @"已满";
    if ([level isEqual:@"normal"]) return @"正常";
    return @"未知";
}

+ (NSString *)resourceKindText:(NSString *)kind {
    if ([kind isEqual:@"snapshot"]) return @"快照";
    if ([kind isEqual:@"derived"]) return @"派生预览";
    if ([kind isEqual:@"temporary"]) return @"临时文件";
    return @"未知类型";
}

+ (NSString *)libraryKindText:(NSString *)kind {
    if ([kind isEqual:@"text"]) return @"文字";
    if ([kind isEqual:@"image"]) return @"图片";
    // An unknown kind is stated as unknown instead of degrading to text.
    return SRMediaString(kind, nil) ? [NSString stringWithFormat:@"未支持（%@）", kind] : @"未知类型";
}

+ (NSString *)stateTextForRow:(NSDictionary *)row {
    if (![row isKindOfClass:NSDictionary.class]) return @"状态未知";
    if ([row[@"inUse"] isEqual:@YES]) return @"使用中";
    if ([row[@"reclaimable"] isEqual:@YES]) return @"可回收";
    if ([row[@"referenced"] isEqual:@YES]) return @"引用中";
    if ([row[@"kind"] isEqual:@"temporary"]) return @"临时文件";
    return @"未引用";
}

+ (NSDictionary *)usageSummary:(NSDictionary *)usage {
    NSMutableDictionary *summary = [@{@"available": @NO, @"problem": @"用量不可读",
        @"usedText": @"未知", @"limitText": @"未知", @"remainingText": @"未知",
        @"reclaimableText": @"未知", @"percentText": @"未知", @"level": @"unknown",
        @"levelText": [self levelText:nil], @"fileCountText": @"未知",
        @"complete": @NO, @"warningRaised": @NO, @"scanValid": @NO,
        @"note": NSNull.null} mutableCopy];
    if (![usage isKindOfClass:NSDictionary.class]) return summary;

    double used = 0, limit = 0;
    BOOL hasUsed = SRMediaNumber(usage[@"usedBytes"], &used);
    BOOL hasLimit = SRMediaNumber(usage[@"limitBytes"], &limit);
    // A partial reading is not a usable reading: without a limit there is no
    // ratio to show, and a concrete "used" value next to an unknown limit reads
    // as a measurement the page cannot actually support.
    BOOL usable = hasUsed && hasLimit && limit > 0;
    NSString *level = SRMediaString(usage[@"level"], nil);
    summary[@"level"] = level ?: @"unknown";
    summary[@"levelText"] = [self levelText:level];
    summary[@"available"] = @(usable);
    summary[@"problem"] = usable ? (id)NSNull.null : @"用量不可读";
    // Nothing numeric is published unless the whole comparison is readable.
    if (usable) {
        summary[@"usedText"] = [self bytesText:usage[@"usedBytes"]];
        summary[@"limitText"] = [self bytesText:usage[@"limitBytes"]];
        double ratio = used / limit * 100.0;
        summary[@"percentText"] = [NSString stringWithFormat:@"%.1f%%", ratio];
        if ([usage[@"remainingBytes"] isKindOfClass:NSNumber.class])
            summary[@"remainingText"] = [self bytesText:usage[@"remainingBytes"]];
    }
    if (usable && [usage[@"reclaimableBytes"] isKindOfClass:NSNumber.class])
        summary[@"reclaimableText"] = [self bytesText:usage[@"reclaimableBytes"]];
    if (usable && [usage[@"fileCount"] isKindOfClass:NSNumber.class])
        summary[@"fileCountText"] = [NSString stringWithFormat:@"%@ 个",
            [usage[@"fileCount"] stringValue]];
    summary[@"complete"] = [usage[@"reclaimableComplete"] isEqual:@YES] ? @YES : @NO;
    summary[@"warningRaised"] = [usage[@"warningRaised"] isEqual:@YES] ? @YES : @NO;
    summary[@"scanValid"] = [usage[@"scanValid"] isEqual:@YES] ? @YES : @NO;
    // A scan that did not complete must not read as an exact figure.
    if (usable && ![summary[@"scanValid"] isEqual:@YES])
        summary[@"note"] = @"上次扫描不完整，数字可能过期";
    else if (usable && ![summary[@"complete"] isEqual:@YES])
        summary[@"note"] = @"可回收容量不完整";
    return [summary copy];
}

+ (NSDictionary *)resourceRow:(NSDictionary *)row {
    NSDictionary *source = [row isKindOfClass:NSDictionary.class] ? row : @{};
    return @{
        @"identifier": SRMediaString(source[@"identifier"], @"未命名资源"),
        @"kindText": [self resourceKindText:SRMediaString(source[@"kind"], nil)],
        @"bytesText": [self bytesText:source[@"bytes"]],
        @"stateText": [self stateTextForRow:source],
        @"referenced": [source[@"referenced"] isEqual:@YES] ? @YES : @NO,
        @"reclaimable": [source[@"reclaimable"] isEqual:@YES] ? @YES : @NO,
        @"inUse": [source[@"inUse"] isEqual:@YES] ? @YES : @NO};
}

+ (NSDictionary *)resourceSectionForPayload:(NSDictionary *)payload {
    NSMutableDictionary *section = [@{@"state": @"unavailable",
        @"notice": @"资源列表不可用", @"rows": @[], @"listedCount": @0,
        @"otherAccountCount": @0, @"truncated": @NO, @"verified": @NO} mutableCopy];
    if (![payload isKindOfClass:NSDictionary.class]) return [section copy];

    BOOL verified = [payload[@"referencesVerified"] isEqual:@YES];
    BOOL truncated = [payload[@"truncated"] isEqual:@YES];
    NSArray *raw = [payload[@"rows"] isKindOfClass:NSArray.class] ? payload[@"rows"] : @[];
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:raw.count];
    for (id entry in raw) if ([entry isKindOfClass:NSDictionary.class])
        [rows addObject:[self resourceRow:entry]];

    section[@"verified"] = @(verified);
    section[@"truncated"] = @(truncated);
    section[@"otherAccountCount"] = [payload[@"otherAccountCount"] isKindOfClass:NSNumber.class] ?
        payload[@"otherAccountCount"] : @0;
    // The published row list and its count are one value: every state below
    // either keeps both or empties both, so a caller can never read a count for
    // rows the page refused to show.
    NSArray *published = @[];
    // An unverified reference set cannot say which file belongs to this account,
    // so the detail list is withheld even when rows were returned.
    if (!verified) {
        section[@"state"] = @"unverified";
        section[@"notice"] = @"资源归属未验证，暂不显示明细";
    } else if (!rows.count) {
        // An empty page from a truncated read is not proof of an empty library.
        section[@"state"] = truncated ? @"truncated_empty" : @"empty";
        section[@"notice"] = truncated ? @"结果不完整：本次没有取到资源行，不能据此判断没有素材" : (id)NSNull.null;
    } else {
        section[@"state"] = @"rows";
        section[@"notice"] = NSNull.null;
        published = [rows copy];
    }
    section[@"rows"] = published;
    section[@"listedCount"] = @(published.count);
    return [section copy];
}

@end
