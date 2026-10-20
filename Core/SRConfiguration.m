#import "SRConfiguration.h"
#import "SRPacing.h"

@implementation SRConfiguration
+ (NSMutableDictionary *)emptyDraft {
    return [@{@"schema": @1, @"sourceGroup": @{}, @"senders": @[], @"types": @[@"text", @"image"],
              @"minimum": @10, @"maximum": @20, @"rules": @[], @"excludedGroups": @[]} mutableCopy];
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
