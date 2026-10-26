#import "SRSourceMessage.h"
#import "SRConfiguration.h"
#import "SRImageAssetStore.h"
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>
/* A wall-clock value must be a finite, positive, integer-precision number. A
 * boolean is an NSNumber but never a time: accepting it would silently turn
 * @YES into 1970-01-01. NSNull, strings and NaN/Infinity stay unknown. */
static NSNumber *_Nullable SRTimeNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    double number = [value doubleValue];
    if (!isfinite(number) || number <= 0 || number > 9007199254740991.0) return nil;
    return value;
}
static NSNumber *_Nullable SRIntegerTime(id value) {
    NSNumber *number = SRTimeNumber(value);
    if (number && floor(number.doubleValue) == number.doubleValue) return number;
    return nil;
}
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
+ (NSDictionary *)allowlistedTimeEvidence:(NSDictionary *)evidence {
    @try {
        if (![evidence isKindOfClass:NSDictionary.class] || ![evidence[@"schema"] isEqual:@1]) return nil;
        NSNumber *generation = SRIntegerTime(evidence[@"generation"]);
        if (!generation) return nil;
        NSMutableDictionary *allowed = [NSMutableDictionary dictionaryWithObject:generation forKey:@"generation"];
        allowed[@"schema"] = @1;
        NSNumber *receivedAt = SRTimeNumber(evidence[@"receivedAt"]);
        if (receivedAt) allowed[@"receivedAt"] = receivedAt;
        NSNumber *createdAt = SRIntegerTime(evidence[@"createdAt"]);
        if (createdAt) allowed[@"createdAt"] = createdAt;
        return allowed;
    } @catch (__unused NSException *exception) { return nil; }
}
@end
