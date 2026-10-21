#import "SRRelayCoordinator.h"
#import "SRStore.h"
#import "SRConfiguration.h"
#import "SRSourceMessage.h"
#import "SROperationsState.h"
#include <math.h>

@interface SRRelayCoordinator () {
    SROperationsState _state;
}
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, strong) id<SRRelayExecution> execution;
@property(nonatomic, strong) id<SRRelayCaptureControl> capture;
@property(nonatomic, copy) NSString * _Nullable (^currentAccount)(void);
@property(nonatomic, copy) NSTimeInterval (^clock)(void);
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSDictionary *configuration;
@property(nonatomic, copy) NSDictionary *content;
@property(nonatomic, copy) NSDictionary *recent;
@property(nonatomic, copy) NSDictionary *run;
@property(nonatomic, copy) NSDictionary *legacyRun;
@property(nonatomic, copy) NSArray *groups;
@property(nonatomic, copy) NSArray *requirements;
@property(nonatomic, copy) NSString *problem;
@property(nonatomic, copy) NSString *manualRun;
@property(nonatomic, copy) NSString *commandProblem;
@property(nonatomic) BOOL loadedAccount;
@property(nonatomic) BOOL requireEnable;
@property(nonatomic) BOOL foreground;
@property(nonatomic) BOOL verified;
@property(nonatomic) BOOL mutating;
@property(nonatomic) BOOL lifecyclePending;
@property(nonatomic) BOOL stateLoaded;
@property(nonatomic) BOOL listening;
@property(nonatomic) BOOL safetyLatched;
@property(nonatomic) uint64_t listeningGeneration;
@property(nonatomic) NSTimeInterval listeningSince;
- (BOOL)reloadAllowPause:(BOOL)allowPause error:(NSError **)error;
@end

static BOOL SRRelayFail(NSError **error, NSString *reason) {
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.Coordinator" code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
    return NO;
}

@implementation SRRelayCoordinator
- (instancetype)initWithStore:(SRStore *)store execution:(id<SRRelayExecution>)execution
                       capture:(id<SRRelayCaptureControl>)capture currentAccount:(NSString * _Nullable (^)(void))currentAccount
                         clock:(NSTimeInterval (^)(void))clock {
    self = [super init];
    if (self) {
        _store = store; _execution = execution; _capture = capture;
        _currentAccount = [currentAccount copy]; _clock = [clock copy];
        _groups = @[]; _requirements = @[];
    }
    return self;
}
- (BOOL)stopCapture {
    self.listening = NO;
    @try { [self.capture stop]; return YES; }
    @catch (__unused id exception) {
        self.safetyLatched = YES; _state.fault = true;
        self.problem = @"Capture could not be stopped; operations are blocked";
        return NO;
    }
}
- (BOOL)fail:(NSError **)error reason:(NSString *)reason {
    self.problem = reason; self.safetyLatched = YES; _state.fault = true; _state.generation++;
    [self stopCapture];
    // A port may have persisted a run before throwing, even if it is not loaded yet.
    @try { if (self.account.length) [self.execution pauseForAccount:self.account error:NULL]; }
    @catch (__unused id exception) { }
    return SRRelayFail(error, reason);
}
- (BOOL)performCommand:(BOOL (^)(NSError **))command error:(NSError **)error {
    if (!NSThread.isMainThread || self.mutating) return SRRelayFail(error, @"Another coordinator command is in progress");
    self.mutating = YES;
    BOOL result = NO; NSError *failure = nil;
    @try { result = command(&failure); }
    @catch (__unused id exception) { [self fail:&failure reason:@"Coordinator port failed; operations are stopped"]; }
    @finally {
        // Host calls can synchronously deliver lifecycle notifications. Apply the
        // latest one before releasing ownership, but never spin on a broken port.
        if (self.lifecyclePending) {
            self.lifecyclePending = NO;
            @try { (void)[self reloadAllowPause:YES error:NULL]; }
            @catch (__unused id exception) { [self fail:NULL reason:@"Lifecycle recovery failed; operations are stopped"]; }
            if (self.lifecyclePending) {
                self.lifecyclePending = NO;
                [self fail:NULL reason:@"Repeated lifecycle reentry; explicitly enable operations after recovery"];
            }
            result = NO;
            if (!failure) SRRelayFail(&failure, @"Lifecycle changed during the command; sending requires manual continuation");
        }
        self.mutating = NO;
    }
    if (!result && !failure) SRRelayFail(&failure, self.problem ?: self.commandProblem ?: @"Coordinator command did not complete");
    if (error && failure) *error = failure;
    return result;
}
- (BOOL)updateCapture:(NSError **)error {
    if (!SROpsCaptureAllowed(_state)) {
        if (self.listening && ![self stopCapture]) return SRRelayFail(error, self.problem);
        return YES;
    }
    if (self.listening && self.listeningGeneration == _state.generation) return YES;
    if (![self stopCapture]) return SRRelayFail(error, self.problem);
    NSTimeInterval since = self.clock(); uint64_t generation = _state.generation;
    if (!isfinite(since) || since <= 0) return [self fail:error reason:@"Capture clock cannot be verified"];
    NSError *failure = nil;
    if (![self.capture startForAccount:self.account configuration:self.configuration generation:generation error:&failure])
        return [self fail:error reason:failure.localizedDescription ?: @"Capture could not be armed"];
    if (generation != _state.generation || self.lifecyclePending || !SROpsCaptureAllowed(_state)) {
        [self stopCapture];
        return SRRelayFail(error, @"Capture ownership changed while arming");
    }
    self.listening = YES; self.listeningGeneration = generation; self.listeningSince = since;
    return YES;
}
- (BOOL)refreshForeground:(BOOL)foreground sourceTimeVerified:(BOOL)verified error:(NSError **)error {
    if (!NSThread.isMainThread) return SRRelayFail(error, @"Coordinator commands require the main thread");
    self.foreground = foreground; self.verified = verified;
    if (self.mutating) {
        self.lifecyclePending = YES; self.manualRun = nil;
        _state.generation++; _state.trusted = false; _state.fault = true;
        return SRRelayFail(error, @"Lifecycle refresh is deferred until the current command drains");
    }
    return [self performCommand:^BOOL(NSError **failure) { return [self reloadAllowPause:YES error:failure]; } error:error];
}
- (BOOL)reloadAllowPause:(BOOL)allowPause error:(NSError **)error {
    self.stateLoaded = NO;
    NSString *account = nil;
    @try { account = self.currentAccount(); } @catch (__unused id exception) { }
    if (![account isKindOfClass:NSString.class]) account = nil;
    if (!account.length || ![account isEqual:self.account]) {
        BOOL stopped = [self stopCapture];
        @try { if (self.account.length) [self.execution pauseForAccount:self.account error:NULL]; }
        @catch (__unused id exception) { }
        SROpsApply(&_state, SROpsAccountInvalidated, _state.generation);
        self.requireEnable = self.loadedAccount;
        self.account = nil; self.content = nil; self.recent = nil; self.configuration = nil;
        self.groups = @[]; self.run = nil; self.legacyRun = nil; self.manualRun = nil;
        self.requirements = @[]; self.commandProblem = nil;
        self.safetyLatched = !stopped;
        if (!account.length) return [self fail:error reason:@"Current account cannot be verified"];
        if (self.requireEnable && ![self.store setOperationsEnabled:NO account:account error:error])
            return [self fail:error reason:@"Account changed; disabling operations could not be persisted"];
        self.account = account; self.loadedAccount = YES;
        SROpsRestore(&_state, false, false, SROpsWaiting);
    }
    NSError *failure = nil;
    NSNumber *enabled = [self.store operationsEnabledForAccount:account error:&failure];
    NSDictionary *config = [self.store configurationForAccount:account error:NULL];
    NSDictionary *saved = [self.store operationsContentForAccount:account error:&failure];
    if (!enabled || !saved) return [self fail:error reason:failure.localizedDescription ?: @"Operations state could not be loaded"];
    // Editable settings can fail independently of a valid frozen task. Load its
    // safety controls, but never capture or dispatch with unreadable settings.
    BOOL configurationLoaded = config != nil;
    if (!configurationLoaded) {
        config = @{}; self.safetyLatched = YES;
        self.problem = @"Saved configuration is unreadable; repair settings before operations can start";
    }
    if (self.configuration && ![self.configuration isEqual:config]) {
        [self stopCapture]; SROpsApply(&_state, SROpsConfigurationChanged, _state.generation);
    }
    if (_state.sourceVerified && !self.verified) {
        _state.generation++; [self stopCapture];
    }
    self.configuration = config; self.requirements = [SRConfiguration operationsRequirementsForDraft:config];
    self.content = saved[@"current"] == NSNull.null ? nil : saved[@"current"];
    self.recent = saved[@"recent"] == NSNull.null ? nil : saved[@"recent"];
    self.legacyRun = saved[@"legacyRun"] == NSNull.null ? nil : saved[@"legacyRun"];
    if (!self.foreground && _state.foreground) {
        SROpsApply(&_state, SROpsBackground, _state.generation); self.manualRun = nil;
    }
    BOOL shouldEnable = enabled.boolValue && !self.requireEnable;
    _state.trusted = true;
    if (_state.enabled != shouldEnable)
        SROpsApply(&_state, shouldEnable ? SROpsEnableCommitted : SROpsDisable, _state.generation);
    _state.foreground = self.foreground;
    _state.sourceVerified = self.verified; _state.occupied = self.content != nil;
    _state.fault = self.safetyLatched;
    if (!self.safetyLatched) self.problem = nil;
    self.run = nil; self.groups = @[];
    NSString *plan = self.content[@"plan_id"];
    if (plan && (id)plan != NSNull.null) {
        self.groups = [self.store ruleCardsForPlan:plan account:account error:&failure];
        if (!self.groups) return [self fail:error reason:failure.localizedDescription ?: @"Content groups could not be loaded"];
        NSDictionary *latest = nil;
        for (NSDictionary *group in self.groups) {
            NSDictionary *run = group[@"latestRun"];
            if ((id)run == NSNull.null) continue;
            if ([@[@"running", @"paused", @"awaiting_resume"] containsObject:run[@"state"]]) { self.run = run; break; }
            if (!latest || [run[@"started_at"] doubleValue] > [latest[@"started_at"] doubleValue]) latest = run;
        }
        if (!self.run) self.run = latest;
    }
    if (!self.content) _state.phase = self.recent ? SROpsContentCompleted : SROpsWaiting;
    else if (!self.run) _state.phase = SROpsReady;
    else {
        NSDictionary *cancellation = [self.store operationsCancellationForRun:self.run[@"id"] account:account error:&failure];
        if (!cancellation) return [self fail:error reason:failure.localizedDescription ?: @"Cancellation state could not be loaded"];
        BOOL inflight = [self.run[@"counts"][@"submitting"] unsignedIntegerValue] > 0;
        if (cancellation.count) _state.phase = cancellation[@"drained_at"] == NSNull.null ? SROpsCancelling : SROpsGroupCancelled;
        else if ([self.run[@"state"] isEqual:@"completed"]) _state.phase = SROpsGroupCompleted;
        else if ([self.run[@"state"] isEqual:@"ended"]) _state.phase = SROpsGroupCancelled;
        else if (inflight && (![self.run[@"state"] isEqual:@"running"] || !self.foreground || !_state.enabled)) _state.phase = SROpsDraining;
        else if ([self.run[@"state"] isEqual:@"running"] && [self.manualRun isEqual:self.run[@"id"]]) _state.phase = SROpsRunning;
        else _state.phase = SROpsPaused;
    }
    self.stateLoaded = YES;
    BOOL blocked = !_state.enabled || !self.foreground || self.requirements.count || self.safetyLatched;
    NSDictionary *active = self.legacyRun ?: self.run;
    if (blocked && [active[@"state"] isEqual:@"running"]) {
        if (!allowPause) return [self fail:error reason:@"Execution port did not persist the requested pause"];
        if (![self.execution pauseForAccount:account error:&failure])
            return [self fail:error reason:failure.localizedDescription ?: @"New dispatch is blocked but pausing could not be persisted"];
        self.manualRun = nil;
        return [self reloadAllowPause:NO error:error];
    }
    if (!configurationLoaded) return [self fail:error reason:@"Saved configuration is unreadable; repair settings before operations can start"];
    if (_state.enabled && self.requirements.count) return [self fail:error reason:@"Saved configuration is incomplete; operations are stopped"];
    if (_state.enabled && self.legacyRun)
        return [self fail:error reason:@"An older active run requires explicit source recovery before operations can capture"];
    if ([self.run[@"state"] isEqual:@"running"] && ![self.manualRun isEqual:self.run[@"id"]])
        return [self fail:error reason:@"Interrupted run requires recovery and manual continuation"];
    return [self updateCapture:error];
}
- (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        (void)[self reloadAllowPause:YES error:NULL];
        if (!self.account.length) return SRRelayFail(failure, @"Current account cannot be verified");
        if (enabled && self.legacyRun) return [self fail:failure reason:@"Recover the older run's source before enabling operations"];
        BOOL stopped = YES;
        if (!enabled) {
            _state.enabled = false; _state.generation++; self.manualRun = nil;
            stopped = [self stopCapture];
            if (self.run || self.legacyRun) [self.execution pauseForAccount:self.account error:NULL];
        }
        if (![self.store setOperationsEnabled:enabled account:self.account error:failure]) return [self fail:failure reason:(*failure).localizedDescription ?: @"Operations preference could not be saved"];
        if (!stopped) return [self fail:failure reason:@"Operations are disabled but capture stop could not be verified"];
        self.requireEnable = NO; self.safetyLatched = NO;
        return [self reloadAllowPause:YES error:failure];
    } error:error];
}
- (BOOL)configurationSaved:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) { return [self reloadAllowPause:YES error:failure]; } error:error];
}
- (BOOL)acceptPreparedEnvelope:(NSDictionary *)envelope generation:(uint64_t)generation
                     createdAt:(NSTimeInterval)createdAt receivedAt:(NSTimeInterval)receivedAt error:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self reloadAllowPause:YES error:failure]) return NO;
        NSTimeInterval now = self.clock();
        if (!self.listening || generation != _state.generation || !SROpsCaptureAllowed(_state) ||
            !SROpsNewMessage(createdAt, self.listeningSince, receivedAt) || !isfinite(now) || receivedAt > now)
            return SRRelayFail(failure, @"Stale, historical or unverified source event");
        NSString *content = [self.store saveOperationsContent:envelope configuration:self.configuration account:self.account capturedAt:receivedAt error:failure];
        if (!content) return [self fail:failure reason:(*failure).localizedDescription ?: @"Prepared source could not be persisted"];
        [self stopCapture]; SROpsApply(&_state, SROpsCandidateCommitted, _state.generation);
        self.commandProblem = nil;
        return [self reloadAllowPause:YES error:failure];
    } error:error];
}
- (BOOL)canControl:(NSError **)error {
    if (![self reloadAllowPause:YES error:error]) return NO;
    if (!SROpsVisible(_state) || _state.fault || !self.content) return SRRelayFail(error, @"Enable operations with ready content in the foreground first");
    return YES;
}
- (BOOL)canResolveContent:(NSError **)error {
    (void)[self reloadAllowPause:YES error:NULL];
    if (!self.stateLoaded || !_state.trusted || !self.foreground || !self.content)
        return SRRelayFail(error, @"Ready account-scoped content in the foreground is required");
    return YES;
}
- (NSArray<NSDictionary *> *)prepareGroups:(NSError **)error {
    __block NSArray *groups = nil;
    BOOL result = [self performCommand:^BOOL(NSError **failure) {
        if (![self canControl:failure]) return NO;
        NSString *plan = [self.store planForOperationsContent:self.content[@"id"] account:self.account error:failure];
        if (!plan || ![self reloadAllowPause:YES error:failure]) {
            self.commandProblem = (*failure).localizedDescription ?: @"Content groups could not be prepared"; return NO;
        }
        groups = [SRSourceMessage frozenJSON:@{@"groups": self.groups}][@"groups"];
        return YES;
    } error:error];
    return result ? groups : nil;
}
- (BOOL)startGroup:(NSString *)frozenRuleID error:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self canControl:failure]) return NO;
        if (self.run && [@[@"running", @"paused", @"awaiting_resume"] containsObject:self.run[@"state"]])
            return SRRelayFail(failure, @"Use pause or continue for the occupied run");
        NSString *plan = [self.store planForOperationsContent:self.content[@"id"] account:self.account error:failure];
        if (!plan) { self.commandProblem = (*failure).localizedDescription ?: @"Content plan could not be prepared"; return NO; }
        NSArray *groups = [self.store ruleCardsForPlan:plan account:self.account error:failure];
        if (!groups) return NO;
        NSDictionary *selected = nil;
        for (NSDictionary *group in groups) if ([group[@"id"] isEqual:frozenRuleID]) selected = group;
        NSUInteger targets = [selected[@"targetCount"] unsignedIntegerValue];
        if (!selected || selected[@"latestRun"] != NSNull.null || !targets || targets > 20)
            return SRRelayFail(failure, @"Select an unstarted frozen group with 1 to 20 targets");
        BOOL result = [self.execution startRule:frozenRuleID account:self.account error:failure];
        NSArray *history = [self.store historyForRule:frozenRuleID account:self.account limit:1 offset:0 error:NULL];
        if (result && !history.firstObject[@"id"]) return [self fail:failure reason:@"Execution port did not persist the started run"];
        if (result) self.manualRun = history.firstObject[@"id"];
        self.commandProblem = result ? nil : ((*failure).localizedDescription ?: @"Group did not start; its plan and paused run are retained");
        BOOL loaded = [self reloadAllowPause:YES error:result ? failure : NULL];
        return result && loaded;
    } error:error];
}
- (BOOL)resume:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self canControl:failure] || !self.run) return NO;
        if (_state.phase != SROpsPaused) return SRRelayFail(failure, @"Only a drained paused run can continue");
        BOOL result = [self.execution resumeRun:self.run[@"id"] account:self.account error:failure];
        NSDictionary *persisted = result ? [self.store summaryForRun:self.run[@"id"] error:failure] : nil;
        if (result && ![@[@"running", @"completed", @"ended"] containsObject:persisted[@"state"]])
            return [self fail:failure reason:@"Execution port did not persist manual continuation"];
        if (result) self.manualRun = self.run[@"id"];
        self.commandProblem = result ? nil : ((*failure).localizedDescription ?: @"The paused run could not continue");
        BOOL loaded = [self reloadAllowPause:YES error:result ? failure : NULL];
        return result && loaded;
    } error:error];
}
- (BOOL)pause:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self canResolveContent:failure] || !self.run) return NO;
        NSString *account = self.account, *run = self.run[@"id"];
        BOOL result = [self.execution pauseForAccount:self.account error:failure];
        self.manualRun = nil;
        (void)[self reloadAllowPause:YES error:NULL];
        if (result && (!self.stateLoaded || !_state.trusted || ![self.account isEqual:account] || ![self.run[@"id"] isEqual:run]))
            return SRRelayFail(failure, @"Pause was accepted, but its account-scoped state could not be reloaded");
        if (result && [self.run[@"state"] isEqual:@"running"]) return [self fail:failure reason:@"Execution port did not persist the requested pause"];
        return result;
    } error:error];
}
- (BOOL)cancel:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self canResolveContent:failure] || !self.run) return NO;
        NSString *account = self.account, *content = self.content[@"id"];
        BOOL result = [self.execution cancelRun:self.run[@"id"] account:self.account error:failure];
        if (result && ![self.store operationsCancellationForRun:self.run[@"id"] account:self.account error:failure].count)
            return [self fail:failure reason:@"Execution port did not persist cancellation"];
        self.manualRun = nil;
        if (result) self.commandProblem = nil;
        (void)[self reloadAllowPause:YES error:NULL];
        if (result && (!self.stateLoaded || !_state.trusted || ![self.account isEqual:account] || ![self.content[@"id"] isEqual:content]))
            return SRRelayFail(failure, @"Cancellation was persisted, but its account-scoped state could not be reloaded");
        return result;
    } error:error];
}
- (BOOL)recoverLegacyRun:(NSString *)run error:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        (void)[self reloadAllowPause:YES error:NULL];
        if (!self.stateLoaded || !_state.trusted || !self.foreground)
            return SRRelayFail(failure, @"Verify and drain the account's older run before recovery");
        NSDictionary *adoption = self.content[@"legacyAdoption"];
        // A repeated upgrade action is not a new manual sending decision. In
        // particular, do not revoke the lease of an already resumed adopted run.
        if ([adoption isKindOfClass:NSDictionary.class] && [adoption[@"run_id"] isEqual:run]) return YES;
        if (![self.legacyRun[@"id"] isEqual:run])
            return SRRelayFail(failure, @"Verify and drain the account's older run before recovery");
        NSString *content = [self.store adoptLegacyOperationsRun:run account:self.account error:failure];
        if (!content) return NO;
        self.safetyLatched = NO; self.commandProblem = nil; self.manualRun = nil;
        (void)[self reloadAllowPause:YES error:NULL];
        return self.stateLoaded && [self.content[@"id"] isEqual:content];
    } error:error];
}
- (BOOL)finishContent:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self canResolveContent:failure]) return NO;
        NSString *account = self.account, *content = self.content[@"id"];
        if (![self.store archiveOperationsContent:content account:account error:failure]) return NO;
        self.commandProblem = nil;
        SROpsApply(&_state, SROpsContentEndCommitted, _state.generation);
        (void)[self reloadAllowPause:YES error:NULL];
        if (!self.stateLoaded || !_state.trusted || ![self.account isEqual:account] || self.content || ![self.recent[@"id"] isEqual:content])
            return SRRelayFail(failure, @"Content was archived, but its account-scoped state could not be reloaded");
        return YES;
    } error:error];
}
- (NSDictionary *)snapshot {
    BOOL trusted = _state.trusted;
    NSString *captureState = _state.fault ? @"fault" : (self.listening ? @"waiting" :
        (_state.occupied ? @"occupied" : (SROpsVisible(_state) && !_state.sourceVerified ? @"source_check_required" : @"inactive")));
    return [SRSourceMessage frozenJSON:@{@"visible": @(SROpsVisible(_state)), @"enabled": @(trusted && _state.enabled), @"phase": @(_state.phase),
        @"captureAllowed": @(SROpsCaptureAllowed(_state)), @"dispatchAllowed": @(SROpsDispatchAllowed(_state)), @"stateLoaded": @(self.stateLoaded && trusted),
        @"captureState": captureState, @"generation": @(_state.generation), @"listening": @(trusted && self.listening),
        @"problem": self.problem ?: self.commandProblem ?: @"", @"requirements": trusted ? self.requirements : @[],
        @"content": trusted && self.content ? self.content : (id)NSNull.null, @"configuration": trusted && self.configuration ? self.configuration : @{},
        @"recent": trusted && self.recent ? self.recent : (id)NSNull.null, @"groups": trusted ? self.groups : @[],
        @"legacyRun": trusted && self.legacyRun ? self.legacyRun : (id)NSNull.null, @"run": trusted && self.run ? self.run : (id)NSNull.null}];
}
@end
