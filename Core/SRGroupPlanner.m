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
+ (NSDictionary *)configurationBySettingSourceGroup:(NSDictionary *)group inDraft:(NSDictionary *)draft error:(NSError **)error {
    @try {
        NSDictionary *snapshot = [SRSourceMessage frozenJSON:draft];
        if (![SRConfiguration validateDraft:snapshot error:NULL] || !SRGroupRow(group)) @throw @"Invalid source group or draft";
        if ([snapshot[@"sourceGroup"][@"id"] isEqual:group[@"id"]]) return snapshot;
        NSMutableDictionary *candidate = [snapshot mutableCopy];
        candidate[@"sourceGroup"] = group; candidate[@"senders"] = @[];
        NSMutableArray *rules = [NSMutableArray array];
        for (NSDictionary *rule in snapshot[@"rules"]) {
            NSMutableArray *targets = [NSMutableArray array];
            for (NSDictionary *target in rule[@"targets"]) if (![target[@"id"] isEqual:group[@"id"]]) [targets addObject:target];
            if (!targets.count) continue;
            NSMutableDictionary *updated = [rule mutableCopy]; updated[@"targets"] = targets; [rules addObject:updated];
        }
        candidate[@"rules"] = rules;
        if (![SRConfiguration validateDraft:candidate error:NULL]) @throw @"Source change would create an invalid draft";
        return [SRSourceMessage frozenJSON:candidate];
    } @catch (id reason) { SRGroupingError(error, reason); return nil; }
}
+ (NSUInteger)capacityForRule:(NSDictionary *)rule {
    id capacity = [rule isKindOfClass:NSDictionary.class] ? rule[@"capacity"] : nil;
    if ([capacity isKindOfClass:NSNumber.class] && ([capacity isEqual:@100] || [capacity isEqual:@200]))
        return [capacity unsignedIntegerValue];
    // A rule saved before the field existed came from the same 100/200 batches,
    // so more than 100 targets can only be the residue of a 200 batch.
    NSUInteger count = [rule[@"targets"] isKindOfClass:NSArray.class] ? [rule[@"targets"] count] : 0;
    return count > 100 ? 200 : 100;
}

+ (NSDictionary *)previewWithRows:(NSArray<NSDictionary *> *)rows draft:(NSDictionary *)draft
                          recipe:(NSArray<NSDictionary *> *)recipe error:(NSError **)error {
    // No executable-range clamp: pure grouping. The app passes its real limit.
    return [self previewWithRows:rows draft:draft recipe:recipe intent:SRGroupingIntentAutomatic
        executionLimit:0 error:error];
}

+ (NSDictionary *)previewWithRows:(NSArray<NSDictionary *> *)rows draft:(NSDictionary *)draft
                          recipe:(NSArray<NSDictionary *> *)recipe
                  executionLimit:(NSUInteger)executionLimit error:(NSError **)error {
    return [self previewWithRows:rows draft:draft recipe:recipe intent:SRGroupingIntentAutomatic
        executionLimit:executionLimit error:error];
}

+ (NSDictionary *)previewWithRows:(NSArray<NSDictionary *> *)rows draft:(NSDictionary *)draft
                          recipe:(NSArray<NSDictionary *> *)recipe
                          intent:(SRGroupingIntent)intent
                  executionLimit:(NSUInteger)executionLimit error:(NSError **)error {
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
        // A zero-count recipe is allowed: it means "top up only, create nothing".
        // Whether there is any work at all is decided after the top-up pass.
        for (id row in rows) if (!SRGroupRow(row)) @throw @"The group list contains an invalid stable group ID or name";
        NSMutableSet *excluded = [NSMutableSet setWithObject:snapshot[@"sourceGroup"][@"id"]];
        for (NSDictionary *row in snapshot[@"excludedGroups"]) [excluded addObject:row[@"id"]];
        for (NSDictionary *rule in snapshot[@"rules"]) [excluded addObjectsFromArray:[rule[@"targets"] valueForKey:@"id"]];
        SRSelection *selection = [[SRSelection alloc] initWithRows:rows excludedIDs:excluded selectedIDs:NSSet.set];
        NSArray *eligible = selection.rows;
        NSMutableArray *rules = [NSMutableArray array], *topUps = [NSMutableArray array], *batches = [NSMutableArray array];
        NSMutableSet *names = [NSMutableSet setWithArray:[snapshot[@"rules"] valueForKey:@"name"]];
        NSUInteger cursor = 0;
        // Top up automatic rules first, in allocation order. A custom rule is a
        // deliberate composition and is never filled; a rule already at or above
        // its target is left untouched. The fill target is the rule's own spec,
        // clamped by the caller's executable range, so nothing here assumes a
        // particular limit value. A hand-picked request never tops anything up:
        // the rows the user selected are reserved for the rules it creates.
        BOOL topUp = (intent == SRGroupingIntentAutomatic);
        for (NSDictionary *rule in snapshot[@"rules"]) {
            NSMutableDictionary *updated = [rule mutableCopy];
            if (topUp && ![rule[@"origin"] isEqual:@"custom"]) {
                NSUInteger capacity = [self capacityForRule:rule];
                NSUInteger target = executionLimit ? MIN(capacity, executionLimit) : capacity;
                NSUInteger current = [rule[@"targets"] count];
                if (current < target && cursor < eligible.count) {
                    NSUInteger added = MIN(target - current, eligible.count - cursor);
                    NSMutableArray *targets = [rule[@"targets"] mutableCopy];
                    [targets addObjectsFromArray:[eligible subarrayWithRange:NSMakeRange(cursor, added)]];
                    updated[@"targets"] = targets;
                    [topUps addObject:@{@"ruleID": rule[@"id"], @"name": rule[@"name"], @"added": @(added),
                        @"before": @(current), @"after": @(current + added),
                        @"capacity": @(capacity), @"target": @(target)}];
                    cursor += added;
                }
                updated[@"origin"] = @"auto"; updated[@"capacity"] = @(capacity);
            }
            [rules addObject:updated];
        }
        NSUInteger generatedFrom = cursor, generated = 0, partial = 0, nextNumber = rules.count + 1;
        for (NSDictionary *entry in recipe) {
            NSUInteger size = [entry[@"size"] unsignedIntegerValue], count = [entry[@"count"] unsignedIntegerValue];
            BOOL custom = (intent == SRGroupingIntentCustom);
            NSUInteger batchStart = cursor, batchRules = 0;
            // Stop at available rows even when the requested rule count is very large.
            for (NSUInteger i = 0; i < count && cursor < eligible.count; i++) {
                NSUInteger length = MIN(size, eligible.count - cursor);
                NSString *name;
                do { name = [NSString stringWithFormat:@"Rule %lu", (unsigned long)nextNumber++]; }
                while ([names containsObject:name]);
                [names addObject:name];
                NSMutableDictionary *created = [@{@"id": NSUUID.UUID.UUIDString, @"name": name,
                    @"targets": [eligible subarrayWithRange:NSMakeRange(cursor, length)],
                    @"origin": custom ? @"custom" : @"auto"} mutableCopy];
                // A custom rule carries no capacity: it is never topped up.
                if (!custom) created[@"capacity"] = @(size);
                [rules addObject:created];
                cursor += length; generated++; batchRules++;
                if (length < size) partial++;
            }
            [batches addObject:@{@"size": @(size), @"count": @(count), @"generatedCount": @(batchRules),
                @"assignedCount": @(cursor - batchStart), @"shortfallCount": @(size * count - (cursor - batchStart))}];
        }
        NSMutableDictionary *candidate = [snapshot mutableCopy]; candidate[@"rules"] = rules;
        if (![SRConfiguration validateDraft:candidate error:NULL]) @throw @"Generated configuration is invalid; previous rules are unchanged";
        // Two different "nothing happened" cases. An explicit request that finds
        // no available row is a legitimate zero result: the caller shows "no
        // change" and keeps the draft. A pure top-up with nothing to fill asked
        // for work that cannot be done, so it is refused.
        if (!generated && !topUps.count && !requested)
            @throw @"Nothing to assign: no automatic rule is below its target";
        return [SRSourceMessage frozenJSON:@{@"configuration": candidate, @"batches": batches,
            @"topUpRules": topUps, @"topUpCount": @(generatedFrom), @"topUpRuleCount": @(topUps.count),
            @"requestedCount": @(requested), @"requestedRuleCount": @(requestedRules),
            @"availableCount": @(eligible.count), @"assignedCount": @(cursor - generatedFrom),
            @"generatedRuleCount": @(generated), @"partialRuleCount": @(partial),
            @"shortfallCount": @(requested - (cursor - generatedFrom)), @"remainingCount": @(eligible.count - cursor)}];
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
