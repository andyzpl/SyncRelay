#import "SRSourceTimeProbe.h"
#import "SRWeChatReceiver.h"
#import "Core/SRConfiguration.h"
#import "Core/SRSourceMessage.h"
#import "Core/SROperationsState.h"
#import <objc/runtime.h>
#include <math.h>
#include <string.h>

static const NSUInteger SRSampleLimit = 16;
static const double SRDurationLimit = 120;

static BOOL SRProbeTime(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) && [value doubleValue] > 0;
}
static BOOL SRProbeInteger(id value) {
    if (!SRProbeTime(value)) return NO;
    double number = [value doubleValue];
    return number <= 9007199254740991.0 && floor(number) == number;
}
static NSString *SRProbeGetterEncoding(Class type) {
    Method method = type ? class_getInstanceMethod(type, NSSelectorFromString(@"m_uiCreateTime")) : NULL;
    if (!method) return @"missing";
    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        const char *result = signature.methodReturnType;
        while (*result && strchr("rnNoORV", *result)) result++;
        if (signature.numberOfArguments == 2 && result[0] && !result[1] && strchr("iIqQlL", result[0]))
            return [NSString stringWithUTF8String:result];
    } @catch (__unused id exception) { }
    return @"incompatible";
}

@interface SRSourceTimeProbe ()
@property(nonatomic, strong) SRWeChatReceiver *receiver;
@property(nonatomic, copy) Class (^resolver)(NSString *);
@property(nonatomic, copy) NSString *(^currentAccount)(void);
@property(nonatomic, copy) NSDictionary *(^configuration)(NSString *);
@property(nonatomic, copy) BOOL (^environmentAllowed)(void);
@property(nonatomic, copy) double (^monotonicClock)(void);
@property(nonatomic, copy) NSTimeInterval (^wallClock)(void);
@property(nonatomic, copy) void (^legacyReceived)(NSDictionary *);
@property(nonatomic, copy) void (^changed)(void);
@property(nonatomic) BOOL starting;
@property(nonatomic) BOOL listening;
@property(nonatomic) NSUInteger round;
@property(nonatomic) NSUInteger receiverGeneration;
@property(nonatomic) NSUInteger lastProbeGeneration;
@property(nonatomic) NSTimeInterval listeningSince;
@property(nonatomic) double startedMonotonic;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSDictionary *frozenConfiguration;
@property(nonatomic, copy) NSString *state;
@property(nonatomic, copy) NSString *getterEncoding;
@property(nonatomic, strong) NSMutableArray *samples;
@property(nonatomic, strong) NSMutableDictionary *messageOrdinals;
@property(nonatomic, strong) NSMutableArray *hookSamples;
@property(nonatomic, strong) NSMutableDictionary *hookOrdinals;
@end

@implementation SRSourceTimeProbe
- (instancetype)initWithReceiver:(SRWeChatReceiver *)receiver classResolver:(Class (^)(NSString *))resolver
                 currentAccount:(NSString *(^)(void))currentAccount configurationForAccount:(NSDictionary *(^)(NSString *))configuration
             environmentAllowed:(BOOL (^)(void))environmentAllowed monotonicClock:(double (^)(void))monotonicClock
                      wallClock:(NSTimeInterval (^)(void))wallClock legacyReceived:(void (^)(NSDictionary *))legacyReceived
                        changed:(void (^)(void))changed {
    self = [super init];
    if (self) {
        _receiver = receiver; _resolver = [resolver copy]; _currentAccount = [currentAccount copy];
        _configuration = [configuration copy]; _environmentAllowed = [environmentAllowed copy];
        _monotonicClock = [monotonicClock copy]; _wallClock = [wallClock copy];
        _legacyReceived = [legacyReceived copy]; _changed = [changed copy];
        _state = @"off"; _getterEncoding = @"not_observed";
        _samples = [NSMutableArray array]; _messageOrdinals = [NSMutableDictionary dictionary];
        _hookSamples = [NSMutableArray array]; _hookOrdinals = [NSMutableDictionary dictionary];
        __weak typeof(self) weakSelf = self;
        receiver.receivedWithTimeEvidence = ^(NSDictionary *message, NSDictionary *evidence) {
            [weakSelf receiveMessage:message evidence:evidence];
        };
    }
    return self;
}
- (BOOL)active { return self.starting || self.listening; }
- (BOOL)fail:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.SourceTimeProbe" code:1 userInfo:@{
        NSLocalizedDescriptionKey: @"Read-only sampling requires saved text sources, a stable account, and no capture or sending activity"}];
    return NO;
}
- (void)notifyChanged {
    @try { self.changed(); } @catch (__unused id exception) { }
}
- (NSString *)contextProblemForAccount:(NSString *)account configuration:(NSDictionary *)configuration {
    @try {
        if (![self.currentAccount() isEqual:account]) return @"account_invalidated";
        if (![self.configuration(account) isEqual:configuration]) return @"configuration_changed";
        if (!self.environmentAllowed()) return @"environment_blocked";
    } @catch (__unused id exception) { return @"context_unavailable"; }
    return nil;
}
- (BOOL)startForAccount:(NSString *)account configuration:(NSDictionary *)configuration error:(NSError **)error {
    if (!NSThread.isMainThread || self.active) return [self fail:error];
    @try { if ([self.receiver.diagnostics[@"armed"] boolValue]) return [self fail:error]; }
    @catch (__unused id exception) { return [self fail:error]; }
    NSDictionary *frozen = [SRSourceMessage frozenJSON:configuration];
    if (!account.length || [account hasSuffix:@"@chatroom"] || ![SRConfiguration validateDraft:frozen error:NULL] ||
        ![frozen[@"sourceGroup"] count] || ![frozen[@"senders"] count] || ![frozen[@"types"] containsObject:@"text"] ||
        [self contextProblemForAccount:account configuration:frozen]) return [self fail:error];
    double monotonic, wall;
    NSString *encoding;
    @try { monotonic = self.monotonicClock(); wall = self.wallClock(); encoding = SRProbeGetterEncoding(self.resolver(@"CMessageWrap")); }
    @catch (__unused id exception) { return [self fail:error]; }
    if (!isfinite(monotonic) || monotonic < 0 || !isfinite(wall) || wall <= 0 || self.round == NSUIntegerMax) return [self fail:error];

    // Historical callbacks must remain observable. Images are excluded before
    // the receiver can enter its download/snapshot preparation chain.
    NSMutableDictionary *textOnly = [frozen mutableCopy]; textOnly[@"types"] = @[@"text"];
    self.starting = YES;
    BOOL armed = NO, valid = NO; NSDictionary *diagnostic = nil;
    @try {
        armed = [self.receiver armForAccount:account configuration:textOnly newMessagesOnly:NO error:error];
        diagnostic = self.receiver.diagnostics;
        valid = self.starting && armed && [diagnostic[@"armed"] boolValue] && SRProbeTime(diagnostic[@"armedAt"]) &&
            SRProbeInteger(diagnostic[@"receiverGeneration"]) &&
            ![self contextProblemForAccount:account configuration:frozen];
    } @catch (__unused id exception) { [self.receiver stop]; }
    self.starting = NO;
    if (!valid) {
        if (armed) [self.receiver stop];
        return [self fail:error];
    }
    self.round++; self.receiverGeneration = [diagnostic[@"receiverGeneration"] unsignedIntegerValue];
    self.lastProbeGeneration = MAX(self.lastProbeGeneration, self.receiverGeneration);
    self.account = [account copy]; self.frozenConfiguration = frozen;
    self.listeningSince = [diagnostic[@"armedAt"] doubleValue]; self.startedMonotonic = monotonic;
    self.getterEncoding = encoding; self.state = @"sampling";
    [self.samples removeAllObjects]; [self.messageOrdinals removeAllObjects];
    [self.hookSamples removeAllObjects]; [self.hookOrdinals removeAllObjects];
    __weak typeof(self) weakSelf = self;
    self.receiver.observeTimeHook = ^(NSDictionary *observation) { [weakSelf receiveTimeHook:observation]; };
    self.listening = YES; [self notifyChanged];
    return YES;
}
- (BOOL)ownsReceiver {
    @try {
        NSDictionary *diagnostic = self.receiver.diagnostics;
        return [diagnostic[@"armed"] boolValue] && [diagnostic[@"armedAt"] doubleValue] == self.listeningSince &&
            [diagnostic[@"receiverGeneration"] unsignedIntegerValue] == self.receiverGeneration;
    } @catch (__unused id exception) { return NO; }
}
- (void)stopWithState:(NSString *)state clearSamples:(BOOL)clearSamples {
    BOOL stopReceiver = self.listening && [self ownsReceiver];
    self.listening = NO; self.starting = NO; self.state = state;
    self.receiver.observeTimeHook = nil;
    [self.messageOrdinals removeAllObjects];
    [self.hookOrdinals removeAllObjects];
    if (clearSamples) {
        [self.samples removeAllObjects]; self.account = nil; self.frozenConfiguration = nil;
        [self.hookSamples removeAllObjects];
        self.getterEncoding = @"not_observed";
    }
    // Invalidate our route before the receiver's optional trace can reenter UI.
    if (stopReceiver) [self.receiver stop];
    [self notifyChanged];
}
- (void)stopForReason:(SRSourceTimeProbeStopReason)reason {
    if (!NSThread.isMainThread) return;
    BOOL invalidate = reason == SRSourceTimeProbeAccountInvalidated || reason == SRSourceTimeProbeConfigurationChanged;
    if (!self.active && !(invalidate && self.account)) return;
    NSString *state = @"stopped";
    if (reason == SRSourceTimeProbeInactive) state = @"inactive";
    if (reason == SRSourceTimeProbeConfigurationChanged) state = @"configuration_changed";
    if (reason == SRSourceTimeProbeAccountInvalidated) state = @"account_invalidated";
    [self stopWithState:state clearSamples:invalidate];
}
- (void)tick {
    if (!NSThread.isMainThread || self.starting || !self.account) return;
    NSUInteger round = self.round; NSString *account = self.account;
    NSString *problem = [self contextProblemForAccount:account configuration:self.frozenConfiguration];
    if (self.round != round || self.account != account) return;
    if (problem && (![problem isEqual:@"environment_blocked"] || self.listening)) {
        [self stopWithState:problem clearSamples:![problem isEqual:@"environment_blocked"]]; return;
    }
    if (!self.listening) return;
    BOOL owns = [self ownsReceiver];
    if (self.round != round || !self.listening) return;
    if (!owns) { [self stopWithState:@"receiver_stopped" clearSamples:NO]; return; }
    double now;
    @try { now = self.monotonicClock(); } @catch (__unused id exception) { now = NAN; }
    if (self.round != round || !self.listening) return;
    if (!isfinite(now) || now < self.startedMonotonic) { [self stopWithState:@"clock_invalid" clearSamples:NO]; return; }
    if (now - self.startedMonotonic >= SRDurationLimit) [self stopWithState:@"time_limit" clearSamples:NO];
}
- (void)receiveMessage:(NSDictionary *)message evidence:(NSDictionary *)evidence {
    if (!NSThread.isMainThread || self.starting || ![message isKindOfClass:NSDictionary.class] || ![evidence isKindOfClass:NSDictionary.class]) return;
    if (!self.listening) {
        // The receiver rejects old generations before delivery. Do not compare
        // wall-clock boundaries here: a later manual capture can share a time.
        if (self.lastProbeGeneration && SRProbeInteger(evidence[@"generation"]) &&
            [evidence[@"generation"] unsignedIntegerValue] <= self.lastProbeGeneration) return;
        self.legacyReceived(message); return;
    }
    // Stopping can notify a consumer that explicitly starts another round.
    // A repeated wall-clock boundary must not admit this old callback there.
    NSUInteger round = self.round;
    [self tick];
    if (!self.listening || self.round != round) return;
    if (![evidence[@"schema"] isEqual:@1] || !SRProbeInteger(evidence[@"generation"]) ||
        !SRProbeTime(evidence[@"listeningSince"]) || [evidence[@"listeningSince"] doubleValue] != self.listeningSince ||
        !SRProbeTime(evidence[@"receivedAt"])) return;
    NSUInteger generation = [evidence[@"generation"] unsignedIntegerValue];
    if (self.receiverGeneration && generation != self.receiverGeneration) return;
    if (![message[@"account"] isEqual:self.account] || ![message[@"group"] isEqual:self.frozenConfiguration[@"sourceGroup"][@"id"]] ||
        ![[self.frozenConfiguration[@"senders"] valueForKey:@"id"] containsObject:message[@"sender"]] ||
        ![message[@"type"] isEqual:@"text"] || ![message[@"generatedByRelay"] isEqual:@NO]) return;
    NSString *messageID = message[@"messageID"];
    if (![messageID isKindOfClass:NSString.class] || !messageID.length || messageID.length > 128) return;
    NSTimeInterval delivered;
    @try { delivered = self.wallClock(); } @catch (__unused id exception) { delivered = NAN; }
    if (!self.listening || self.round != round) return;
    if (!isfinite(delivered) || delivered <= 0) { [self stopWithState:@"clock_invalid" clearSamples:NO]; return; }
    self.receiverGeneration = generation; self.lastProbeGeneration = MAX(self.lastProbeGeneration, generation);
    NSNumber *ordinal = self.messageOrdinals[messageID];
    if (!ordinal) { ordinal = @(self.messageOrdinals.count + 1); self.messageOrdinals[messageID] = ordinal; }
    NSNumber *created = SRProbeInteger(evidence[@"createdAt"]) ? evidence[@"createdAt"] : nil;
    double received = [evidence[@"receivedAt"] doubleValue];
    NSString *relationship = @"missing_or_invalid";
    if (created) {
        if (received < self.listeningSince) relationship = @"receive_clock_rollback";
        else if (created.doubleValue > received) relationship = @"future_or_different_units";
        else if (floor(created.doubleValue) < floor(self.listeningSince)) relationship = @"older_than_boundary";
        else if (floor(created.doubleValue) == floor(self.listeningSince)) relationship = @"same_second";
        else relationship = @"after_boundary";
    }
    [self.samples addObject:@{@"ordinal": @(self.samples.count + 1), @"messageOrdinal": ordinal, @"round": @(self.round),
        @"receiverGeneration": @(generation), @"selfSource": @([message[@"sender"] isEqual:self.account]),
        @"createdAt": created ?: (id)NSNull.null, @"receivedAt": evidence[@"receivedAt"],
        @"listeningSince": evidence[@"listeningSince"], @"deliveredAt": @(delivered),
        @"deliveryClockRollback": @(delivered < received), @"relationship": relationship,
        @"strictPolicyWouldAccept": @(created && delivered >= received && SROpsNewMessage(created.doubleValue, self.listeningSince, received))}];
    if (self.samples.count >= SRSampleLimit) [self stopWithState:@"sample_limit" clearSamples:NO];
    else [self notifyChanged];
}
- (void)receiveTimeHook:(NSDictionary *)observation {
    if (!NSThread.isMainThread || !self.listening) return;
    NSUInteger round = self.round;
    [self tick];
    if (!self.listening || self.round != round || self.hookSamples.count >= SRSampleLimit) return;
    NSDictionary *evidence = observation[@"evidence"];
    if (![evidence[@"schema"] isEqual:@1] || !SRProbeInteger(evidence[@"generation"]) ||
        !SRProbeTime(evidence[@"receivedAt"]) || !SRProbeTime(evidence[@"listeningSince"]) ||
        [evidence[@"listeningSince"] doubleValue] != self.listeningSince ||
        ![observation[@"account"] isEqual:self.account] ||
        ![[self.frozenConfiguration[@"senders"] valueForKey:@"id"] containsObject:observation[@"sender"]] ||
        ![@[@1, @3] containsObject:observation[@"type"]]) return;
    NSUInteger generation = [evidence[@"generation"] unsignedIntegerValue];
    if (self.receiverGeneration && generation != self.receiverGeneration) return;
    self.receiverGeneration = generation; self.lastProbeGeneration = MAX(self.lastProbeGeneration, generation);
    NSString *encoding = observation[@"actualGetterEncoding"], *path = observation[@"path"];
    if (![@[@"i", @"I", @"q", @"Q", @"l", @"L", @"missing", @"incompatible"] containsObject:encoding] ||
        ![@[@"receive", @"outgoing"] containsObject:path]) return;
    // Only exact nonzero IDs correlate. Local and server identities are not
    // merged speculatively; a zero-ID event remains explicitly uncorrelated.
    NSString *key = nil;
    NSNumber *server = observation[@"serverID"], *local = observation[@"localID"];
    if ([server isKindOfClass:NSNumber.class] && server.unsignedLongLongValue)
        key = [@"s:" stringByAppendingString:server.stringValue];
    else if ([local isKindOfClass:NSNumber.class] && local.unsignedLongLongValue)
        key = [@"l:" stringByAppendingString:local.stringValue];
    NSNumber *ordinal = key ? self.hookOrdinals[key] : nil;
    if (key && !ordinal) { ordinal = @(self.hookOrdinals.count + 1); self.hookOrdinals[key] = ordinal; }
    NSNumber *created = SRProbeInteger(evidence[@"createdAt"]) ? evidence[@"createdAt"] : nil;
    [self.hookSamples addObject:@{@"ordinal": @(self.hookSamples.count + 1), @"messageOrdinal": ordinal ?: (id)NSNull.null,
        @"round": @(round), @"receiverGeneration": @(generation), @"messageType": observation[@"type"],
        @"selfSource": @([observation[@"sender"] isEqual:self.account]), @"path": path,
        @"serverIDPresent": @([server isKindOfClass:NSNumber.class] && server.unsignedLongLongValue != 0),
        @"correlationScope": key ? (server.unsignedLongLongValue ? @"server" : @"local") : @"none",
        @"actualGetterEncoding": encoding, @"createdAt": created ?: (id)NSNull.null,
        @"receivedAt": evidence[@"receivedAt"], @"listeningSince": evidence[@"listeningSince"]}];
    [self notifyChanged];
}
- (NSDictionary *)diagnostics {
    [self tick];
    return @{@"schema": @1, @"observerOnly": @YES, @"textOnly": @NO, @"deliveredTextOnly": @YES, @"active": @(self.active),
        @"state": self.state, @"round": @(self.round), @"sampleLimit": @(SRSampleLimit), @"durationLimit": @(SRDurationLimit),
        @"getterDeclaredReturnEncoding": self.getterEncoding, @"getterDeclarationScope": @"configured_wrap_class",
        @"actualWrapABIObserved": @(self.hookSamples.count > 0), @"sourceTimeSemanticsVerified": @NO, @"imageReadinessObserved": @NO,
        @"prefilteredCallbacksObserved": @(self.hookSamples.count > 0), @"sendingEnabled": @NO, @"samples": [self.samples copy],
        @"hookSampleLimit": @(SRSampleLimit), @"hookScope": @"selected_source_text_image_before_readiness_filters",
        @"hookSamples": [self.hookSamples copy]};
}
@end
