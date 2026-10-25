#import <Foundation/Foundation.h>
#import "Adapter/SRSourceTimeProbe.h"
#import "Adapter/SRWeChatReceiver.h"
#import "Core/SRConfiguration.h"
#include <assert.h>
#include <math.h>
#define CHECK(...) assert((__VA_ARGS__))

@interface TimeProbeWrap : NSObject
@property(nonatomic, copy) NSString *m_nsFromUsr;
@property(nonatomic, copy) NSString *m_nsToUsr;
@property(nonatomic, copy) NSString *m_nsRealChatUsr;
@property(nonatomic, copy) NSString *m_nsContent;
@property(nonatomic) unsigned int m_uiMessageType;
@property(nonatomic) unsigned long long m_n64MesSvrID;
@property(nonatomic) unsigned int m_uiMesLocalID;
@end
@implementation TimeProbeWrap
@end
@interface IntegerTimeWrap : TimeProbeWrap
@property(nonatomic) unsigned long long m_uiCreateTime;
@end
@implementation IntegerTimeWrap
@end
@interface FloatingTimeWrap : TimeProbeWrap
- (double)m_uiCreateTime;
@end
@implementation FloatingTimeWrap
- (double)m_uiCreateTime { abort(); }
@end

@interface TimeProbeManager : NSObject
@property(nonatomic) NSUInteger originalCalls;
@property(nonatomic, copy) void (^duringOriginal)(void);
@property(nonatomic) BOOL throws;
@property(nonatomic, strong) TimeProbeWrap *stored;
@property(nonatomic, copy) NSString *lookupGroup;
@property(nonatomic) unsigned int lookupLocalID;
- (void)AsyncOnAddMsg:(id)session MsgWrap:(id)wrap;
- (void)AddMsg:(id)session MsgWrap:(id)wrap;
- (id)GetMsg:(NSString *)group LocalID:(unsigned int)localID;
@end
@implementation TimeProbeManager
- (void)AsyncOnAddMsg:(__unused id)session MsgWrap:(__unused id)wrap {
    self.originalCalls++;
    if (self.duringOriginal) self.duringOriginal();
    if (self.throws) @throw @"private original exception";
}
- (void)AddMsg:(id)session MsgWrap:(id)wrap { [self AsyncOnAddMsg:session MsgWrap:wrap]; }
- (id)GetMsg:(NSString *)group LocalID:(unsigned int)localID {
    self.lookupGroup = group; self.lookupLocalID = localID; return self.stored;
}
@end

@interface TimeProbeFixture : NSObject
@property(nonatomic, strong) SRWeChatReceiver *receiver;
@property(nonatomic, strong) SRSourceTimeProbe *probe;
@property(nonatomic, strong) TimeProbeManager *manager;
@property(nonatomic, copy) NSString *current;
@property(nonatomic, copy) NSDictionary *configuration;
@property(nonatomic) BOOL allowed;
@property(nonatomic) BOOL contextThrows;
@property(nonatomic) double wall;
@property(nonatomic) double monotonic;
@property(nonatomic) NSUInteger legacyCalls;
@property(nonatomic) NSUInteger changes;
@property(nonatomic, copy) void (^onChange)(void);
@property(nonatomic, copy) void (^onReceiverAccountRead)(void);
@property(nonatomic, copy) void (^onMonotonicRead)(void);
- (instancetype)initWithWrapClass:(Class)type;
- (BOOL)start;
- (void)stop;
@end
@implementation TimeProbeFixture
- (instancetype)initWithWrapClass:(Class)type {
    self = [super init];
    if (self) {
        _current = @"wxid_time_private"; _wall = 2000.5; _monotonic = 10; _allowed = YES;
        NSMutableDictionary *draft = [SRConfiguration emptyDraft];
        draft[@"sourceGroup"] = @{@"id": @"private_source@chatroom", @"name": @"private source name"};
        draft[@"senders"] = @[@{@"id": _current, @"name": @"private self name"}, @{@"id": @"wxid_other_private", @"name": @"private other name"}];
        _configuration = draft; _manager = [TimeProbeManager new];
        __weak typeof(self) weakSelf = self;
        Class (^resolver)(NSString *) = ^Class(NSString *name) {
            return [name isEqual:@"CMessageMgr"] ? TimeProbeManager.class : ([name isEqual:@"CMessageWrap"] ? type : Nil);
        };
        _receiver = [[SRWeChatReceiver alloc] initWithVersion:@"8.0.79" classResolver:resolver
            currentAccount:^NSString * {
                CHECK(NSThread.isMainThread);
                if (weakSelf.onReceiverAccountRead) weakSelf.onReceiverAccountRead();
                return weakSelf.current;
            }
            received:^(__unused NSDictionary *message) { abort(); } clock:^double { return weakSelf.wall; }];
        _receiver.prepareImage = ^NSDictionary *(__unused id wrap, __unused NSDictionary *source, __unused NSError **error) { abort(); };
        _receiver.discardImage = ^(__unused NSDictionary *payload) { abort(); };
        _probe = [[SRSourceTimeProbe alloc] initWithReceiver:_receiver classResolver:resolver
            currentAccount:^NSString * {
                CHECK(NSThread.isMainThread);
                if (weakSelf.contextThrows) @throw @"private context exception";
                return weakSelf.current;
            } configurationForAccount:^NSDictionary *(__unused NSString *account) { return weakSelf.configuration; }
            environmentAllowed:^BOOL { return weakSelf.allowed; }
            monotonicClock:^double {
                double now = weakSelf.monotonic;
                if (weakSelf.onMonotonicRead) weakSelf.onMonotonicRead();
                return now;
            } wallClock:^double { return weakSelf.wall; }
            legacyReceived:^(__unused NSDictionary *message) { weakSelf.legacyCalls++; }
            changed:^{ CHECK(NSThread.isMainThread); weakSelf.changes++; if (weakSelf.onChange) weakSelf.onChange(); }];
    }
    return self;
}
- (BOOL)start { return [self.probe startForAccount:self.current configuration:self.configuration error:NULL]; }
- (void)stop { [self.probe stopForReason:SRSourceTimeProbeUserStopped]; [self.receiver stop]; }
@end

static void pump(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false); }
static void runMainLoopFor(NSTimeInterval duration) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:duration];
    while (YES) {
        NSTimeInterval remaining = [deadline timeIntervalSinceNow];
        if (remaining <= 0) break;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, fmin(remaining, 0.05), false);
    }
}
static BOOL waitForCondition(NSTimeInterval timeout, BOOL (^condition)(void)) {
    // Poll in bounded slices so a slow CI runner cannot turn a positive wait
    // into a fixed-time assertion, while still failing at a known deadline.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition()) {
        NSTimeInterval remaining = [deadline timeIntervalSinceNow];
        if (remaining <= 0) return NO;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, fmin(remaining, 0.05), false);
    }
    return YES;
}
static IntegerTimeWrap *message(unsigned long long created) {
    IntegerTimeWrap *wrap = [IntegerTimeWrap new];
    wrap.m_nsFromUsr = @"private_source@chatroom"; wrap.m_nsToUsr = @"wxid_time_private";
    wrap.m_nsRealChatUsr = @"wxid_other_private"; wrap.m_nsContent = @"private body and XML never in report";
    wrap.m_uiMessageType = 1; wrap.m_n64MesSvrID = 9007199254740993ULL;
    wrap.m_uiMesLocalID = 42; wrap.m_uiCreateTime = created; return wrap;
}
static void receive(TimeProbeFixture *fixture, TimeProbeWrap *wrap) {
    [fixture.manager AsyncOnAddMsg:@"private_source@chatroom" MsgWrap:wrap]; pump();
}
static NSDictionary *last(TimeProbeFixture *fixture) { return [fixture.probe.diagnostics[@"samples"] lastObject]; }
static NSUInteger count(TimeProbeFixture *fixture) { return [fixture.probe.diagnostics[@"samples"] count]; }
static void privateReport(TimeProbeFixture *fixture) {
    NSDictionary *report = fixture.probe.diagnostics;
    CHECK([NSJSONSerialization isValidJSONObject:report]);
    NSString *text = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL] encoding:NSUTF8StringEncoding];
    for (NSString *secret in @[@"wxid_time_private", @"wxid_other_private", @"private_source@chatroom", @"private body", @"private source name",
        @"private self name", @"9007199254740993", @"private context exception", @"private original exception", @"private clock exception", @"payload", @"messageID"])
        CHECK(![text containsString:secret]);
    for (NSString *key in @[@"sourceTimeSemanticsVerified", @"imageReadinessObserved", @"sendingEnabled"])
        CHECK([report[key] isEqual:@NO]);
    CHECK([report[@"actualWrapABIObserved"] boolValue] == ([report[@"hookSamples"] count] > 0));
    CHECK([report[@"prefilteredCallbacksObserved"] boolValue] == ([report[@"hookSamples"] count] > 0));
}

static void checkObservation(void) {
    TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
    CHECK(!fixture.probe.active && [fixture.probe.diagnostics[@"state"] isEqual:@"off"]);
    receive(fixture, message(2000)); CHECK(fixture.manager.originalCalls == 1 && count(fixture) == 0 && fixture.legacyCalls == 0);
    fixture.allowed = NO; CHECK(![fixture start]); fixture.allowed = YES;
    fixture.contextThrows = YES; CHECK(![fixture start]); fixture.contextThrows = NO;
    CHECK(![fixture.probe startForAccount:@"wxid_wrong" configuration:fixture.configuration error:NULL]);
    fixture.monotonic = NAN; CHECK(![fixture start]); fixture.monotonic = 10;
    CHECK([fixture start]); CHECK(![fixture start]);
    CHECK([fixture.receiver.diagnostics[@"textOnlyCandidate"] boolValue] && ![fixture.receiver.diagnostics[@"newMessagesOnly"] boolValue]);
    CHECK([fixture.probe.diagnostics[@"getterDeclaredReturnEncoding"] isEqual:@"Q"]);
    CHECK([fixture.probe.diagnostics[@"getterDeclarationScope"] isEqual:@"configured_wrap_class"]);
    __block BOOL backgroundStart = YES;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        backgroundStart = [fixture start]; dispatch_semaphore_signal(done);
    });
    CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0 && !backgroundStart);
    fixture.wall = 2001.25;
    __weak TimeProbeFixture *weakFixture = fixture;
    fixture.manager.duringOriginal = ^{ weakFixture.wall = 2010; };
    IntegerTimeWrap *wrap = message(2001); receive(fixture, wrap); fixture.manager.duringOriginal = nil;
    CHECK(count(fixture) == 1 && fixture.legacyCalls == 0);
    CHECK([last(fixture)[@"createdAt"] isEqual:@2001] && [last(fixture)[@"receivedAt"] isEqual:@2001.25]);
    CHECK([last(fixture)[@"listeningSince"] isEqual:@2000.5] && [last(fixture)[@"deliveredAt"] isEqual:@2010]);
    CHECK([last(fixture)[@"relationship"] isEqual:@"after_boundary"] && [last(fixture)[@"strictPolicyWouldAccept"] boolValue]);
    receive(fixture, wrap); CHECK(count(fixture) == 2 && [last(fixture)[@"messageOrdinal"] isEqual:@1]);
    wrap = message(1990); wrap.m_n64MesSvrID++; receive(fixture, wrap);
    CHECK([last(fixture)[@"relationship"] isEqual:@"older_than_boundary"] && ![last(fixture)[@"strictPolicyWouldAccept"] boolValue]);
    receive(fixture, message(2000)); CHECK([last(fixture)[@"relationship"] isEqual:@"same_second"]);
    receive(fixture, message(3000)); CHECK([last(fixture)[@"relationship"] isEqual:@"future_or_different_units"]);
    receive(fixture, message(0)); CHECK(last(fixture)[@"createdAt"] == NSNull.null);
    receive(fixture, message(9007199254740993ULL)); CHECK(last(fixture)[@"createdAt"] == NSNull.null);
    NSUInteger before = count(fixture);
    wrap = message(2005); wrap.m_uiMessageType = 3; receive(fixture, wrap);
    wrap = message(2005); wrap.m_nsRealChatUsr = @"wxid_unselected"; receive(fixture, wrap);
    wrap = message(2005); wrap.m_nsFromUsr = @"wrong@chatroom"; receive(fixture, wrap);
    wrap = message(2005); wrap.m_n64MesSvrID = 0; receive(fixture, wrap);
    CHECK(count(fixture) == before && [fixture.receiver.diagnostics[@"imageReads"] isEqual:@0]);
    fixture.manager.throws = YES; BOOL propagated = NO;
    @try { [fixture.manager AsyncOnAddMsg:@"private_source@chatroom" MsgWrap:message(2005)]; }
    @catch (id exception) { propagated = [exception isEqual:@"private original exception"]; }
    CHECK(propagated); fixture.manager.throws = NO; pump(); CHECK(count(fixture) == before);
    privateReport(fixture);
    [fixture.probe stopForReason:SRSourceTimeProbeUserStopped];
    CHECK(!fixture.probe.active && ![fixture.receiver.diagnostics[@"armed"] boolValue]);
    receive(fixture, message(2005)); CHECK(count(fixture) == before);
    fixture.wall = 2000.5; // A repeated wall time must not swallow legacy capture.
    CHECK([fixture.receiver armForAccount:fixture.current sourceGroup:@"private_source@chatroom" error:NULL]);
    receive(fixture, message(2019)); CHECK(fixture.legacyCalls == 1 && count(fixture) == before);
    [fixture stop];
}

static void checkOwnAndGeneration(void) {
    TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
    CHECK([fixture start]); fixture.wall = 2002.5;
    IntegerTimeWrap *own = message(2002); own.m_nsFromUsr = fixture.current;
    own.m_nsToUsr = @"private_source@chatroom"; own.m_nsRealChatUsr = nil; own.m_n64MesSvrID = 0;
    [fixture.manager AddMsg:@"private_source@chatroom" MsgWrap:own]; pump(); CHECK(count(fixture) == 0);
    IntegerTimeWrap *settled = message(2002); settled.m_nsFromUsr = fixture.current;
    settled.m_nsToUsr = @"private_source@chatroom"; settled.m_nsRealChatUsr = nil;
    settled.m_n64MesSvrID = 9007199254740994ULL;
    fixture.manager.stored = settled; fixture.wall = 2020;
    CHECK(waitForCondition(5, ^{ return (BOOL)(count(fixture) == 1); }));
    CHECK([last(fixture)[@"selfSource"] boolValue]);
    CHECK([last(fixture)[@"createdAt"] isEqual:@2002] && [last(fixture)[@"receivedAt"] isEqual:@2002.5]);
    CHECK([last(fixture)[@"deliveredAt"] isEqual:@2020]);
    CHECK([last(fixture)[@"hookMessageOrdinal"] isEqual:@1]);
    CHECK([fixture.manager.lookupGroup isEqual:@"private_source@chatroom"] && fixture.manager.lookupLocalID == 42);
    NSDictionary *oldEvidence = @{@"schema": @1, @"generation": last(fixture)[@"receiverGeneration"],
        @"createdAt": @2002, @"receivedAt": @2002.5, @"listeningSince": @2000.5};
    [fixture.probe stopForReason:SRSourceTimeProbeUserStopped];
    fixture.receiver.receivedWithTimeEvidence(@{}, oldEvidence); CHECK(fixture.legacyCalls == 0);
    fixture.wall = 3000.5; CHECK([fixture start]);
    fixture.receiver.receivedWithTimeEvidence(@{}, oldEvidence); CHECK(count(fixture) == 0);
    own.m_n64MesSvrID = 0; own.m_uiCreateTime = 3001; fixture.wall = 3001.5;
    [fixture.manager AddMsg:@"private_source@chatroom" MsgWrap:own]; pump();
    // A text delivery already queued on main and an own-ID poll must both die.
    [fixture.manager AsyncOnAddMsg:@"private_source@chatroom" MsgWrap:message(3001)];
    [fixture.probe stopForReason:SRSourceTimeProbeUserStopped]; fixture.wall = 3002.5; CHECK([fixture start]);
    own.m_n64MesSvrID = 123; runMainLoopFor(1.1);
    CHECK(count(fixture) == 0 && fixture.legacyCalls == 0 && [fixture.probe.diagnostics[@"round"] isEqual:@3]);
    fixture.wall = 3003.5; receive(fixture, message(3003)); CHECK(count(fixture) == 1);
    privateReport(fixture); [fixture stop];
}

static void checkReadbackCorrelationRejectsMismatch(void) {
    // Exact local ID, account, group, type and body must all still match.
    TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
    CHECK([fixture start]); fixture.wall = 2102.5;
    IntegerTimeWrap *own = message(2102); own.m_nsFromUsr = fixture.current;
    own.m_nsToUsr = @"private_source@chatroom"; own.m_nsRealChatUsr = nil; own.m_n64MesSvrID = 0;
    [fixture.manager AddMsg:@"private_source@chatroom" MsgWrap:own]; pump();
    NSDictionary *hook = [fixture.probe.diagnostics[@"hookSamples"] lastObject];
    CHECK([hook[@"messageOrdinal"] isEqual:@1] && [hook[@"correlationScope"] isEqual:@"local"]);
    IntegerTimeWrap *settled = message(2102); settled.m_nsFromUsr = fixture.current;
    settled.m_nsToUsr = @"private_source@chatroom"; settled.m_nsRealChatUsr = nil;
    settled.m_n64MesSvrID = 9007199254740995ULL; fixture.manager.stored = settled;
    fixture.wall = 2120;
    CHECK(waitForCondition(5, ^{ return (BOOL)(count(fixture) == 1); }));
    CHECK([last(fixture)[@"hookMessageOrdinal"] isEqual:@1]);
    [fixture stop];
    fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
    CHECK([fixture start]); fixture.wall = 2152.5;
    own = message(2152); own.m_nsFromUsr = fixture.current;
    own.m_nsToUsr = @"private_source@chatroom"; own.m_nsRealChatUsr = nil; own.m_n64MesSvrID = 0;
    [fixture.manager AddMsg:@"private_source@chatroom" MsgWrap:own]; pump();
    settled = message(2152); settled.m_nsFromUsr = fixture.current;
    settled.m_nsToUsr = @"private_source@chatroom"; settled.m_nsRealChatUsr = nil;
    settled.m_n64MesSvrID = 9007199254740997ULL; fixture.manager.stored = settled;
    fixture.receiver.observeTimeHook = nil;
    fixture.wall = 2170;
    CHECK(waitForCondition(5, ^{ return (BOOL)(count(fixture) == 1); }));
    CHECK(last(fixture)[@"hookMessageOrdinal"] == NSNull.null);
    [fixture stop];
    fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
    CHECK([fixture start]); fixture.wall = 2182.5;
    own = message(2182); own.m_nsFromUsr = fixture.current;
    own.m_nsToUsr = @"private_source@chatroom"; own.m_nsRealChatUsr = nil; own.m_n64MesSvrID = 0;
    // Remove the early hook first: a local ID alone must not invent an ordinal.
    fixture.receiver.observeTimeHook = nil;
    [fixture.manager AddMsg:@"private_source@chatroom" MsgWrap:own]; pump();
    CHECK([fixture.probe.diagnostics[@"hookSamples"] count] == 0);
    settled = message(2182); settled.m_nsFromUsr = fixture.current;
    settled.m_nsToUsr = @"private_source@chatroom"; settled.m_nsRealChatUsr = nil;
    settled.m_n64MesSvrID = 9007199254740998ULL; fixture.manager.stored = settled;
    fixture.wall = 2200;
    CHECK(waitForCondition(5, ^{ return (BOOL)(count(fixture) == 1); }));
    CHECK(last(fixture)[@"hookMessageOrdinal"] == NSNull.null);
    [fixture stop];

    NSArray *mutations = @[
        ^(IntegerTimeWrap *stored, __unused TimeProbeFixture *fixture) { stored.m_uiMesLocalID = 99; },
        ^(IntegerTimeWrap *stored, __unused TimeProbeFixture *fixture) { stored.m_nsToUsr = @"wrong@chatroom"; },
        ^(IntegerTimeWrap *stored, __unused TimeProbeFixture *fixture) { stored.m_nsFromUsr = @"wxid_wrong"; },
        ^(IntegerTimeWrap *stored, __unused TimeProbeFixture *fixture) { stored.m_uiMessageType = 3; },
        ^(IntegerTimeWrap *stored, __unused TimeProbeFixture *fixture) { stored.m_nsContent = @"different body"; },
    ];
    for (void (^mutate)(IntegerTimeWrap *, TimeProbeFixture *) in mutations) {
        fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
        CHECK([fixture start]); fixture.wall = 2202.5;
        own = message(2202); own.m_nsFromUsr = fixture.current;
        own.m_nsToUsr = @"private_source@chatroom"; own.m_nsRealChatUsr = nil; own.m_n64MesSvrID = 0;
        [fixture.manager AddMsg:@"private_source@chatroom" MsgWrap:own]; pump();
        settled = message(2202); settled.m_nsFromUsr = fixture.current;
        settled.m_nsToUsr = @"private_source@chatroom"; settled.m_nsRealChatUsr = nil;
        settled.m_n64MesSvrID = 9007199254740996ULL; mutate(settled, fixture);
        fixture.manager.stored = settled; fixture.wall = 2220;
        runMainLoopFor(1.1);
        CHECK(count(fixture) == 0);
        [fixture stop];
    }
}

static void checkMetadataAndClocks(void) {
    TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
    CHECK([fixture start]); fixture.wall = 2001.5; receive(fixture, message(2001));
    NSMutableDictionary *evidence = [@{@"schema": @1, @"generation": last(fixture)[@"receiverGeneration"],
        @"createdAt": @2002, @"receivedAt": @2002.5, @"listeningSince": @2000.5, @"privateXML": @"secret"} mutableCopy];
    NSMutableDictionary *envelope = [@{@"account": fixture.current, @"group": @"private_source@chatroom", @"sender": @"wxid_other_private",
        @"messageID": @"svr:9007199254740993", @"type": @"text", @"generatedByRelay": @NO, @"payload": @"secret"} mutableCopy];
    // Synthetic consumer-boundary checks, not additional host observations.
    for (NSDictionary *change in @[@{@"schema": @2}, @{@"generation": @9999}, @{@"receivedAt": @(NAN)},
        @{@"listeningSince": @1000}, @{@"generation": NSNull.null}]) {
        NSMutableDictionary *invalid = [evidence mutableCopy]; [invalid addEntriesFromDictionary:change];
        fixture.receiver.receivedWithTimeEvidence(envelope, invalid);
    }
    for (NSDictionary *change in @[@{@"account": @"wrong"}, @{@"group": @"wrong@chatroom"}, @{@"sender": @"wrong"},
        @{@"type": @"image"}, @{@"generatedByRelay": @YES}, @{@"messageID": @""}]) {
        NSMutableDictionary *invalid = [envelope mutableCopy]; [invalid addEntriesFromDictionary:change];
        fixture.receiver.receivedWithTimeEvidence(invalid, evidence);
    }
    CHECK(count(fixture) == 1 && fixture.legacyCalls == 0);
    fixture.wall = 2001.25;
    fixture.receiver.receivedWithTimeEvidence(envelope, evidence);
    CHECK(count(fixture) == 2 && [last(fixture)[@"deliveryClockRollback"] boolValue] && ![last(fixture)[@"strictPolicyWouldAccept"] boolValue]);
    evidence[@"receivedAt"] = @1999.5; evidence[@"createdAt"] = @1999;
    fixture.receiver.receivedWithTimeEvidence(envelope, evidence);
    CHECK([last(fixture)[@"relationship"] isEqual:@"receive_clock_rollback"] && ![last(fixture)[@"strictPolicyWouldAccept"] boolValue]);
    privateReport(fixture); [fixture stop];
}

static void checkReentrantRestart(void) {
    TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
    CHECK([fixture start]); fixture.wall = 2001.5; receive(fixture, message(2001));
    NSDictionary *evidence = @{@"schema": @1, @"generation": last(fixture)[@"receiverGeneration"],
        @"createdAt": @2001, @"receivedAt": @2001.5, @"listeningSince": @2000.5};
    NSDictionary *envelope = @{@"account": fixture.current, @"group": @"private_source@chatroom", @"sender": @"wxid_other_private",
        @"messageID": @"svr:9007199254740993", @"type": @"text", @"generatedByRelay": @NO};
    NSMutableDictionary *changed = [fixture.configuration mutableCopy]; changed[@"maximum"] = @12; fixture.configuration = changed;
    fixture.wall = 2000.5; // Mock rollback: a new arm can have the identical boundary.
    __weak TimeProbeFixture *weakFixture = fixture;
    fixture.onChange = ^{
        if (!weakFixture.probe.active) {
            weakFixture.onChange = nil;
            CHECK([weakFixture start]);
        }
    };
    fixture.receiver.receivedWithTimeEvidence(envelope, evidence);
    CHECK(fixture.probe.active && [fixture.probe.diagnostics[@"round"] isEqual:@2] && count(fixture) == 0);
    fixture.wall = 2002.5; receive(fixture, message(2002));
    CHECK(count(fixture) == 1 && ![last(fixture)[@"receiverGeneration"] isEqual:evidence[@"generation"]]);
    privateReport(fixture); [fixture stop];
}

static void checkBoundsAndInvalidation(void) {
    TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
    CHECK([fixture start]); fixture.wall = 2001.5;
    for (NSUInteger index = 0; index < 20; index++) receive(fixture, message(2001));
    CHECK(count(fixture) == 16 && !fixture.probe.active && [fixture.probe.diagnostics[@"state"] isEqual:@"sample_limit"]);
    CHECK(![fixture.receiver.diagnostics[@"armed"] boolValue] && fixture.legacyCalls == 0);
    fixture.wall = 3000.5; fixture.monotonic = 100; CHECK([fixture start]);
    fixture.monotonic = 219.999; [fixture.probe tick]; CHECK(fixture.probe.active);
    fixture.monotonic = 220; [fixture.probe tick]; CHECK(!fixture.probe.active && [fixture.probe.diagnostics[@"state"] isEqual:@"time_limit"]);
    fixture.wall = 4000.5; CHECK([fixture start]);
    [fixture.probe stopForReason:SRSourceTimeProbeInactive]; [fixture.probe tick]; CHECK(!fixture.probe.active);
    CHECK([fixture.probe.diagnostics[@"state"] isEqual:@"inactive"]);
    fixture.wall = 5000.5; CHECK([fixture start]); fixture.wall = 5001.5; receive(fixture, message(5001));
    fixture.current = @"wxid_different"; [fixture.probe tick];
    CHECK(count(fixture) == 0 && !fixture.probe.active && [fixture.probe.diagnostics[@"state"] isEqual:@"account_invalidated"]);
    fixture.current = @"wxid_time_private"; fixture.wall = 6000.5; CHECK([fixture start]);
    fixture.wall = 6001.5; receive(fixture, message(6001));
    [fixture.probe stopForReason:SRSourceTimeProbeUserStopped]; fixture.current = nil;
    CHECK(count(fixture) == 0 && [fixture.probe.diagnostics[@"state"] isEqual:@"account_invalidated"]);
    fixture.current = @"wxid_time_private"; fixture.wall = 7000.5; CHECK([fixture start]);
    [fixture.manager AsyncOnAddMsg:@"private_source@chatroom" MsgWrap:message(7001)];
    NSMutableDictionary *changed = [fixture.configuration mutableCopy]; changed[@"maximum"] = @12; fixture.configuration = changed;
    pump(); CHECK(!fixture.probe.active && count(fixture) == 0 && fixture.legacyCalls == 0);
    CHECK([fixture.probe.diagnostics[@"state"] isEqual:@"configuration_changed"]);
    fixture.wall = 8000.5; CHECK([fixture start]); fixture.configuration = nil;
    CHECK(![fixture.probe.diagnostics[@"active"] boolValue] && count(fixture) == 0);
    privateReport(fixture); [fixture stop];
}

static void checkInactiveGrace(void) {
    TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
    CHECK([fixture start]);
    CHECK(![fixture.probe.diagnostics[@"inactivePending"] boolValue]);
    CHECK(![fixture.probe.diagnostics[@"resumedAfterInactive"] boolValue]);
    fixture.monotonic = 20;
    [fixture.probe noteApplicationInactive];
    fixture.monotonic = 21;
    [fixture.probe tick];
    CHECK(fixture.probe.active && [fixture.probe.diagnostics[@"inactivePending"] boolValue]);
    [fixture.probe noteApplicationActive];
    fixture.monotonic = 22;
    [fixture.probe tick];
    CHECK(fixture.probe.active && ![fixture.probe.diagnostics[@"inactivePending"] boolValue]);
    CHECK([fixture.probe.diagnostics[@"resumedAfterInactive"] boolValue]);
    fixture.monotonic = 30;
    [fixture.probe noteApplicationInactive];
    fixture.monotonic = 31.999;
    [fixture.probe tick];
    CHECK(fixture.probe.active);
    fixture.monotonic = 32;
    [fixture.probe tick];
    CHECK(!fixture.probe.active && ![fixture.receiver.diagnostics[@"armed"] boolValue]);
    CHECK([fixture.probe.diagnostics[@"state"] isEqual:@"inactive"]);
    CHECK(![fixture.probe.diagnostics[@"resumedAfterInactive"] boolValue]);
    fixture.monotonic = 40;
    CHECK([fixture start]);
    CHECK(![fixture.probe.diagnostics[@"inactivePending"] boolValue]);
    CHECK(![fixture.probe.diagnostics[@"resumedAfterInactive"] boolValue]);
    fixture.monotonic = 50;
    [fixture.probe noteApplicationInactive];
    fixture.monotonic = 52;
    [fixture.probe noteApplicationActive];
    CHECK(!fixture.probe.active && ![fixture.receiver.diagnostics[@"armed"] boolValue]);
    CHECK([fixture.probe.diagnostics[@"state"] isEqual:@"inactive"]);
    [fixture.probe stopForReason:SRSourceTimeProbeUserStopped];
    [fixture.probe noteApplicationInactive];
    CHECK(![fixture.probe.diagnostics[@"inactivePending"] boolValue]);
    // A manual stop is idempotent once the timeout already chose the reason.
    CHECK([fixture.probe.diagnostics[@"state"] isEqual:@"inactive"]);
    privateReport(fixture); [fixture stop];
}

static void checkInactiveEntryClockFailures(void) {
    for (NSUInteger failure = 0; failure < 3; failure++) {
        TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
        CHECK([fixture start]); fixture.wall = 2001.5; receive(fixture, message(2001));
        CHECK(count(fixture) == 1);
        fixture.monotonic = failure == 0 ? NAN : (failure == 1 ? -1 : 21);
        if (failure == 2) fixture.onMonotonicRead = ^{ @throw @"private clock exception"; };
        [fixture.probe noteApplicationInactive]; fixture.onMonotonicRead = nil;
        CHECK(!fixture.probe.active && ![fixture.receiver.diagnostics[@"armed"] boolValue]);
        CHECK([fixture.probe.diagnostics[@"state"] isEqual:@"clock_invalid"]);
        CHECK(count(fixture) == 1 && fixture.receiver.observeTimeHook == nil);
        privateReport(fixture); [fixture stop];
    }
}

static void checkInactiveClockReentry(void) {
    for (NSUInteger entry = 0; entry < 3; entry++) {
        for (NSUInteger restart = 0; restart < 2; restart++) {
            for (NSUInteger outcome = 0; outcome < 3; outcome++) {
                TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
                CHECK([fixture start]); fixture.wall = 2001.5; receive(fixture, message(2001));
                CHECK(count(fixture) == 1);
                fixture.wall = 2000.5;
                fixture.monotonic = 20;
                if (entry != 0) [fixture.probe noteApplicationInactive];
                fixture.monotonic = outcome == 1 ? NAN : 21;
                NSUInteger changes = fixture.changes;
                __weak TimeProbeFixture *weakFixture = fixture;
                __block NSNumber *generation = nil;
                __block BOOL fired = NO;
                fixture.onMonotonicRead = ^{
                    weakFixture.onMonotonicRead = nil; fired = YES;
                    [weakFixture.probe stopForReason:SRSourceTimeProbeUserStopped];
                    weakFixture.monotonic = 21;
                    // Keep the wall boundary identical: ownership is not a timestamp.
                    if (restart) CHECK([weakFixture start]);
                    generation = weakFixture.receiver.diagnostics[@"receiverGeneration"];
                    if (outcome == 2) @throw @"private clock exception";
                };
                if (entry == 0) [fixture.probe noteApplicationInactive];
                else if (entry == 1) [fixture.probe noteApplicationActive];
                else [fixture.probe tick];
                CHECK(fired && fixture.probe.active == (BOOL)restart);
                NSDictionary *report = fixture.probe.diagnostics;
                CHECK([report[@"round"] unsignedIntegerValue] == 1 + restart);
                CHECK([report[@"state"] isEqual:restart ? @"sampling" : @"stopped"]);
                CHECK(![report[@"inactivePending"] boolValue] && ![report[@"resumedAfterInactive"] boolValue]);
                CHECK([report[@"samples"] count] == (restart ? 0 : 1));
                CHECK(fixture.changes == changes + 1 + restart);
                CHECK([fixture.receiver.diagnostics[@"armed"] boolValue] == (BOOL)restart);
                CHECK([fixture.receiver.diagnostics[@"receiverGeneration"] isEqual:generation]);
                CHECK((fixture.receiver.observeTimeHook != nil) == (BOOL)restart);
                if (restart) {
                    fixture.wall = 2002.5; receive(fixture, message(2002));
                    CHECK(count(fixture) == 1);
                    CHECK([last(fixture)[@"receiverGeneration"] isEqual:generation]);
                    CHECK([last(fixture)[@"round"] isEqual:report[@"round"]]);
                }
                CHECK(fixture.legacyCalls == 0); privateReport(fixture); [fixture stop];
            }
        }
    }
}

static void checkInactiveClockResume(void) {
    TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
    CHECK([fixture start]); fixture.monotonic = 20; [fixture.probe noteApplicationInactive];
    fixture.monotonic = 21;
    __weak TimeProbeFixture *weakFixture = fixture;
    fixture.onMonotonicRead = ^{
        weakFixture.onMonotonicRead = nil;
        [weakFixture.probe noteApplicationActive];
    };
    [fixture.probe tick];
    CHECK(fixture.probe.active && ![fixture.probe.diagnostics[@"inactivePending"] boolValue]);
    CHECK([fixture.probe.diagnostics[@"resumedAfterInactive"] boolValue]);
    CHECK([fixture.receiver.diagnostics[@"armed"] boolValue]);
    fixture.monotonic = 22; [fixture.probe tick]; CHECK(fixture.probe.active);
    privateReport(fixture); [fixture stop];
}

static void checkInactiveIntervalReplacement(void) {
    for (NSUInteger entry = 0; entry < 3; entry++) {
        for (NSUInteger outcome = 0; outcome < 3; outcome++) {
            TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
            CHECK([fixture start]); fixture.monotonic = 20;
            if (entry != 0) [fixture.probe noteApplicationInactive];
            fixture.monotonic = outcome == 1 ? NAN : 20;
            __weak TimeProbeFixture *weakFixture = fixture;
            fixture.onMonotonicRead = ^{
                weakFixture.onMonotonicRead = nil; weakFixture.monotonic = 20;
                if (entry == 0) [weakFixture.probe noteApplicationInactive];
                [weakFixture.probe noteApplicationActive];
                // A new interval can have exactly the same clock boundary.
                if (entry != 0) [weakFixture.probe noteApplicationInactive];
                if (outcome == 2) @throw @"private clock exception";
            };
            if (entry == 0) [fixture.probe noteApplicationInactive];
            else if (entry == 1) [fixture.probe noteApplicationActive];
            else [fixture.probe tick];
            CHECK(fixture.probe.active && [fixture.receiver.diagnostics[@"armed"] boolValue]);
            CHECK([fixture.probe.diagnostics[@"inactivePending"] boolValue] == (entry != 0));
            CHECK([fixture.probe.diagnostics[@"resumedAfterInactive"] boolValue]);
            fixture.monotonic = 22; [fixture.probe tick];
            CHECK(fixture.probe.active == (entry == 0));
            CHECK([fixture.probe.diagnostics[@"state"] isEqual:entry == 0 ? @"sampling" : @"inactive"]);
            privateReport(fixture); [fixture stop];
        }
    }
    // The guard must not hide a genuine failure in the still-current interval.
    for (NSUInteger outcome = 0; outcome < 3; outcome++) {
        TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
        CHECK([fixture start]); fixture.wall = 2001.5; receive(fixture, message(2001));
        fixture.monotonic = 20; [fixture.probe noteApplicationInactive];
        fixture.monotonic = outcome == 0 ? 19 : NAN;
        if (outcome == 2) fixture.onMonotonicRead = ^{ @throw @"private clock exception"; };
        [fixture.probe tick]; fixture.onMonotonicRead = nil;
        CHECK(!fixture.probe.active && ![fixture.receiver.diagnostics[@"armed"] boolValue]);
        CHECK([fixture.probe.diagnostics[@"state"] isEqual:@"clock_invalid"] && count(fixture) == 1);
        privateReport(fixture); [fixture stop];
    }
}

static void checkCapabilityAndFaults(void) {
    for (Class type in @[TimeProbeWrap.class, FloatingTimeWrap.class]) {
        TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:type];
        CHECK([fixture start]); fixture.wall = 2001.5;
        TimeProbeWrap *wrap = [[type alloc] init]; IntegerTimeWrap *template = message(2001);
        wrap.m_nsFromUsr = template.m_nsFromUsr; wrap.m_nsToUsr = template.m_nsToUsr;
        wrap.m_nsRealChatUsr = template.m_nsRealChatUsr; wrap.m_nsContent = template.m_nsContent;
        wrap.m_uiMessageType = 1; wrap.m_n64MesSvrID = template.m_n64MesSvrID;
        receive(fixture, wrap); CHECK(count(fixture) == 1 && last(fixture)[@"createdAt"] == NSNull.null);
        CHECK([fixture.probe.diagnostics[@"getterDeclaredReturnEncoding"] isEqual:type == TimeProbeWrap.class ? @"missing" : @"incompatible"]);
        CHECK([[fixture.probe.diagnostics[@"hookSamples"] lastObject][@"actualGetterEncoding"]
            isEqual:type == TimeProbeWrap.class ? @"missing" : @"incompatible"]);
        privateReport(fixture); [fixture stop];
    }
    TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:IntegerTimeWrap.class];
    CHECK([fixture start]); fixture.allowed = NO; [fixture.probe tick];
    CHECK(!fixture.probe.active && [fixture.probe.diagnostics[@"state"] isEqual:@"environment_blocked"]);
    fixture.allowed = YES; fixture.wall = 3000.5; CHECK([fixture start]);
    fixture.monotonic = 9; [fixture.probe tick]; CHECK(!fixture.probe.active && [fixture.probe.diagnostics[@"state"] isEqual:@"clock_invalid"]);
    fixture.monotonic = 100; fixture.wall = 4000.5; CHECK([fixture start]);
    fixture.contextThrows = YES; [fixture.probe tick]; CHECK(!fixture.probe.active && count(fixture) == 0);
    CHECK([fixture.probe.diagnostics[@"state"] isEqual:@"context_unavailable"]); fixture.contextThrows = NO;
    fixture.wall = 5000.5; CHECK([fixture start]);
    [fixture.receiver stop]; fixture.wall = 5002.5;
    CHECK([fixture.receiver armForAccount:fixture.current sourceGroup:@"private_source@chatroom" error:NULL]);
    [fixture.probe tick]; CHECK(!fixture.probe.active && [fixture.receiver.diagnostics[@"armed"] boolValue]);
    CHECK([fixture.probe.diagnostics[@"state"] isEqual:@"receiver_stopped"]); [fixture stop];
    fixture.wall = 6000.5;
    __weak TimeProbeFixture *weakFixture = fixture;
    fixture.receiver.trace = ^(NSString *event, __unused NSDictionary *facts) {
        if ([event isEqual:@"receiver_arm"]) [weakFixture.probe stopForReason:SRSourceTimeProbeInactive];
    };
    CHECK(![fixture start] && !fixture.probe.active && ![fixture.receiver.diagnostics[@"armed"] boolValue]);
    privateReport(fixture); [fixture stop];
}

static void checkSupplementalHooks(void) {
    // The configured class intentionally lacks the getter. Only the actual
    // object's declaration can explain the Q value observed below.
    TimeProbeFixture *fixture = [[TimeProbeFixture alloc] initWithWrapClass:TimeProbeWrap.class];
    CHECK(fixture.receiver.observeTimeHook == nil);
    CHECK([fixture start]); fixture.wall = 2002.5;
    IntegerTimeWrap *image = message(1990); image.m_uiMessageType = 3;
    // Empty content and no server ID must remain visible without preparing media.
    image.m_nsContent = nil; image.m_n64MesSvrID = 0;
    receive(fixture, image);
    NSDictionary *hook = [fixture.probe.diagnostics[@"hookSamples"] lastObject];
    CHECK(count(fixture) == 0 && [fixture.probe.diagnostics[@"hookSamples"] count] == 1);
    CHECK([hook[@"messageType"] isEqual:@3] && [hook[@"actualGetterEncoding"] isEqual:@"Q"]);
    CHECK([fixture.probe.diagnostics[@"getterDeclaredReturnEncoding"] isEqual:@"missing"]);
    CHECK([hook[@"createdAt"] isEqual:@1990] && [hook[@"receivedAt"] isEqual:@2002.5]);
    CHECK([hook[@"correlationScope"] isEqual:@"local"] && ![hook[@"serverIDPresent"] boolValue]);
    CHECK([fixture.receiver.diagnostics[@"imageReads"] isEqual:@0]);
    image.m_uiMessageType = 49; receive(fixture, image);
    image.m_uiMessageType = 3; image.m_nsRealChatUsr = @"wrong"; receive(fixture, image);
    CHECK([fixture.probe.diagnostics[@"hookSamples"] count] == 1);
    image.m_nsRealChatUsr = @"wxid_other_private"; image.m_uiMesLocalID = 0;
    receive(fixture, image); hook = [fixture.probe.diagnostics[@"hookSamples"] lastObject];
    CHECK(hook[@"messageOrdinal"] == NSNull.null && [hook[@"correlationScope"] isEqual:@"none"]);
    // Snapshot is taken before the original host method mutates the object.
    __weak TimeProbeFixture *weakFixture = fixture;
    fixture.manager.duringOriginal = ^{ image.m_uiCreateTime = 3000; weakFixture.wall = 2010; };
    receive(fixture, image); fixture.manager.duringOriginal = nil;
    hook = [fixture.probe.diagnostics[@"hookSamples"] lastObject];
    CHECK([hook[@"createdAt"] isEqual:@1990] && [hook[@"receivedAt"] isEqual:@2002.5]);
    // Reservations, not just retained samples, bound an unpumped hook burst.
    for (NSUInteger index = 0; index < 100; index++)
        [fixture.manager AsyncOnAddMsg:@"private_source@chatroom" MsgWrap:image];
    pump(); CHECK([fixture.probe.diagnostics[@"hookSamples"] count] == 16);
    privateReport(fixture);
    [fixture stop]; CHECK(fixture.receiver.observeTimeHook == nil);
    fixture.wall = 4000.5; CHECK([fixture start]);
    [fixture.manager AsyncOnAddMsg:@"private_source@chatroom" MsgWrap:image];
    [fixture stop]; CHECK([fixture start]); pump();
    CHECK([fixture.probe.diagnostics[@"hookSamples"] count] == 0);
    // Account resolution can synchronously stop/rearm with an identical wall
    // boundary. The post-resolution receiver generation fence must win.
    fixture.onReceiverAccountRead = ^{
        weakFixture.onReceiverAccountRead = nil;
        [weakFixture stop]; CHECK([weakFixture start]);
    };
    [fixture.manager AsyncOnAddMsg:@"private_source@chatroom" MsgWrap:image]; pump();
    CHECK([fixture.probe.diagnostics[@"hookSamples"] count] == 0 && count(fixture) == 0);
    fixture.current = @"changed"; [fixture.probe tick];
    CHECK([fixture.probe.diagnostics[@"hookSamples"] count] == 0 && fixture.receiver.observeTimeHook == nil);
    [fixture stop];
}

int main(void) {
    @autoreleasepool {
        checkObservation(); checkOwnAndGeneration(); checkReadbackCorrelationRejectsMismatch();
        checkBoundsAndInvalidation(); checkInactiveGrace(); checkInactiveEntryClockFailures(); checkCapabilityAndFaults(); checkMetadataAndClocks(); checkReentrantRestart(); checkSupplementalHooks();
        checkInactiveClockReentry(); checkInactiveClockResume(); checkInactiveIntervalReplacement();
        puts("PASS: read-only source-time text probe, original chain, frozen evidence, bounded rounds, identity invalidation, no image preparation and legacy capture routing");
    }
    return 0;
}
