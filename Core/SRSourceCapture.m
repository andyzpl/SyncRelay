#import "SRSourceCapture.h"
#import "SRSourceMessage.h"
#import "SRConfiguration.h"
#import "SRStore.h"
#import "SRImageAssetStore.h"
#include <math.h>
static NSNumber *_Nullable SRFrozenTime(NSTimeInterval value) {
    return (isfinite(value) && value > 0 && value <= 9007199254740991.0) ? @(value) : nil;
}
/* Versioned, numeric-only time metadata frozen together with the snapshot. It
 * never carries a correlation ID, a body or an internal observer field. */
static NSDictionary *SRSourceTimeMetadata(NSDictionary *evidence, NSTimeInterval frozenAt) {
    NSDictionary *allowed = [SRSourceMessage allowlistedTimeEvidence:evidence];
    NSNumber *received = [allowed[@"receivedAt"] isKindOfClass:NSNumber.class] ? allowed[@"receivedAt"] : nil;
    NSNumber *created = [allowed[@"createdAt"] isKindOfClass:NSNumber.class] ? allowed[@"createdAt"] : nil;
    NSNumber *generation = [allowed[@"generation"] isKindOfClass:NSNumber.class] ? allowed[@"generation"] : nil;
    NSNumber *frozen = SRFrozenTime(frozenAt);
    // `unit` describes Unix seconds for the two plugin-local observations only.
    // The host value keeps its own unverified unit: its scale and meaning have
    // not been confirmed, so it is carried as a raw number and never converted.
    return @{@"schema": @1, @"unit": @"unix_seconds", @"unitAppliesTo": @[@"receivedAt", @"previewFrozenAt"],
        @"receivedAt": received ?: (id)NSNull.null, @"receivedAtStatus": received ? @"recorded" : @"unknown",
        @"previewFrozenAt": frozen ?: (id)NSNull.null, @"previewFrozenAtStatus": frozen ? @"recorded" : @"unknown",
        @"createdAt": created ?: (id)NSNull.null, @"createdAtStatus": created ? @"unverified" : @"unknown",
        @"createdAtUnit": @"unverified", @"createdAtSemanticsVerified": @NO,
        @"receiverGeneration": generation ?: (id)NSNull.null};
}
@interface SRSourceCapture ()
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, copy) NSTimeInterval (^clock)(void);
@property(nonatomic, copy, nullable) NSNumber *receiverRound;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSDictionary *configuration;
@property(nonatomic, copy, nullable) NSDictionary *captured;
@property(nonatomic) BOOL waiting;
/* Monotonic round token. It is bumped on every successful arm so that
 * diagnostics and any in-flight offer belong to exactly one capture round and a
 * re-arm cannot be confused with the previous round. */
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger offered;
@property(nonatomic) NSUInteger rejected;
@property(nonatomic) NSInteger lastReason;
@end
@implementation SRSourceCapture
- (instancetype)initWithStore:(SRStore *)store {
    return [self initWithStore:store clock:^NSTimeInterval { return NSDate.date.timeIntervalSince1970; }];
}
- (instancetype)initWithStore:(SRStore *)store clock:(NSTimeInterval (^)(void))clock {
    self = [super init];
    if (self) {
        _store = store;
        _clock = clock ? [clock copy] : [^NSTimeInterval { return NSDate.date.timeIntervalSince1970; } copy];
    }
    return self;
}
- (NSDictionary *)preview { @synchronized(self) { return self.captured; } }
/* Read once, at acceptance. An unusable clock yields an explicit unknown
 * instead of a fabricated or non-finite JSON number. */
- (NSTimeInterval)freezeClock {
    NSTimeInterval now = 0;
    @try { now = self.clock ? self.clock() : 0; } @catch (__unused NSException *exception) { now = 0; }
    return (isfinite(now) && now > 0) ? now : 0;
}
- (BOOL)armForAccount:(NSString *)account configuration:(NSDictionary *)configuration error:(NSError **)error {
    @synchronized(self) {
        NSDictionary *frozen = [SRSourceMessage frozenJSON:configuration];
        NSString *problem = nil; NSInteger code = 0;
        if (!account.length) { code = 11; problem = @"无法核对当前账号，请先重新读取配置。"; }
        else if (![SRConfiguration validateDraft:frozen error:NULL]) { code = 12; problem = @"当前设置无效，请检查来源、间隔和目标群后重新保存。"; }
        else if (![frozen[@"sourceGroup"] count]) { code = 13; problem = @"尚未选择母群，请先选择消息来源群。"; }
        else if (![frozen[@"senders"] count]) { code = 14; problem = @"尚未选择来源成员。更换母群后需重新勾选“我”或指定成员，再保存。"; }
        else if (![frozen[@"rules"] count]) { code = 15; problem = @"尚无目标规则，请先自动分组或手动选择目标群，再保存。"; }
        if (problem) {
            self.lastReason = code;
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.Capture" code:code userInfo:@{NSLocalizedDescriptionKey: problem}];
            return NO;
        }
        if (self.waiting || self.captured) {
            self.lastReason = 2;
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.Capture" code:2 userInfo:@{NSLocalizedDescriptionKey: @"已有等待或未确认预览，请先取消等待、确认或放弃预览。"}];
            return NO;
        }
        self.account = account; self.configuration = frozen; self.waiting = YES;
        self.offered = 0; self.rejected = 0; self.lastReason = 0; self.generation++;
        // A new round starts unbound: the host arm that follows decides which
        // receiver round may deliver into it.
        self.receiverRound = nil;
        return YES;
    }
}
- (void)bindReceiverGeneration:(NSNumber *)generation {
    @synchronized(self) {
        NSNumber *value = [generation isKindOfClass:NSNumber.class] ? generation : nil;
        self.receiverRound = (value && isfinite(value.doubleValue) && value.doubleValue > 0) ? value : nil;
    }
}
- (BOOL)offerEnvelope:(NSDictionary *)envelope { return [self offerEnvelope:envelope evidence:nil]; }
- (BOOL)offerEnvelope:(NSDictionary *)envelope evidence:(NSDictionary *)evidence {
    @synchronized(self) {
        // Only a live, currently-waiting round may record diagnostics. A late
        // callback after cancel/confirm-failure/stop, or a stray envelope from a
        // previous round, must not increment the current round's counters or
        // overwrite lastReason; the next arm resets them explicitly.
        if (!self.waiting) return NO;
        NSDictionary *snapshot = [SRSourceMessage frozenJSON:envelope];
        self.offered++;
        if (![SRSourceMessage matchesEnvelope:snapshot configuration:self.configuration account:self.account]) {
            NSInteger reason = 24;
            if (![snapshot[@"sender"] isKindOfClass:NSString.class] || ![snapshot[@"type"] isKindOfClass:NSString.class]) reason = 24;
            else if (![snapshot[@"account"] isEqual:self.account]) reason = 20;
            else if (![snapshot[@"group"] isEqual:self.configuration[@"sourceGroup"][@"id"]]) reason = 21;
            else if (![[self.configuration[@"senders"] valueForKey:@"id"] containsObject:snapshot[@"sender"]]) reason = 22;
            else if (![self.configuration[@"types"] containsObject:snapshot[@"type"]]) reason = 23;
            self.rejected++; self.lastReason = reason; return NO;
        }
        NSDictionary *allowed = [SRSourceMessage allowlistedTimeEvidence:evidence];
        NSNumber *generation = allowed[@"generation"];
        // Refuse a provably different round. The evidence must name the bound
        // receiver round; the capture generation is a different counter and is
        // deliberately never part of this comparison. Evidence that is missing
        // or unusable is not a conflict: it degrades to an explicit unknown
        // without relaxing the identity gates the envelope already passed.
        if (self.receiverRound && generation &&
            self.receiverRound.unsignedIntegerValue != generation.unsignedIntegerValue) {
            self.rejected++; self.lastReason = 25; return NO;
        }
        NSMutableDictionary *merged = [snapshot mutableCopy];
        merged[@"sourceTime"] = SRSourceTimeMetadata(evidence, [self freezeClock]);
        NSDictionary *frozen = [SRSourceMessage frozenJSON:merged];
        if (!frozen) { self.rejected++; self.lastReason = 24; return NO; }
        self.lastReason = 0;
        self.captured = frozen; self.waiting = NO;
        return YES;
    }
}
- (NSString *)confirmForCurrentAccount:(NSString *)account error:(NSError **)error {
    @synchronized(self) {
        if (!self.captured || ![account isEqual:self.account]) {
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.Capture" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No captured message or account changed"}];
            return nil;
        }
        NSString *plan = [self.store createPlanFromConfiguration:self.configuration envelope:self.captured account:account error:error];
        if (plan) { self.captured = nil; [self cancel]; }
        return plan;
    }
}
- (void)cancel {
    @synchronized(self) {
        if ([self.captured[@"type"] isEqual:@"image"]) [self.store.imageAssets discardPayload:self.captured[@"payload"]];
        self.waiting = NO; self.captured = nil; self.configuration = nil; self.account = nil;
        self.receiverRound = nil;
    }
}
- (NSDictionary *)status {
    @synchronized(self) {
        return @{@"state": self.captured ? @"preview" : (self.waiting ? @"waiting" : @"idle"),
            @"account": self.account ?: (id)NSNull.null, @"configuration": self.configuration ?: @{}};
    }
}
- (NSDictionary *)diagnostics {
    @synchronized(self) {
        return @{@"state": self.captured ? @"preview" : (self.waiting ? @"waiting" : @"idle"),
            @"generation": @(self.generation),
            @"offered": @(self.offered), @"rejected": @(self.rejected), @"lastReasonCode": @(self.lastReason)};
    }
}
@end
