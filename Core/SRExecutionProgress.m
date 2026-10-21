#import "SRExecutionProgress.h"
#include <math.h>
@implementation SRExecutionProgress
+ (NSDictionary *)modelForStatus:(NSDictionary *)status {
    NSDictionary *hidden = @{@"visible": @NO};
    if (![status isKindOfClass:NSDictionary.class] || ![status[@"busy"] isEqual:@YES] ||
        ![status[@"counts"] isKindOfClass:NSDictionary.class]) return hidden;
    NSDictionary *counts = status[@"counts"];
    NSUInteger total = 0, processed = 0, inflight = 0;
    for (NSString *key in @[@"pending", @"submitting", @"submitted", @"confirmed", @"failed", @"uncertain", @"cancelled"]) {
        NSNumber *number = counts[key] ?: @0;
        if (![number isKindOfClass:NSNumber.class] || !isfinite(number.doubleValue) || number.doubleValue < 0 ||
            floor(number.doubleValue) != number.doubleValue || number.unsignedLongLongValue > NSUIntegerMax - total) return hidden;
        NSUInteger count = number.unsignedIntegerValue; total += count;
        if ([key isEqual:@"submitting"]) inflight = count;
        else if (![key isEqual:@"pending"]) processed += count;
    }
    if (!total || ![@[@"running", @"paused", @"awaiting_resume"] containsObject:status[@"state"]]) return hidden;
    BOOL running = [status[@"state"] isEqual:@"running"] && [status[@"dispatchEnabled"] isEqual:@YES];
    BOOL settling = !running && inflight > 0;
    return @{@"visible": @YES, @"processed": @(processed), @"total": @(total),
        @"phase": running ? @"running" : (settling ? @"settling" : @"paused"),
        @"action": running ? @"pause" : @"resume", @"actionEnabled": @(!settling)};
}
@end
