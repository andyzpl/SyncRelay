#import "SRGroupPlanner.h"
#import "SRConfiguration.h"
#import "SRSelection.h"
#import "SRSourceMessage.h"
#include <string.h>

static BOOL SRWholeCount(id value, NSUInteger *result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        !strchr("cCsSiIlLqQ", [value objCType][0]) || [value compare:@0] == NSOrderedAscending ||
        [value unsignedLongLongValue] > NSUIntegerMax) return NO;
    *result = [value unsignedIntegerValue];
    return YES;
}

static BOOL SRGroupRow(id row) {
    if (![row isKindOfClass:NSDictionary.class]) return NO;
    NSString *identifier = row[@"id"], *name = row[@"name"];
    return [identifier isKindOfClass:NSString.class] && [identifier hasSuffix:@"@chatroom"] &&
        [identifier rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound &&
        [name isKindOfClass:NSString.class] && name.length;
}

static void SRGroupingError(NSError **error, id reason) {
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.GroupPlanner" code:1 userInfo:@{
        NSLocalizedDescriptionKey: [reason isKindOfClass:NSString.class] ? reason : @"Invalid grouping data; previous rules are unchanged"}];
}

@implementation SRGroupPlanner
+ (NSDictionary *)previewWithRows:(NSArray<NSDictionary *> *)rows draft:(NSDictionary *)draft
                          recipe:(NSArray<NSDictionary *> *)recipe error:(NSError **)error {
    @try {
        NSDictionary *snapshot = [SRSourceMessage frozenJSON:draft];
        if (![SRConfiguration validateDraft:snapshot error:NULL] || ![snapshot[@"sourceGroup"] count])
            @throw @"Select a valid source group before generating rules";
        if (![rows isKindOfClass:NSArray.class] || ![recipe isKindOfClass:NSArray.class] || !recipe.count)
            @throw @"A group list and a non-empty batch recipe are required";
        NSUInteger requested = 0, requestedRules = 0;
        for (id entry in recipe) {
            NSUInteger size = 0, count = 0;
            if (![entry isKindOfClass:NSDictionary.class] || !SRWholeCount(entry[@"size"], &size) ||
                (size != 100 && size != 200) || !SRWholeCount(entry[@"count"], &count))
                @throw @"Batch sizes must be 100 or 200; counts must be non-negative whole numbers";
            if (count > (NSUIntegerMax - requested) / size) @throw @"The requested total is too large";
            requested += size * count; requestedRules += count;
        }
        if (!requested) @throw @"Request at least one rule";
        for (id row in rows) if (!SRGroupRow(row)) @throw @"The group list contains an invalid stable group ID or name";
        NSMutableSet *excluded = [NSMutableSet setWithObject:snapshot[@"sourceGroup"][@"id"]];
        for (NSDictionary *row in snapshot[@"excludedGroups"]) [excluded addObject:row[@"id"]];
        for (NSDictionary *rule in snapshot[@"rules"]) [excluded addObjectsFromArray:[rule[@"targets"] valueForKey:@"id"]];
        SRSelection *selection = [[SRSelection alloc] initWithRows:rows excludedIDs:excluded selectedIDs:NSSet.set];
        NSArray *eligible = selection.rows;
        NSMutableArray *rules = [snapshot[@"rules"] mutableCopy], *batches = [NSMutableArray array];
        NSMutableSet *names = [NSMutableSet setWithArray:[rules valueForKey:@"name"]];
        NSUInteger cursor = 0, generated = 0, partial = 0, nextNumber = rules.count + 1;
        for (NSDictionary *entry in recipe) {
            NSUInteger size = [entry[@"size"] unsignedIntegerValue], count = [entry[@"count"] unsignedIntegerValue];
            NSUInteger batchStart = cursor, batchRules = 0;
            // Stop at available rows even when the requested rule count is very large.
            for (NSUInteger i = 0; i < count && cursor < eligible.count; i++) {
                NSUInteger length = MIN(size, eligible.count - cursor);
                NSString *name;
                do { name = [NSString stringWithFormat:@"Rule %lu", (unsigned long)nextNumber++]; }
                while ([names containsObject:name]);
                [names addObject:name];
                [rules addObject:@{@"id": NSUUID.UUID.UUIDString, @"name": name,
                    @"targets": [eligible subarrayWithRange:NSMakeRange(cursor, length)]}];
                cursor += length; generated++; batchRules++;
                if (length < size) partial++;
            }
            [batches addObject:@{@"size": @(size), @"count": @(count), @"generatedCount": @(batchRules),
                @"assignedCount": @(cursor - batchStart), @"shortfallCount": @(size * count - (cursor - batchStart))}];
        }
        NSMutableDictionary *candidate = [snapshot mutableCopy]; candidate[@"rules"] = rules;
        if (![SRConfiguration validateDraft:candidate error:NULL]) @throw @"Generated configuration is invalid; previous rules are unchanged";
        return [SRSourceMessage frozenJSON:@{@"configuration": candidate, @"batches": batches,
            @"requestedCount": @(requested), @"requestedRuleCount": @(requestedRules),
            @"availableCount": @(eligible.count), @"assignedCount": @(cursor),
            @"generatedRuleCount": @(generated), @"partialRuleCount": @(partial),
            @"shortfallCount": @(requested - cursor), @"remainingCount": @(eligible.count - cursor)}];
    } @catch (id reason) { SRGroupingError(error, reason); return nil; }
}

+ (NSDictionary *)configurationBySettingExcludedGroups:(NSArray<NSDictionary *> *)groups
                                               inDraft:(NSDictionary *)draft error:(NSError **)error {
    @try {
        NSDictionary *snapshot = [SRSourceMessage frozenJSON:draft];
        if (![SRConfiguration validateDraft:snapshot error:NULL] || ![groups isKindOfClass:NSArray.class])
            @throw @"Invalid draft or exclusion list; previous rules are unchanged";
        NSMutableSet *excluded = [NSMutableSet set];
        for (id row in groups) {
            if (!SRGroupRow(row) || [excluded containsObject:row[@"id"]]) @throw @"Exclusions must have unique stable group IDs";
            [excluded addObject:row[@"id"]];
        }
        NSMutableArray *rules = [NSMutableArray array];
        for (NSDictionary *rule in snapshot[@"rules"]) {
            NSMutableArray *targets = [NSMutableArray array];
            for (NSDictionary *target in rule[@"targets"]) if (![excluded containsObject:target[@"id"]]) [targets addObject:target];
            if (!targets.count) continue;
            NSMutableDictionary *updated = [rule mutableCopy]; updated[@"targets"] = targets; [rules addObject:updated];
        }
        NSMutableDictionary *candidate = [snapshot mutableCopy]; candidate[@"excludedGroups"] = groups; candidate[@"rules"] = rules;
        if (![SRConfiguration validateDraft:candidate error:NULL]) @throw @"Invalid exclusions; previous rules are unchanged";
        return [SRSourceMessage frozenJSON:candidate];
    } @catch (id reason) { SRGroupingError(error, reason); return nil; }
}
@end
