#import "SRSourceMessage.h"
#import "SRConfiguration.h"
#import "SRImageAssetStore.h"
@implementation SRSourceMessage
+ (NSDictionary *)frozenJSON:(id)object {
    @try {
        if (![object isKindOfClass:NSDictionary.class] || ![NSJSONSerialization isValidJSONObject:object]) return nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
        return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    } @catch (__unused NSException *exception) { return nil; }
}
+ (BOOL)matchesEnvelope:(NSDictionary *)message configuration:(NSDictionary *)configuration account:(NSString *)account {
    @try {
        if (![SRConfiguration validateDraft:configuration error:NULL] || ![message isKindOfClass:NSDictionary.class] || !account.length) return NO;
        for (NSString *key in @[@"account", @"group", @"sender", @"messageID", @"type"]) {
            if (![message[key] isKindOfClass:NSString.class] || ![message[key] length]) return NO;
        }
        // Require explicit provenance. Absence is not equivalent to "not generated".
        if (![message[@"generatedByRelay"] isEqual:@NO] || ![message[@"account"] isEqual:account] ||
            ![message[@"group"] isEqual:configuration[@"sourceGroup"][@"id"]] ||
            ![configuration[@"types"] containsObject:message[@"type"]]) return NO;
        BOOL allowedSender = NO;
        for (NSDictionary *sender in configuration[@"senders"]) if ([sender[@"id"] isEqual:message[@"sender"]]) allowedSender = YES;
        if (!allowedSender) return NO;
        NSDictionary *payload = message[@"payload"];
        if (![payload isKindOfClass:NSDictionary.class]) return NO;
        BOOL valid = [message[@"type"] isEqual:@"text"] ?
            ([payload[@"text"] isKindOfClass:NSString.class] && [payload[@"text"] length]) :
            ([message[@"type"] isEqual:@"image"] && [SRImageAssetStore validPayload:payload]);
        return valid && [NSJSONSerialization isValidJSONObject:message];
    } @catch (__unused NSException *exception) { return NO; }
}
@end
