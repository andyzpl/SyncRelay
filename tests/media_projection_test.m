#import <Foundation/Foundation.h>
#import "Core/SRMediaProjection.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

/* Fixed synthetic fixtures: no device account, token, path or body. The
 * projection only formats dictionaries the media store already produced. */

static NSDictionary *usage(unsigned long long used, unsigned long long limit) {
    return @{@"usedBytes": @(used), @"limitBytes": @(limit),
        @"remainingBytes": @(limit - used), @"reclaimableBytes": @(1024ULL),
        @"reclaimableComplete": @YES, @"fileCount": @4, @"scanValid": @YES,
        @"level": used * 5 >= limit * 4 ? @"warning" : @"normal", @"warningRaised": @NO};
}

static void checkBytesText(void) {
    CHECK([[SRMediaProjection bytesText:@0] isEqual:@"0 B"]);
    CHECK([[SRMediaProjection bytesText:@1023] isEqual:@"1023 B"]);
    CHECK([[SRMediaProjection bytesText:@1024] isEqual:@"1.0 KB"]);
    CHECK([[SRMediaProjection bytesText:@(1536)] isEqual:@"1.5 KB"]);
    CHECK([[SRMediaProjection bytesText:@(1048576)] isEqual:@"1.0 MB"]);
    CHECK([[SRMediaProjection bytesText:@(268435456)] isEqual:@"256.0 MB"]);
    CHECK([[SRMediaProjection bytesText:@(1181116006)] isEqual:@"1.10 GB"]);
    // Missing or nonsense values are "unknown", never a fabricated zero.
    CHECK([[SRMediaProjection bytesText:nil] isEqual:@"未知"]);
    CHECK([[SRMediaProjection bytesText:@"2048"] isEqual:@"未知"]);
    CHECK([[SRMediaProjection bytesText:@(-1)] isEqual:@"未知"]);
    CHECK([[SRMediaProjection bytesText:NSNull.null] isEqual:@"未知"]);
}

static void checkLabels(void) {
    CHECK([[SRMediaProjection levelText:@"normal"] isEqual:@"正常"]);
    CHECK([[SRMediaProjection levelText:@"warning"] isEqual:@"接近上限"]);
    CHECK([[SRMediaProjection levelText:@"full"] isEqual:@"已满"]);
    CHECK([[SRMediaProjection levelText:nil] isEqual:@"未知"]);
    CHECK([[SRMediaProjection levelText:@"made-up"] isEqual:@"未知"]);

    CHECK([[SRMediaProjection resourceKindText:@"snapshot"] isEqual:@"快照"]);
    CHECK([[SRMediaProjection resourceKindText:@"derived"] isEqual:@"派生预览"]);
    CHECK([[SRMediaProjection resourceKindText:@"temporary"] isEqual:@"临时文件"]);
    CHECK([[SRMediaProjection resourceKindText:@"other"] isEqual:@"未知类型"]);

    CHECK([[SRMediaProjection libraryKindText:@"text"] isEqual:@"文字"]);
    CHECK([[SRMediaProjection libraryKindText:@"image"] isEqual:@"图片"]);
    // An unsupported kind is stated as such instead of degrading to text.
    CHECK([[SRMediaProjection libraryKindText:@"video"] containsString:@"未支持"]);
    CHECK([[SRMediaProjection libraryKindText:nil] isEqual:@"未知类型"]);
}

static void checkUsageSummary(void) {
    NSDictionary *summary = [SRMediaProjection usageSummary:usage(0, 268435456)];
    CHECK([summary[@"available"] isEqual:@YES]);
    CHECK([summary[@"problem"] isEqual:NSNull.null]);
    CHECK([summary[@"usedText"] isEqual:@"0 B"]);
    CHECK([summary[@"limitText"] isEqual:@"256.0 MB"]);
    CHECK([summary[@"percentText"] isEqual:@"0.0%"]);
    CHECK([summary[@"levelText"] isEqual:@"正常"]);
    CHECK([summary[@"fileCountText"] isEqual:@"4 个"]);
    CHECK([summary[@"complete"] isEqual:@YES]);
    CHECK([summary[@"note"] isEqual:NSNull.null]);

    // 79.6% must not be reported as 80%.
    NSDictionary *near = [SRMediaProjection usageSummary:usage(213866905, 268435456)];
    CHECK([near[@"percentText"] isEqual:@"79.7%"]);
    CHECK([near[@"levelText"] isEqual:@"正常"]);

    NSDictionary *warning = [SRMediaProjection usageSummary:@{
        @"usedBytes": @(250000000), @"limitBytes": @(268435456), @"remainingBytes": @(18435456),
        @"reclaimableBytes": @0, @"reclaimableComplete": @NO, @"fileCount": @9, @"scanValid": @YES,
        @"level": @"warning"}];
    CHECK([warning[@"levelText"] isEqual:@"接近上限"]);
    CHECK([warning[@"complete"] isEqual:@NO]);
    CHECK([warning[@"note"] isEqual:@"可回收容量不完整"]);

    NSDictionary *stale = [SRMediaProjection usageSummary:@{
        @"usedBytes": @(10), @"limitBytes": @(100), @"reclaimableComplete": @YES,
        @"fileCount": @1, @"scanValid": @NO, @"level": @"normal"}];
    CHECK([stale[@"note"] isEqual:@"上次扫描不完整，数字可能过期"]);

    // An unreadable usage is unavailable, not an empty budget, and a partial
    // reading publishes no number at all: a concrete "used" value next to an
    // unknown limit reads as a measurement the page cannot support.
    for (id broken in @[[NSNull null], @{}, @{@"usedBytes": @1},
                        @{@"usedBytes": @1, @"limitBytes": @0},
                        @{@"usedBytes": @1, @"limitBytes": NSNull.null},
                        @{@"limitBytes": @268435456}, @{@"usedBytes": @"1", @"limitBytes": @0}]) {
        NSDictionary *failed = [SRMediaProjection usageSummary:broken];
        CHECK([failed[@"available"] isEqual:@NO]);
        CHECK([failed[@"problem"] isEqual:@"用量不可读"]);
        CHECK([failed[@"usedText"] isEqual:@"未知"]);
        CHECK([failed[@"limitText"] isEqual:@"未知"]);
        CHECK([failed[@"remainingText"] isEqual:@"未知"]);
        CHECK([failed[@"percentText"] isEqual:@"未知"]);
        CHECK([failed[@"reclaimableText"] isEqual:@"未知"]);
        CHECK([failed[@"fileCountText"] isEqual:@"未知"]);
        CHECK([failed[@"note"] isEqual:NSNull.null]);
        CHECK([failed[@"complete"] isEqual:@NO]);
    }
    NSDictionary *nilUsage = [SRMediaProjection usageSummary:nil];
    CHECK([nilUsage[@"available"] isEqual:@NO]);
    CHECK([nilUsage[@"usedText"] isEqual:@"未知"]);

    // A readable limit with a zero used value is still a usable reading.
    NSDictionary *zeroUsed = [SRMediaProjection usageSummary:@{@"usedBytes": @0,
        @"limitBytes": @268435456, @"remainingBytes": @268435456, @"reclaimableBytes": @0,
        @"reclaimableComplete": @YES, @"fileCount": @0, @"scanValid": @YES, @"level": @"normal"}];
    CHECK([zeroUsed[@"available"] isEqual:@YES]);
    CHECK([zeroUsed[@"usedText"] isEqual:@"0 B"]);
    CHECK([zeroUsed[@"percentText"] isEqual:@"0.0%"]);
}

static void checkResourceSection(void) {
    NSDictionary *row = @{@"identifier": @"a1", @"kind": @"snapshot", @"bytes": @(2048),
        @"referenced": @YES, @"reclaimable": @NO, @"inUse": @NO};
    NSDictionary *listed = [SRMediaProjection resourceSectionForPayload:@{@"rows": @[row],
        @"referencesVerified": @YES, @"truncated": @NO, @"otherAccountCount": @2}];
    CHECK([listed[@"state"] isEqual:@"rows"]);
    CHECK([listed[@"verified"] isEqual:@YES] && [listed[@"truncated"] isEqual:@NO]);
    CHECK([listed[@"listedCount"] isEqual:@1]);
    CHECK([listed[@"otherAccountCount"] isEqual:@2]);
    CHECK([listed[@"notice"] isEqual:NSNull.null]);
    CHECK([listed[@"rows"][0][@"kindText"] isEqual:@"快照"]);
    CHECK([listed[@"rows"][0][@"bytesText"] isEqual:@"2.0 KB"]);

    // Unverified attribution withholds every row even though rows were returned.
    NSDictionary *unverified = [SRMediaProjection resourceSectionForPayload:@{@"rows": @[row, row],
        @"referencesVerified": @NO, @"truncated": @NO}];
    CHECK([unverified[@"state"] isEqual:@"unverified"]);
    CHECK([unverified[@"verified"] isEqual:@NO]);
    CHECK([unverified[@"rows"] count] == 0);
    CHECK([unverified[@"listedCount"] isEqual:@0]);
    CHECK([unverified[@"notice"] isEqual:@"资源归属未验证，暂不显示明细"]);

    // An empty page from a truncated read is incomplete, not "nothing stored".
    NSDictionary *truncatedEmpty = [SRMediaProjection resourceSectionForPayload:@{@"rows": @[],
        @"referencesVerified": @YES, @"truncated": @YES}];
    CHECK([truncatedEmpty[@"state"] isEqual:@"truncated_empty"]);
    CHECK([truncatedEmpty[@"truncated"] isEqual:@YES]);
    CHECK([truncatedEmpty[@"notice"] containsString:@"结果不完整"]);
    CHECK([truncatedEmpty[@"rows"] count] == 0);
    CHECK([truncatedEmpty[@"listedCount"] isEqual:@0]);

    // A complete empty read keeps the ordinary empty state with no complaint.
    NSDictionary *empty = [SRMediaProjection resourceSectionForPayload:@{@"rows": @[],
        @"referencesVerified": @YES, @"truncated": @NO}];
    CHECK([empty[@"state"] isEqual:@"empty"]);
    CHECK([empty[@"notice"] isEqual:NSNull.null]);
    CHECK([empty[@"rows"] count] == 0);
    CHECK([empty[@"listedCount"] isEqual:@0]);

    // A listed page that was truncated still lists what it has.
    NSDictionary *truncatedRows = [SRMediaProjection resourceSectionForPayload:@{@"rows": @[row],
        @"referencesVerified": @YES, @"truncated": @YES}];
    CHECK([truncatedRows[@"state"] isEqual:@"rows"]);
    CHECK([truncatedRows[@"truncated"] isEqual:@YES]);
    CHECK([truncatedRows[@"rows"] count] == 1);
    CHECK([truncatedRows[@"listedCount"] isEqual:@1]);

    // A missing payload is unavailable, never an empty library.
    for (id broken in @[[NSNull null], @"rows", @{@"referencesVerified": @"yes"}]) {
        NSDictionary *failed = [SRMediaProjection resourceSectionForPayload:broken];
        if ([broken isKindOfClass:NSDictionary.class]) {
            CHECK([failed[@"state"] isEqual:@"unverified"]);
        } else {
            CHECK([failed[@"state"] isEqual:@"unavailable"]);
            CHECK([failed[@"notice"] isEqual:@"资源列表不可用"]);
        }
        CHECK([failed[@"rows"] count] == 0);
    }

    // The published count is the published row list, in every state. A list the
    // page refuses to show must never report a non-zero count.
    NSArray *shapes = @[
        [NSNull null],
        @{},
        @{@"rows": @[row], @"referencesVerified": @YES},
        @{@"rows": @[row, row], @"referencesVerified": @YES},
        @{@"rows": @[row], @"referencesVerified": @NO},
        @{@"rows": @[], @"referencesVerified": @YES, @"truncated": @NO},
        @{@"rows": @[], @"referencesVerified": @YES, @"truncated": @YES},
        @{@"rows": @[row], @"referencesVerified": @YES, @"truncated": @YES}];
    for (id shape in shapes) {
        NSDictionary *sectionForShape = [SRMediaProjection resourceSectionForPayload:shape];
        NSArray *published = sectionForShape[@"rows"];
        NSNumber *listed = sectionForShape[@"listedCount"];
        CHECK([published isKindOfClass:NSArray.class]);
        CHECK([listed isKindOfClass:NSNumber.class]);
        CHECK(listed.unsignedIntegerValue == published.count);
        // Only the listed state may publish rows, and it must publish them all.
        if (![sectionForShape[@"state"] isEqual:@"rows"]) CHECK(published.count == 0);
    }
}

static void checkResourceRows(void) {
    NSDictionary *inUse = [SRMediaProjection resourceRow:@{@"identifier": @"a1b2c3",
        @"kind": @"snapshot", @"bytes": @(2048), @"referenced": @YES, @"reclaimable": @NO, @"inUse": @YES}];
    CHECK([inUse[@"identifier"] isEqual:@"a1b2c3"]);
    CHECK([inUse[@"kindText"] isEqual:@"快照"]);
    CHECK([inUse[@"bytesText"] isEqual:@"2.0 KB"]);
    CHECK([inUse[@"stateText"] isEqual:@"使用中"]);

    // State priority: in use, then reclaimable, then referenced.
    CHECK([[SRMediaProjection stateTextForRow:@{@"reclaimable": @YES, @"referenced": @YES}] isEqual:@"可回收"]);
    CHECK([[SRMediaProjection stateTextForRow:@{@"referenced": @YES}] isEqual:@"引用中"]);
    CHECK([[SRMediaProjection stateTextForRow:@{@"kind": @"temporary"}] isEqual:@"临时文件"]);
    CHECK([[SRMediaProjection stateTextForRow:@{}] isEqual:@"未引用"]);
    CHECK([[SRMediaProjection stateTextForRow:nil] isEqual:@"状态未知"]);

    // A row without an identifier is labelled, never shown as a path or blank.
    NSDictionary *anonymous = [SRMediaProjection resourceRow:@{@"kind": @"derived", @"bytes": @1}];
    CHECK([anonymous[@"identifier"] isEqual:@"未命名资源"]);
    CHECK([anonymous[@"stateText"] isEqual:@"未引用"]);
    CHECK([anonymous[@"inUse"] isEqual:@NO]);
    NSDictionary *nilRow = [SRMediaProjection resourceRow:nil];
    CHECK([nilRow[@"kindText"] isEqual:@"未知类型"]);
    CHECK([nilRow[@"bytesText"] isEqual:@"未知"]);
}

int main(void) {
    @autoreleasepool {
        checkBytesText();
        checkLabels();
        checkUsageSummary();
        checkResourceRows();
        checkResourceSection();
        puts("PASS: media projection formats bytes, levels, kinds and resource state without inventing "
             "an empty budget, publishing a partial usage or degrading an unknown kind to text");
    }
    return 0;
}
