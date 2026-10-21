#import "SRSmallGroupSession.h"
#import "Core/SRStore.h"
#import "Core/SRSourceMessage.h"
#import "Core/SRRuntimeLog.h"

@class SRSmallGroupBridge;
@interface SRSmallGroupSession ()
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, strong) SRRunner *runner;
@property(nonatomic, strong) SRSmallGroupBridge *bridge;
@property(nonatomic, copy) NSString *(^currentAccount)(void);
@property(nonatomic, copy) BOOL (^environmentAllowed)(void);
@property(nonatomic, copy) BOOL (^targetAllowed)(NSString *);
@property(nonatomic, copy) SRSmallGroupHostFactory hostFactory;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSString *run;
@property(nonatomic, copy) NSDictionary *source;
@property(nonatomic, strong) id<SRSmallGroupHost> host;
@property(nonatomic, strong) NSMutableArray *evidence;
@property(nonatomic, copy) NSString *problem;
@property(nonatomic, copy) NSDictionary *lastSummary;
@property(nonatomic, copy) NSString *nativeProblem;
@property(nonatomic) BOOL dispatchEnabled;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL usedNativeHost;
@property(nonatomic) NSUInteger generation;
- (BOOL)cachedReady:(NSString *)account;
- (void)submit:(NSDictionary *)delivery source:(NSDictionary *)source completion:(SRSendCompletion)completion;
@end

@interface SRSmallGroupBridge : NSObject <SRSendTransport>
@property(nonatomic, weak) SRSmallGroupSession *owner;
@end
@implementation SRSmallGroupBridge
- (BOOL)canSendForAccount:(NSString *)account { return [self.owner cachedReady:account]; }
- (void)submitDelivery:(NSDictionary *)delivery snapshot:(NSDictionary *)snapshot completion:(SRSendCompletion)completion {
    SRSmallGroupSession *owner = self.owner;
    if (!owner) { completion(@"uncertain", nil, @"session_unavailable"); return; }
    NSDictionary *frozenDelivery = [SRSourceMessage frozenJSON:delivery], *frozenSource = [SRSourceMessage frozenJSON:snapshot];
    // Runner methods may be called by the main thread; never wait for it here.
    dispatch_async(dispatch_get_main_queue(), ^{
        [owner submit:frozenDelivery source:frozenSource completion:completion];
    });
}
@end

static BOOL SRSmallFail(NSError **error, NSString *reason) {
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.SmallGroup" code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
    return NO;
}
static BOOL SRSmallSubmitted(NSDictionary *evidence, NSDictionary *source, NSString *state, NSString *reason) {
    for (NSString *key in @[@"lookupAttempts", @"lookupMisses", @"identityConflicts"])
        if (![evidence[key] isKindOfClass:NSNumber.class]) return NO;
    if (![evidence[@"samples"] isKindOfClass:NSArray.class]) return NO;
    if (![state isEqual:@"uncertain"] || ![reason isEqual:@"submitted_delivery_unknown"] ||
        ![evidence[@"submissionAttempted"] isEqual:@YES] || ![evidence[@"hostReturned"] isEqual:@YES] ||
        ![evidence[@"observing"] isEqual:@NO] || ![evidence[@"localIDPresent"] isEqual:@YES] ||
        ![evidence[@"serverIDPresent"] isEqual:@YES] || [evidence[@"lookupAttempts"] unsignedIntegerValue] == 0 ||
        [evidence[@"lookupMisses"] unsignedIntegerValue] || [evidence[@"identityConflicts"] unsignedIntegerValue] ||
        ![evidence[@"observationServiceCheckFailed"] isEqual:@NO] || ![evidence[@"problem"] isEqual:@""]) return NO;
    if ([source[@"type"] isEqual:@"image"] &&
        (![evidence[@"materialValidated"] isEqual:@YES] || ![evidence[@"imageSetterInvoked"] isEqual:@YES])) return NO;
    for (NSDictionary *sample in evidence[@"samples"])
        if ([sample[@"source"] isEqual:@"local_readback"] && [sample[@"localIDPresent"] isEqual:@YES] &&
            [sample[@"serverIDPresent"] isEqual:@YES]) return YES;
    return NO;
}

@implementation SRSmallGroupSession
- (instancetype)initWithStore:(SRStore *)store currentAccount:(NSString *(^)(void))currentAccount
            environmentAllowed:(BOOL (^)(void))environmentAllowed targetAllowed:(BOOL (^)(NSString *))targetAllowed
                   hostFactory:(SRSmallGroupHostFactory)hostFactory clock:(double (^)(void))clock random:(double (^)(void))random {
    self = [super init];
    if (self) {
        _store = store; _currentAccount = [currentAccount copy]; _environmentAllowed = [environmentAllowed copy];
        _targetAllowed = [targetAllowed copy]; _hostFactory = [hostFactory copy]; _evidence = [NSMutableArray array];
        _bridge = [[SRSmallGroupBridge alloc] init]; _bridge.owner = self;
        __weak typeof(self) weakSelf = self;
        _runner = [[SRRunner alloc] initWithStore:store transport:_bridge clock:clock random:random environmentAllowed:^BOOL {
            SRSmallGroupSession *session = weakSelf;
            @synchronized(session) { return session && session.dispatchEnabled; }
        }];
    }
    return self;
}
- (BOOL)cachedReady:(NSString *)account {
    @synchronized(self) { return self.dispatchEnabled && [self.account isEqual:account]; }
}
- (BOOL)environmentForAccount:(NSString *)account {
    @try { return NSThread.isMainThread && self.environmentAllowed() && [self.currentAccount() isEqual:account]; }
    @catch (__unused id exception) { return NO; }
}
- (void)setEnabled:(BOOL)enabled { @synchronized(self) { self.dispatchEnabled = enabled; } }
- (BOOL)attach:(NSString *)run account:(NSString *)account error:(NSError **)error {
    NSDictionary *summary = [self.store smallGroupRun:run account:account error:error];
    if (!summary) return NO;
    if (![@[@"running", @"paused", @"awaiting_resume"] containsObject:summary[@"state"]]) return SRSmallFail(error, @"Run is terminal; capture a new source instead of replaying it");
    if (self.host || (self.busy && ![self.run isEqual:run])) return SRSmallFail(error, @"End the current run or wait for its in-flight attempt");
    BOOL previousBusy = self.busy; NSString *previousRun = self.run, *previousAccount = self.account;
    NSDictionary *previousSource = self.source;
    self.generation++; @synchronized(self) { self.account = account; }
    self.run = run; self.source = summary[@"source"]; self.busy = YES;
    self.problem = nil; self.nativeProblem = nil; self.lastSummary = nil; [self setEnabled:YES];
    if (![self.runner activateRun:run account:account error:error]) {
        [self setEnabled:NO]; self.busy = previousBusy; self.run = previousRun; self.source = previousSource;
        @synchronized(self) { self.account = previousAccount; } return NO;
    }
    [SRRuntimeLog.shared record:@"small_group_started" facts:@{@"targetCount": @([summary[@"targets"] count])}];
    return YES;
}
- (BOOL)startRule:(NSString *)rule account:(NSString *)account error:(NSError **)error {
    if (!NSThread.isMainThread || self.busy || ![self environmentForAccount:account]) return SRSmallFail(error, @"Keep WeChat in foreground, save configuration and stop other experiments; only one rule may run");
    NSString *run = [self.store startSmallGroupRule:rule account:account error:error];
    if (!run) return NO;
    BOOL attached = [self attach:run account:account error:error];
    if (!attached) [self.store pauseRun:run error:NULL];
    return attached;
}
- (BOOL)resumeRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    if (!NSThread.isMainThread || ![self environmentForAccount:account]) return SRSmallFail(error, @"Account or foreground environment is unavailable; automatic continuation is disabled");
    return [self attach:run account:account error:error];
}
- (BOOL)pauseForAccount:(NSString *)account error:(NSError **)error {
    if (!NSThread.isMainThread || !self.busy || ![self.account isEqual:account]) return SRSmallFail(error, @"No attached run belongs to this account");
    [self setEnabled:NO];
    BOOL result = [self.runner pause:error];
    [SRRuntimeLog.shared record:@"small_group_paused" facts:@{}];
    return result;
}
- (BOOL)endRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    if (!NSThread.isMainThread) return NO;
    if (self.busy && ![self.run isEqual:run]) return SRSmallFail(error, @"Another run is still active");
    BOOL attached = [self.run isEqual:run];
    if (attached && ![self.account isEqual:account]) return SRSmallFail(error, @"Account does not own this run");
    if (attached) { [self setEnabled:NO]; self.generation++; }
    BOOL result = [self.store endSmallGroupRun:run account:account error:error];
    if (attached) { [self.host stopObservation]; self.host = nil; if (result) [self.runner end:NULL]; }
    if (result && attached) { (void)[self status]; self.busy = NO; self.run = nil; self.source = nil; }
    return result;
}
- (void)submit:(NSDictionary *)delivery source:(NSDictionary *)source completion:(SRSendCompletion)completion {
    if (!NSThread.isMainThread || !delivery || !source || ![self cachedReady:source[@"account"]] || self.host ||
        ![delivery[@"run_id"] isEqual:self.run] || ![source isEqual:self.source] || ![self environmentForAccount:self.account]) {
        self.nativeProblem = @"session_changed_before_native_call";
        completion(@"uncertain", nil, self.nativeProblem); return;
    }
    NSError *error = nil; NSUInteger generation = self.generation;
    @try {
        if (!self.targetAllowed(delivery[@"target"])) { self.nativeProblem = @"target_not_currently_readable"; completion(@"uncertain", nil, self.nativeProblem); return; }
        if (![self environmentForAccount:self.account] || ![self cachedReady:self.account] || generation != self.generation) {
            self.nativeProblem = @"environment_changed_before_claim"; completion(@"uncertain", nil, self.nativeProblem); return;
        }
        if (![self.store claimSmallGroupDelivery:delivery source:source account:self.account error:&error]) {
            self.nativeProblem = @"durable_native_claim_rejected"; completion(@"uncertain", nil, self.nativeProblem); return;
        }
        // No refund/retry after this point, including constructor/image writes.
        self.usedNativeHost = YES;
        __weak typeof(self) weakSelf = self;
        BOOL (^allowed)(void) = ^BOOL {
            SRSmallGroupSession *session = weakSelf;
            return session && generation == session.generation && session.busy && [session.run isEqual:delivery[@"run_id"]] &&
                [session environmentForAccount:source[@"account"]];
        };
        self.host = self.hostFactory(source, allowed);
        if (!self.host || ![self.host readyForAccount:self.account error:&error]) {
            if (self.host) [self recordEvidence:[self.host diagnostics]];
            self.nativeProblem = @"native_preflight_rejected";
            self.host = nil; completion(@"uncertain", nil, self.nativeProblem); return;
        }
        id<SRSmallGroupHost> host = self.host;
        NSDictionary *request = @{@"account": source[@"account"], @"target": delivery[@"target"], @"sourceGroup": source[@"group"],
            @"sourceSender": source[@"sender"], @"sourceMessageID": source[@"messageID"], @"type": source[@"type"], @"payload": source[@"payload"]};
        __block BOOL finished = NO;
        [host submitRequest:request completion:^(NSString *state, __unused NSString *messageID, NSString *reason) {
            void (^finish)(void) = ^{
                if (finished) return; finished = YES;
                SRSmallGroupSession *session = weakSelf;
                if (!session) { completion(@"uncertain", nil, @"session_released"); return; }
                NSDictionary *evidence = [host diagnostics];
                BOOL submitted = generation == session.generation && [session environmentForAccount:source[@"account"]] &&
                    SRSmallSubmitted(evidence, source, state, reason);
                [session recordEvidence:evidence]; session.nativeProblem = submitted ? nil : @"native_outcome_unknown";
                if (session.host == host) session.host = nil;
                [SRRuntimeLog.shared record:submitted ? @"small_group_submitted" : @"small_group_unknown" facts:@{}];
                completion(submitted ? @"submitted" : @"uncertain", nil, submitted ? nil : @"native_outcome_unknown");
            };
            if (NSThread.isMainThread) finish(); else dispatch_async(dispatch_get_main_queue(), finish);
        }];
    } @catch (__unused id exception) {
        [self.host stopObservation]; self.host = nil;
        self.nativeProblem = @"native_session_exception";
        completion(@"uncertain", nil, @"native_session_exception");
    }
}
- (void)recordEvidence:(NSDictionary *)evidence {
    [self.evidence addObject:evidence]; if (self.evidence.count > 3) [self.evidence removeObjectAtIndex:0];
}
- (void)tick {
    if (!NSThread.isMainThread || !self.busy) return;
    if (![self environmentForAccount:self.account]) {
        if (self.dispatchEnabled || self.host) [self becameInactive];
        return;
    }
    [self.runner tick];
    NSDictionary *status = self.runner.status;
    if ([status[@"halted"] boolValue]) [self setEnabled:NO];
    self.problem = status[@"problem"];
    if (status[@"run"] == NSNull.null) { (void)[self status]; self.busy = NO; [self setEnabled:NO]; self.run = nil; self.source = nil; }
}
- (void)becameInactive {
    if (!NSThread.isMainThread || !self.busy) return;
    [self setEnabled:NO]; [self.runner pause:NULL]; self.generation++;
    [self.host stopObservation]; self.host = nil; self.problem = @"environment_stopped_manual_resume_required";
    [SRRuntimeLog.shared record:@"small_group_paused" facts:@{}];
}
- (BOOL)progressBelongsToCurrentAccount {
    @try { return NSThread.isMainThread && self.busy && [self.currentAccount() isEqual:self.account]; }
    @catch (__unused id exception) { return NO; }
}
- (BOOL)togglePauseForCurrentAccount:(NSError **)error {
    if (![self progressBelongsToCurrentAccount]) return SRSmallFail(error, @"No active run belongs to the visible account");
    return self.dispatchEnabled ? [self pauseForAccount:self.account error:error] : [self resumeRun:self.run account:self.account error:error];
}
- (BOOL)needsIdleTimer { return self.busy && (self.dispatchEnabled || self.host != nil); }
- (NSDictionary *)status {
    NSMutableDictionary *counts = [self.lastSummary[@"counts"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *state = self.lastSummary[@"state"] ?: @"idle";
    if (self.run) {
        counts = [NSMutableDictionary dictionary];
        NSDictionary *summary = [self.store summaryForRun:self.run error:NULL]; state = summary[@"state"] ?: @"unavailable";
        for (NSDictionary *row in summary[@"counts"]) counts[row[@"state"]] = row[@"count"];
        self.lastSummary = @{@"state": state, @"counts": [counts copy]};
    }
    return @{@"schema": @1, @"targetLimit": @3, @"state": state, @"busy": @(self.busy),
        @"dispatchEnabled": @(self.dispatchEnabled), @"needsIdleTimer": @(self.needsIdleTimer), @"usedNativeHost": @(self.usedNativeHost),
        @"problem": self.problem ?: @"", @"nativeProblem": self.nativeProblem ?: @"", @"counts": counts, @"deviceMultiGroupVerified": @NO,
        @"automaticRetry": @NO, @"automaticNextRule": @NO, @"deliveryOutcome": @"not_determined"};
}
- (NSDictionary *)diagnostics {
    NSMutableDictionary *result = [[self status] mutableCopy];
    result[@"hostEvidence"] = [self.evidence copy];
    result[@"currentHost"] = self.host ? [self.host diagnostics] : @{};
    return result;
}
@end
