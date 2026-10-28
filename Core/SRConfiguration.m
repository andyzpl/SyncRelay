#import "SRConfiguration.h"
#import "SRPacing.h"
#import <CoreFoundation/CoreFoundation.h>

@implementation SRConfiguration
+ (NSMutableDictionary *)emptyDraft {
    return [@{@"schema": @1, @"sourceGroup": @{}, @"senders": @[], @"types": @[@"text", @"image"],
              @"minimum": @(SR_PACING_DEFAULT_MINIMUM_SECONDS), @"maximum": @(SR_PACING_DEFAULT_MAXIMUM_SECONDS),
              @"rules": @[], @"excludedGroups": @[]} mutableCopy];
}
+ (NSArray<NSString *> *)operationsRequirementsForDraft:(NSDictionary *)draft {
    if (![draft isKindOfClass:NSDictionary.class] || ![draft[@"schema"] isEqual:@1]) return @[@"configuration_invalid"];
    NSMutableArray *missing = [NSMutableArray array];
    if (![self row:draft[@"sourceGroup"] group:YES]) [missing addObject:@"source_group"];
    NSArray *senders = draft[@"senders"], *types = draft[@"types"], *rules = draft[@"rules"];
    BOOL membersValid = [senders isKindOfClass:NSArray.class] && senders.count > 0;
    if (membersValid) for (id row in senders) if (![self row:row group:NO]) membersValid = NO;
    if (!membersValid) [missing addObject:@"source_members"];
    BOOL typesValid = [types isKindOfClass:NSArray.class] && types.count > 0 && types.count <= 2;
    if (typesValid) for (id type in types) if (![@[@"text", @"image"] containsObject:type]) typesValid = NO;
    if (!typesValid) [missing addObject:@"message_types"];
    SRPacing pacing = {0};
    if (![draft[@"minimum"] isKindOfClass:NSNumber.class] || ![draft[@"maximum"] isKindOfClass:NSNumber.class] ||
        !SRPacingConfigure(&pacing, [draft[@"minimum"] doubleValue], [draft[@"maximum"] doubleValue]))
        [missing addObject:@"send_interval"];
    if (![rules isKindOfClass:NSArray.class] || !rules.count) [missing addObject:@"target_groups"];
    if (!missing.count && ![self validateDraft:draft error:NULL]) [missing addObject:@"configuration_invalid"];
    return missing;
}
+ (BOOL)row:(id)row group:(BOOL)group {
    if (![row isKindOfClass:NSDictionary.class]) return NO;
    NSString *identifier = row[@"id"];
    NSString *name = row[@"name"];
    if (![identifier isKindOfClass:NSString.class] || !identifier.length ||
        ![name isKindOfClass:NSString.class] || !name.length) return NO;
    if ([identifier rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return NO;
    return group ? [identifier hasSuffix:@"@chatroom"] : ![identifier hasSuffix:@"@chatroom"];
}
+ (BOOL)validateDraft:(NSDictionary *)draft error:(NSError **)error {
    BOOL valid = NO;
    @try {
        if (![draft isKindOfClass:NSDictionary.class] || ![draft[@"schema"] isEqual:@1]) @throw @"schema";
        SRPacing pacing = {0};
        if (![draft[@"minimum"] isKindOfClass:NSNumber.class] || ![draft[@"maximum"] isKindOfClass:NSNumber.class] ||
            !SRPacingConfigure(&pacing, [draft[@"minimum"] doubleValue], [draft[@"maximum"] doubleValue])) @throw @"interval";
        NSArray *types = draft[@"types"], *senders = draft[@"senders"], *rules = draft[@"rules"];
        NSDictionary *source = draft[@"sourceGroup"];
        if (![types isKindOfClass:NSArray.class] || !types.count || types.count > 2 ||
            [NSSet setWithArray:types].count != types.count || ![senders isKindOfClass:NSArray.class] ||
            ![rules isKindOfClass:NSArray.class] || ![source isKindOfClass:NSDictionary.class]) @throw @"shape";
        for (id type in types) if (![@[@"text", @"image"] containsObject:type]) @throw @"type";
        if (source.count && ![self row:source group:YES]) @throw @"source";
        if (!source.count && (senders.count || rules.count)) @throw @"source required";
        NSMutableSet *senderIDs = [NSMutableSet set];
        for (id row in senders) {
            if (![self row:row group:NO] || [senderIDs containsObject:row[@"id"]]) @throw @"sender";
            [senderIDs addObject:row[@"id"]];
        }
        // Missing exclusions remain valid for drafts saved by earlier versions.
        NSArray *excluded = draft[@"excludedGroups"] ?: @[];
        if (![excluded isKindOfClass:NSArray.class]) @throw @"exclusions";
        NSMutableSet *excludedIDs = [NSMutableSet set];
        for (id row in excluded) {
            if (![self row:row group:YES] || [excludedIDs containsObject:row[@"id"]]) @throw @"excluded group";
            [excludedIDs addObject:row[@"id"]];
        }
        NSMutableSet *targets = [NSMutableSet set], *ruleIDs = [NSMutableSet set];
        for (id rule in rules) {
            if (![rule isKindOfClass:NSDictionary.class] || ![rule[@"id"] isKindOfClass:NSString.class] ||
                ![rule[@"id"] length] || [ruleIDs containsObject:rule[@"id"]] ||
                ![rule[@"name"] isKindOfClass:NSString.class] || ![rule[@"name"] length] ||
                ![rule[@"targets"] isKindOfClass:NSArray.class] || ![rule[@"targets"] count]) @throw @"rule";
            // Optional grouping provenance. Absent means a rule saved before this
            // field existed; the planner treats such a rule as automatic. A
            // custom rule never takes part in a top-up, so it may not claim a
            // capacity. The capacity is the grouping spec (100/200) only.
            id origin = rule[@"origin"], capacity = rule[@"capacity"];
            if (origin && (![origin isKindOfClass:NSString.class] ||
                ![@[@"auto", @"custom"] containsObject:origin])) @throw @"rule origin";
            if (capacity) {
                if (![capacity isKindOfClass:NSNumber.class] ||
                    CFGetTypeID((__bridge CFTypeRef)capacity) == CFBooleanGetTypeID() ||
                    ![@[@100, @200] containsObject:capacity]) @throw @"rule capacity";
                if ([origin isEqual:@"custom"]) @throw @"custom rule with capacity";
            }
            [ruleIDs addObject:rule[@"id"]];
            for (id row in rule[@"targets"]) {
                if (![self row:row group:YES] || [row[@"id"] isEqual:source[@"id"]] ||
                    [targets containsObject:row[@"id"]] || [excludedIDs containsObject:row[@"id"]]) @throw @"target conflict";
                [targets addObject:row[@"id"]];
            }
        }
        valid = [NSJSONSerialization isValidJSONObject:draft];
    } @catch (__unused id exception) { valid = NO; }
    if (!valid && error) *error = [NSError errorWithDomain:@"SyncRelay.Configuration" code:1 userInfo:@{
        NSLocalizedDescriptionKey: @"配置无效：检查母群、wxid、类型、间隔及重复目标群；旧配置未被覆盖"}];
    return valid;
}
@end
