#import "SRRunner.h"
#import "SRStore.h"
#import "SRPacing.h"
#include <math.h>

static const void *SRRunnerQueueKey = &SRRunnerQueueKey;
static NSMapTable *SROwners(void) {
    static NSMapTable *owners; static dispatch_once_t once;
    dispatch_once(&once, ^{ owners = [NSMapTable strongToWeakObjectsMapTable]; });
    return owners;
}

@interface SRRunner () {
    dispatch_queue_t _queue;
    SRPacing _pacing;
    SRStore *_store;
    id<SRSendTransport> _transport;
    double (^_clock)(void);
    double (^_random)(void);
    BOOL (^_environment)(void);
    NSString *_run;
    NSString *_account;
    NSDictionary *_snapshot;
    NSDictionary *_inflight;
    double _deadline;
    BOOL _halted;
    NSString *_problem;
}
@end

@implementation SRRunner
- (instancetype)initWithStore:(SRStore *)store transport:(id<SRSendTransport>)transport
                        clock:(double (^)(void))clock random:(double (^)(void))random environmentAllowed:(BOOL (^)(void))environment {
    self = [super init];
    if (self) {
        _store = store; _transport = transport; _clock = [clock copy]; _random = [random copy]; _environment = [environment copy];
        _queue = dispatch_queue_create("andyz.syncrelay.runner", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, SRRunnerQueueKey, (__bridge void *)self, NULL);
        _halted = YES;
    }
    return self;
}
- (void)sync:(dispatch_block_t)block {
    if (dispatch_get_specific(SRRunnerQueueKey) == (__bridge void *)self) block();
    else dispatch_sync(_queue, block);
}
- (NSUInteger)count:(NSString *)state summary:(NSDictionary *)summary {
    for (NSDictionary *row in summary[@"counts"]) if ([row[@"state"] isEqual:state]) return [row[@"count"] unsignedIntegerValue];
    return 0;
}
- (BOOL)ready {
    @try { return _environment() && [_transport canSendForAccount:_account]; }
    @catch (__unused NSException *exception) { return NO; }
}
- (void)releaseOwner {
    @synchronized(SROwners()) { if ([SROwners() objectForKey:_account] == self) [SROwners() removeObjectForKey:_account]; }
}
- (void)halt:(NSString *)reason {
    _halted = YES; _problem = reason;
    if (_run) {
        NSDictionary *summary = [_store summaryForRun:_run error:NULL];
        if ([summary[@"state"] isEqual:@"running"]) [_store pauseRun:_run error:NULL];
    }
}
- (BOOL)activateRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    __block BOOL result = NO; __block NSError *failure = nil;
    [self sync:^{
        NSString *reason = nil;
        NSDictionary *summary = [self->_store summaryForRun:run error:&failure];
        if (!summary) return;
        if (![summary[@"account"] isEqual:account]) reason = @"Account does not own this run";
        else if (self->_run && ![self->_run isEqual:run]) reason = @"End the current run before attaching another";
        else if (![@[@"running", @"paused", @"awaiting_resume"] containsObject:summary[@"state"]]) reason = @"Run is already terminal";
        else if ([self count:@"uncertain" summary:summary] ||
                 ([self count:@"submitting" summary:summary] && !self->_inflight)) reason = @"Reconcile interrupted deliveries before continuing";
        SRPacing pacing = {0};
        if (!reason && (!SRPacingConfigure(&pacing, [summary[@"minimum"] doubleValue], [summary[@"maximum"] doubleValue]) ||
                        !SRPacingResume(&pacing, self->_clock(), self->_random()))) reason = @"Invalid pacing input";
        NSDictionary *snapshot = [NSJSONSerialization JSONObjectWithData:[summary[@"snapshot"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if (![snapshot isKindOfClass:NSDictionary.class]) reason = @"Invalid source snapshot";
        else {
            for (NSString *key in @[@"account", @"group", @"sender", @"messageID", @"type"]) {
                if (![snapshot[key] isKindOfClass:NSString.class] || ![snapshot[key] length]) reason = @"Incomplete normalized source snapshot";
            }
            if (![snapshot[@"account"] isEqual:account] || ![snapshot[@"generatedByRelay"] isEqual:@NO] ||
                ![@[@"text", @"image"] containsObject:snapshot[@"type"]] || ![snapshot[@"payload"] isKindOfClass:NSDictionary.class]) reason = @"Source snapshot is not eligible for dispatch";
        }
        if (!reason) {
            @try { if (!self->_environment() || ![self->_transport canSendForAccount:account]) reason = @"Transport/account/environment is not ready"; }
            @catch (__unused NSException *exception) { reason = @"Transport readiness failed"; }
        }
        if (!reason) {
            @synchronized(SROwners()) {
                id owner = [SROwners() objectForKey:account];
                if (owner && owner != self) reason = @"Another runner owns this account";
                else [SROwners() setObject:self forKey:account];
            }
        }
        if (reason) {
            failure = [NSError errorWithDomain:@"SyncRelay.Runner" code:1 userInfo:@{NSLocalizedDescriptionKey: reason}]; return;
        }
        if (![summary[@"state"] isEqual:@"running"] && ![self->_store resumeRun:run error:&failure]) {
            @synchronized(SROwners()) { if ([SROwners() objectForKey:account] == self && !self->_run) [SROwners() removeObjectForKey:account]; }
            return;
        }
        self->_run = [run copy]; self->_account = [account copy]; self->_snapshot = snapshot;
        self->_pacing = pacing; self->_halted = NO; self->_problem = nil; result = YES;
    }];
    if (error && failure) *error = failure;
    return result;
}
- (void)recordDelivery:(NSDictionary *)delivery run:(NSString *)run state:(NSString *)state messageID:(NSString *)messageID reason:(NSString *)reason {
    BOOL current = [_run isEqual:run] && [_inflight[@"attempt_id"] isEqual:delivery[@"attempt_id"]];
    if (![@[@"confirmed", @"failed", @"uncertain"] containsObject:state] ||
        ([state isEqual:@"confirmed"] && (![messageID isKindOfClass:NSString.class] || !messageID.length))) {
        state = @"uncertain"; messageID = nil; reason = @"Unusable transport result";
    }
    NSError *error = nil;
    if (![_store recordResultForDelivery:delivery[@"id"] attempt:delivery[@"attempt_id"] state:state messageID:messageID reason:reason error:&error]) {
        if (current) [self halt:error.localizedDescription];
        return;
    }
    if (![_run isEqual:run]) return; // History updates never drive a different run.
    if (current) _inflight = nil;
    if (current && [state isEqual:@"uncertain"]) { [self halt:@"Delivery result is uncertain; reconcile before continuing"]; return; }
    NSDictionary *summary = [_store summaryForRun:run error:&error];
    if (!summary) { [self halt:error.localizedDescription]; return; }
    if ([summary[@"state"] isEqual:@"completed"]) {
        [self releaseOwner]; _run = nil; _halted = YES; _problem = nil;
    } else if (current && ![self count:@"pending" summary:summary]) {
        [self halt:@"Batch has exceptions; review and explicitly end it"];
    }
}
- (BOOL)tick {
    __block BOOL submitted = NO;
    [self sync:^{
        if (!self->_run) return;
        double now = self->_clock();
        if (!isfinite(now)) { [self halt:@"Invalid monotonic clock"]; return; }
        // Timeout is checked even while paused; elapsed time never implies safe retry.
        if (self->_inflight && now >= self->_deadline) {
            NSDictionary *delivery = self->_inflight;
            [self recordDelivery:delivery run:self->_run state:@"uncertain" messageID:nil reason:@"Confirmation timeout"];
            return;
        }
        if (self->_halted) return;
        if (![self ready]) { [self halt:@"Account or execution environment changed"]; return; }
        if (self->_inflight || !SRPacingReady(&self->_pacing, now)) return;
        NSError *error = nil;
        NSDictionary *summary = [self->_store summaryForRun:self->_run error:&error];
        if (!summary) { [self halt:error.localizedDescription]; return; }
        if (![@[@"running", @"paused", @"awaiting_resume"] containsObject:summary[@"state"]]) {
            [self releaseOwner]; self->_run = nil; self->_halted = YES; return;
        }
        if (![summary[@"state"] isEqual:@"running"]) { [self halt:@"Manual continuation required"]; return; }
        SRPacing next = self->_pacing;
        if (!SRPacingSubmitted(&next, now, self->_random())) { [self halt:@"Invalid random interval"]; return; }
        NSDictionary *delivery = [self->_store claimNextForRun:self->_run error:&error];
        if (!delivery) { [self halt:error.localizedDescription ?: @"No pending deliveries; review the batch"]; return; }
        self->_pacing = next; self->_inflight = delivery; self->_deadline = now + 60.0;
        NSString *run = self->_run;
        __weak typeof(self) weakSelf = self;
        @try {
            [self->_transport submitDelivery:delivery snapshot:self->_snapshot completion:^(NSString *state, NSString *messageID, NSString *reason) {
                SRRunner *runner = weakSelf;
                if (!runner) return;
                NSString *outcome = [state copy], *identifier = [messageID copy], *detail = [reason copy];
                dispatch_async(runner->_queue, ^{ [runner recordDelivery:delivery run:run state:outcome messageID:identifier reason:detail]; });
            }];
            submitted = YES;
        } @catch (__unused NSException *exception) {
            [self recordDelivery:delivery run:run state:@"uncertain" messageID:nil reason:@"Transport threw during submission"];
        }
    }];
    return submitted;
}
- (BOOL)pause:(NSError **)error {
    __block BOOL success = NO; __block NSError *failure = nil;
    [self sync:^{
        self->_halted = YES;
        if (!self->_run) return;
        NSDictionary *summary = [self->_store summaryForRun:self->_run error:&failure];
        success = [summary[@"state"] isEqual:@"paused"] || [summary[@"state"] isEqual:@"awaiting_resume"];
        if ([summary[@"state"] isEqual:@"running"]) success = [self->_store pauseRun:self->_run error:&failure];
    }];
    if (error && failure) *error = failure;
    return success;
}
- (BOOL)end:(NSError **)error {
    __block BOOL success = NO; __block NSError *failure = nil;
    [self sync:^{
        self->_halted = YES;
        if (!self->_run) return;
        NSDictionary *summary = [self->_store summaryForRun:self->_run error:&failure];
        if ([@[@"completed", @"ended"] containsObject:summary[@"state"]]) success = YES;
        else if (summary) success = [self->_store endRun:self->_run error:&failure];
        if (success) { [self releaseOwner]; self->_run = nil; self->_inflight = nil; }
    }];
    if (error && failure) *error = failure;
    return success;
}
- (NSDictionary *)status {
    __block NSDictionary *result;
    [self sync:^{ result = @{@"run": self->_run ?: (id)NSNull.null, @"halted": @(self->_halted),
        @"inflight": @(self->_inflight != nil), @"nextMonotonic": @(self->_pacing.next_monotonic), @"problem": self->_problem ?: @""}; }];
    return result;
}
@end
