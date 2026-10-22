#import "SRRelayCoordinator.h"
#import "SRStore.h"
#import "SRConfiguration.h"
#import "SRSourceMessage.h"
#import "SROperationsState.h"
#import "SRRuntimeLog.h"
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

static void SRRelayDiagnostic(NSString *event, NSUInteger reasonCode) {
    [SRRuntimeLog.shared record:event facts:@{ @"reasonCode": @(reasonCode) }];
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
    // Re-enabling must not revive an old lease if the safety pause fails.
    self.manualRun = nil;
    [self stopCapture];
    // A port may have persisted a run before throwing, even if it is not loaded yet.
    @try { if (self.account.length) [self.execution pauseForAccount:self.account error:NULL]; }
    @catch (__unused id exception) { }
    return SRRelayFail(error, reason);
}
- (BOOL)performCommand:(BOOL (^)(NSError **))command error:(NSError **)error {
    if (!NSThread.isMainThread || self.mutating) {
        SRRelayDiagnostic(@"operations_command_rejected", 1);
        return SRRelayFail(error, @"Another coordinator command is in progress");
    }
    self.mutating = YES;
    BOOL result = NO; BOOL fault = NO; NSError *failure = nil;
    @try { result = command(&failure); }
    @catch (__unused id exception) {
        fault = YES;
        [self fail:&failure reason:@"Coordinator port failed; operations are stopped"];
    }
    @finally {
        // Host calls can synchronously deliver lifecycle notifications. Apply the
        // latest one before releasing ownership, but never spin on a broken port.
        if (self.lifecyclePending) {
            // A port may have returned success after reentry cleared the lease.
            self.manualRun = nil;
            self.lifecyclePending = NO;
            @try { (void)[self reloadAllowPause:YES error:NULL]; }
            @catch (__unused id exception) {
                fault = YES;
                [self fail:NULL reason:@"Lifecycle recovery failed; operations are stopped"];
            }
            if (self.lifecyclePending) {
                fault = YES;
                self.lifecyclePending = NO;
                [self fail:NULL reason:@"Repeated lifecycle reentry; explicitly enable operations after recovery"];
            }
            result = NO;
            if (!failure) SRRelayFail(&failure, @"Lifecycle changed during the command; sending requires manual continuation");
        }
        self.mutating = NO;
    }
    BOOL hadFailure = failure != nil;
    if (!result && !hadFailure) SRRelayFail(&failure, self.problem ?: self.commandProblem ?: @"Coordinator command did not complete");
    if (error && failure) *error = failure;
    if (!result) {
        BOOL unexpected = fault || !hadFailure;
        SRRelayDiagnostic(unexpected ? @"operations_fault" : @"operations_command_rejected", unexpected ? 2 : 1);
    }
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
            // Use the same durable insertion order as rule history, not a wall
            // clock that can move backwards or give two groups the same time.
            if (!latest || [run[@"creationOrder"] longLongValue] > [latest[@"creationOrder"] longLongValue]) latest = run;
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
    BOOL blocked = SROpsPauseRequired(_state, self.requirements.count == 0, self.lifecyclePending);
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
- (BOOL)matchesAccount:(NSString *)account error:(NSError **)error {
    if (![account isKindOfClass:NSString.class] || !account.length || !_state.trusted || ![self.account isEqual:account])
        return SRRelayFail(error, @"The displayed account is no longer current; reload operations first");
    return YES;
}
- (BOOL)matchesCurrentAccount:(NSString *)account error:(NSError **)error {
    NSString *current = nil;
    @try { current = self.currentAccount(); }
    @catch (__unused id exception) { }
    if (![current isKindOfClass:NSString.class] || !current.length || ![current isEqual:account])
        return SRRelayFail(error, @"The displayed account is no longer current; reload operations first");
    return YES;
}
- (BOOL)matchesRun:(NSString *)run error:(NSError **)error {
    if (![run isKindOfClass:NSString.class] || !run.length || ![self.run[@"id"] isEqual:run])
        return SRRelayFail(error, @"The displayed run is no longer current; reload operations first");
    return YES;
}
- (BOOL)setEnabled:(BOOL)enabled account:(NSString *)account error:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self matchesCurrentAccount:account error:failure]) return NO;
        (void)[self reloadAllowPause:YES error:NULL];
        if (![self matchesAccount:account error:failure]) return NO;
        if (enabled && !self.stateLoaded) return SRRelayFail(failure, @"Reload the account's operations state before enabling");
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
        BOOL result = [self reloadAllowPause:YES error:failure];
        if (result) SRRelayDiagnostic(enabled ? @"operations_enabled" : @"operations_disabled", 0);
        return result;
    } error:error];
}
- (BOOL)configurationSavedForAccount:(NSString *)account error:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self matchesCurrentAccount:account error:failure]) return NO;
        if (![self reloadAllowPause:YES error:failure]) return NO;
        return [self matchesAccount:account error:failure];
    } error:error];
}
- (BOOL)acceptPreparedEnvelope:(NSDictionary *)envelope generation:(uint64_t)generation
                     createdAt:(NSTimeInterval)createdAt receivedAt:(NSTimeInterval)receivedAt error:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        // A delayed capture must not trigger another account's lifecycle writes.
        if (!self.listening || generation != _state.generation || ![envelope isKindOfClass:NSDictionary.class] ||
            ![envelope[@"account"] isKindOfClass:NSString.class] || ![envelope[@"account"] isEqual:self.account])
            return SRRelayFail(failure, @"Stale or unverified capture ownership");
        if (![self matchesCurrentAccount:self.account error:failure]) return NO;
        if (![self reloadAllowPause:YES error:failure]) return NO;
        NSTimeInterval now = self.clock();
        if (!self.listening || generation != _state.generation || !SROpsCaptureAllowed(_state) ||
            !SROpsNewMessage(createdAt, self.listeningSince, receivedAt) || !isfinite(now) || receivedAt > now)
            return SRRelayFail(failure, @"Stale, historical or unverified source event");
        NSString *content = [self.store saveOperationsContent:envelope configuration:self.configuration account:self.account capturedAt:receivedAt error:failure];
        if (!content) return [self fail:failure reason:(*failure).localizedDescription ?: @"Prepared source could not be persisted"];
        [self stopCapture]; SROpsApply(&_state, SROpsCandidateCommitted, _state.generation);
        self.commandProblem = nil;
        BOOL result = [self reloadAllowPause:YES error:failure];
        if (result) SRRelayDiagnostic(@"capture_accepted", 0);
        return result;
    } error:error];
}
- (BOOL)canControlForAccount:(NSString *)account error:(NSError **)error {
    if (![self matchesCurrentAccount:account error:error]) return NO;
    if (![self reloadAllowPause:YES error:error]) return NO;
    if (![self matchesAccount:account error:error]) return NO;
    if (!SROpsVisible(_state) || _state.fault || !self.content) return SRRelayFail(error, @"Enable operations with ready content in the foreground first");
    return YES;
}
- (BOOL)canResolveForAccount:(NSString *)account error:(NSError **)error {
    if (![self matchesCurrentAccount:account error:error]) return NO;
    (void)[self reloadAllowPause:YES error:NULL];
    if (![self matchesAccount:account error:error]) return NO;
    if (!self.stateLoaded || !self.foreground)
        return SRRelayFail(error, @"Readable account-scoped state in the foreground is required");
    return YES;
}
- (NSArray<NSDictionary *> *)prepareGroupsForContent:(NSString *)content account:(NSString *)account error:(NSError **)error {
    __block NSArray *groups = nil;
    BOOL result = [self performCommand:^BOOL(NSError **failure) {
        if (![self canControlForAccount:account error:failure]) return NO;
        if (![self.content[@"id"] isEqual:content]) return SRRelayFail(failure, @"The displayed content is no longer current; reload operations first");
        NSString *plan = [self.store planForOperationsContent:content account:account error:failure];
        if (!plan || ![self reloadAllowPause:YES error:failure]) {
            self.commandProblem = (*failure).localizedDescription ?: @"Content groups could not be prepared"; return NO;
        }
        groups = [SRSourceMessage frozenJSON:@{@"groups": self.groups}][@"groups"];
        SRRelayDiagnostic(@"operations_plan_prepared", 0);
        return YES;
    } error:error];
    return result ? groups : nil;
}
- (BOOL)startGroup:(NSString *)frozenRuleID content:(NSString *)content account:(NSString *)account error:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self canControlForAccount:account error:failure]) return NO;
        if (![self.content[@"id"] isEqual:content]) return SRRelayFail(failure, @"The displayed content is no longer current; reload operations first");
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
        if (result && loaded) SRRelayDiagnostic(@"operations_group_started", 0);
        return result && loaded;
    } error:error];
}
- (BOOL)resumeRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self canControlForAccount:account error:failure] || ![self matchesRun:run error:failure]) return NO;
        if (_state.phase != SROpsPaused) return SRRelayFail(failure, @"Only a drained paused run can continue");
        BOOL result = [self.execution resumeRun:self.run[@"id"] account:self.account error:failure];
        NSDictionary *persisted = result ? [self.store summaryForRun:self.run[@"id"] error:failure] : nil;
        if (result && ![@[@"running", @"completed", @"ended"] containsObject:persisted[@"state"]])
            return [self fail:failure reason:@"Execution port did not persist manual continuation"];
        if (result) self.manualRun = self.run[@"id"];
        self.commandProblem = result ? nil : ((*failure).localizedDescription ?: @"The paused run could not continue");
        BOOL loaded = [self reloadAllowPause:YES error:result ? failure : NULL];
        if (result && loaded) SRRelayDiagnostic(@"operations_group_resumed", 0);
        return result && loaded;
    } error:error];
}
- (BOOL)pauseRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self canResolveForAccount:account error:failure] || ![self matchesRun:run error:failure]) return NO;
        BOOL result = [self.execution pauseForAccount:self.account error:failure];
        self.manualRun = nil;
        (void)[self reloadAllowPause:YES error:NULL];
        if (result && (!self.stateLoaded || !_state.trusted || ![self.account isEqual:account] || ![self.run[@"id"] isEqual:run]))
            return SRRelayFail(failure, @"Pause was accepted, but its account-scoped state could not be reloaded");
        if (result && [self.run[@"state"] isEqual:@"running"]) return [self fail:failure reason:@"Execution port did not persist the requested pause"];
        if (result) SRRelayDiagnostic(@"operations_group_paused", 0);
        return result;
    } error:error];
}
- (BOOL)cancelRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self canResolveForAccount:account error:failure] || ![self matchesRun:run error:failure]) return NO;
        NSString *content = self.content[@"id"];
        BOOL result = [self.execution cancelRun:run account:account error:failure];
        if (result && ![self.store operationsCancellationForRun:run account:account error:failure].count)
            return [self fail:failure reason:@"Execution port did not persist cancellation"];
        self.manualRun = nil;
        if (result) self.commandProblem = nil;
        (void)[self reloadAllowPause:YES error:NULL];
        if (result && (!self.stateLoaded || !_state.trusted || ![self.account isEqual:account] || ![self.content[@"id"] isEqual:content]))
            return SRRelayFail(failure, @"Cancellation was persisted, but its account-scoped state could not be reloaded");
        if (result) SRRelayDiagnostic(@"operations_group_cancelled", 0);
        return result;
    } error:error];
}
- (BOOL)recoverLegacyRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self matchesCurrentAccount:account error:failure]) return NO;
        (void)[self reloadAllowPause:YES error:NULL];
        if (![self matchesAccount:account error:failure]) return NO;
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
        BOOL result = self.stateLoaded && [self.content[@"id"] isEqual:content];
        if (result) SRRelayDiagnostic(@"operations_legacy_recovered", 0);
        return result;
    } error:error];
}
- (BOOL)finishContent:(NSString *)content account:(NSString *)account error:(NSError **)error {
    return [self performCommand:^BOOL(NSError **failure) {
        if (![self canResolveForAccount:account error:failure]) return NO;
        if (![content isKindOfClass:NSString.class] || !content.length)
            return SRRelayFail(failure, @"An explicit displayed content ID is required");
        if ([self.recent[@"id"] isEqual:content]) return YES;
        if (![self.content[@"id"] isEqual:content])
            return SRRelayFail(failure, @"The displayed content is no longer current; reload operations first");
        if (![self.store archiveOperationsContent:content account:account error:failure]) return NO;
        self.commandProblem = nil;
        SROpsApply(&_state, SROpsContentEndCommitted, _state.generation);
        (void)[self reloadAllowPause:YES error:NULL];
        if (!self.stateLoaded || !_state.trusted || ![self.account isEqual:account] || self.content || ![self.recent[@"id"] isEqual:content])
            return SRRelayFail(failure, @"Content was archived, but its account-scoped state could not be reloaded");
        SRRelayDiagnostic(@"operations_content_archived", 0);
        return YES;
    } error:error];
}
- (NSDictionary *)snapshot {
    BOOL trusted = _state.trusted;
    NSString *captureState = _state.fault ? @"fault" : (self.listening ? @"waiting" :
        (_state.occupied ? @"occupied" : (SROpsVisible(_state) && !_state.sourceVerified ? @"source_check_required" : @"inactive")));
    return [SRSourceMessage frozenJSON:@{@"visible": @(SROpsVisible(_state)), @"enabled": @(trusted && _state.enabled), @"phase": @(_state.phase),
        @"account": trusted && self.account ? self.account : (id)NSNull.null,
        @"captureAllowed": @(SROpsCaptureAllowed(_state)), @"dispatchAllowed": @(SROpsDispatchAllowed(_state)), @"stateLoaded": @(self.stateLoaded && trusted),
        @"captureState": captureState, @"generation": @(_state.generation), @"listening": @(trusted && self.listening),
        @"problem": self.problem ?: self.commandProblem ?: @"", @"requirements": trusted ? self.requirements : @[],
        @"content": trusted && self.content ? self.content : (id)NSNull.null, @"configuration": trusted && self.configuration ? self.configuration : @{},
        @"recent": trusted && self.recent ? self.recent : (id)NSNull.null, @"groups": trusted ? self.groups : @[],
        @"legacyRun": trusted && self.legacyRun ? self.legacyRun : (id)NSNull.null, @"run": trusted && self.run ? self.run : (id)NSNull.null}];
}
@end
