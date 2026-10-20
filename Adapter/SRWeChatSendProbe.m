#import "SRWeChatSendProbe.h"
#import "SRRuntime.h"
#import <objc/runtime.h>
#include <math.h>
#include <string.h>

@class SRSendProbeTap;
@interface SRWeChatSendProbe ()
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) Class (^resolver)(NSString *);
@property(nonatomic, copy) NSString *(^currentAccount)(void);
@property(nonatomic, copy) double (^clock)(void);
@property(nonatomic, copy) void (^changed)(void);
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSString *group;
@property(nonatomic, copy) NSString *state;
@property(nonatomic, copy) NSString *problem;
@property(nonatomic) BOOL armed;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger queued;
@property(nonatomic) NSUInteger dropped;
@property(nonatomic) NSUInteger outgoing;
@property(nonatomic) NSUInteger lookupMisses;
@property(nonatomic) NSUInteger conflicts;
@property(nonatomic) double deadline;
@property(nonatomic) Class wrapClass;
@property(nonatomic, strong) SRSendProbeTap *tap;
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, weak) id manager;
@property(nonatomic, weak) id originalWrap;
@property(nonatomic, copy) NSNumber *localID;
@property(nonatomic, copy) NSNumber *serverID;
@property(nonatomic, strong) NSMutableArray *samples;
- (void)observeManager:(id)manager session:(id)session wrap:(id)wrap;
@end
@interface SRSendProbeTap : NSObject
@property(nonatomic) IMP original;
@property(atomic, weak) SRWeChatSendProbe *listener;
@end
@implementation SRSendProbeTap
@end

static NSMutableDictionary *SRSendProbeTaps(void) {
    static NSMutableDictionary *taps; static dispatch_once_t once;
    dispatch_once(&once, ^{ taps = [NSMutableDictionary dictionary]; }); return taps;
}
static const char *SRProbeType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++; return type;
}
static BOOL SRProbeObject(const char *type) { type = SRProbeType(type); return type[0] == '@' && type[1] != '?'; }
static BOOL SRProbeInteger(const char *type) { type = SRProbeType(type); return type[0] && !type[1] && strchr("iIqQlLsScC", type[0]); }
static NSMethodSignature *SRProbeSignature(Class type, NSString *selector) {
    @try {
        Method method = type ? class_getInstanceMethod(type, NSSelectorFromString(selector)) : NULL;
        return method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
    } @catch (__unused NSException *exception) { return nil; }
}
static BOOL SRProbeAddSignature(Class type) {
    NSMethodSignature *s = SRProbeSignature(type, @"AddMsg:MsgWrap:");
    return s && s.numberOfArguments == 4 && !strcmp(SRProbeType(s.methodReturnType), "v") &&
        SRProbeObject([s getArgumentTypeAtIndex:2]) && SRProbeObject([s getArgumentTypeAtIndex:3]);
}
static BOOL SRProbeLookupSignature(id target) {
    @try {
        SEL selector = NSSelectorFromString(@"GetMsg:LocalID:");
        NSMethodSignature *s = [target respondsToSelector:selector] ? [target methodSignatureForSelector:selector] : nil;
        return s && s.numberOfArguments == 4 && SRProbeObject(s.methodReturnType) &&
            SRProbeObject([s getArgumentTypeAtIndex:2]) && SRProbeInteger([s getArgumentTypeAtIndex:3]);
    } @catch (__unused NSException *exception) { return NO; }
}

@implementation SRWeChatSendProbe
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class (^)(NSString *))resolver
                currentAccount:(NSString *(^)(void))currentAccount clock:(double (^)(void))clock changed:(void (^)(void))changed {
    self = [super init];
    if (self) {
        _version = [version copy]; _resolver = [resolver copy]; _currentAccount = [currentAccount copy];
        _clock = [clock copy]; _changed = [changed copy]; _state = @"idle"; _samples = [NSMutableArray array];
    }
    return self;
}
- (void)dealloc { if (_timer) dispatch_source_cancel(_timer); }
- (void)notify {
    @try { if (self.changed) self.changed(); } @catch (__unused NSException *exception) { }
}
- (BOOL)fail:(NSString *)reason error:(NSError **)error {
    @synchronized(self) { self.problem = reason; }
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.SendProbe" code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
    return NO;
}
- (BOOL)armForAccount:(NSString *)account targetGroup:(NSString *)group error:(NSError **)error {
    if (!NSThread.isMainThread) return [self fail:@"Send observation must be armed on the main thread" error:error];
    if (![@[@"8.0.76", @"8.0.79"] containsObject:self.version]) return [self fail:@"This version has no send observation candidate" error:error];
    if (!account.length || [account hasSuffix:@"@chatroom"] || ![group hasSuffix:@"@chatroom"] ||
        [account rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
        [group rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound)
        return [self fail:@"A stable account and one target group are required" error:error];
    @synchronized(self) { if (self.armed) return [self fail:@"Stop the current observation before arming again" error:error]; }
    double now = NAN;
    @try {
        now = self.clock();
        if (![self.currentAccount() isEqual:account]) return [self fail:@"Account changed before observation" error:error];
    } @catch (__unused NSException *exception) { return [self fail:@"Cannot verify the current account or clock" error:error]; }
    if (!isfinite(now) || !isfinite(now + 120.0)) return [self fail:@"Invalid observation clock" error:error];
    Class manager = self.resolver(@"CMessageMgr"), wrap = self.resolver(@"CMessageWrap");
    if (!SRProbeAddSignature(manager)) return [self fail:@"AddMsg:MsgWrap: is absent or is not void(object, object)" error:error];
    for (NSString *name in @[@"m_nsFromUsr", @"m_nsToUsr", @"m_uiMessageType", @"m_uiMesLocalID", @"m_n64MesSvrID"]) {
        NSMethodSignature *s = SRProbeSignature(wrap, name);
        BOOL strings = [name isEqual:@"m_nsFromUsr"] || [name isEqual:@"m_nsToUsr"];
        if (!s || s.numberOfArguments != 2 || !(strings ? SRProbeObject(s.methodReturnType) : SRProbeInteger(s.methodReturnType)))
            return [self fail:@"Outgoing message metadata getters are absent or incompatible" error:error];
    }
    @synchronized(SRSendProbeTaps()) {
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)manager]; SRSendProbeTap *tap = SRSendProbeTaps()[key];
        if (tap.listener && tap.listener != self) return [self fail:@"Another observer owns this send entry" error:error];
        if (!tap) {
            tap = [[SRSendProbeTap alloc] init]; SEL selector = NSSelectorFromString(@"AddMsg:MsgWrap:");
            Method method = class_getInstanceMethod(manager, selector); tap.original = method_getImplementation(method);
            SRSendProbeTap *installed = tap;
            IMP replacement = imp_implementationWithBlock(^(id object, id session, id message) {
                ((void (*)(id, SEL, id, id))installed.original)(object, selector, session, message);
                // The optional observer runs after the unmodified original; it cannot swallow its exceptions.
                @try { [installed.listener observeManager:object session:session wrap:message]; } @catch (__unused NSException *exception) { }
            });
            if (!class_addMethod(manager, selector, replacement, method_getTypeEncoding(method)))
                tap.original = method_setImplementation(class_getInstanceMethod(manager, selector), replacement);
            SRSendProbeTaps()[key] = tap;
        }
        @synchronized(self) {
            self.account = account; self.group = group; self.wrapClass = wrap; self.deadline = now + 120.0;
            self.generation++; self.armed = YES; self.state = @"waiting"; self.problem = nil; self.tap = tap; tap.listener = self;
            self.queued = 0; self.dropped = 0; self.outgoing = 0; self.lookupMisses = 0; self.conflicts = 0;
            self.manager = nil; self.originalWrap = nil; self.localID = nil; self.serverID = nil; [self.samples removeAllObjects];
        }
    }
    __weak typeof(self) weakSelf = self;
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_MSEC * 100);
    dispatch_source_set_event_handler(self.timer, ^{ [weakSelf poll]; }); dispatch_resume(self.timer);
    [self notify]; return YES;
}
- (NSDictionary *)metadata:(id)wrap account:(NSString *)account group:(NSString *)group {
    if (![wrap isKindOfClass:self.wrapClass] || ![SRReadDeclaredString(wrap, @"m_nsFromUsr", NULL) isEqual:account] ||
        ![SRReadDeclaredString(wrap, @"m_nsToUsr", NULL) isEqual:group] || ![SRReadUnsignedInteger(wrap, @"m_uiMessageType", NULL) isEqual:@1]) return nil;
    NSNumber *local = SRReadUnsignedInteger(wrap, @"m_uiMesLocalID", NULL), *server = SRReadUnsignedInteger(wrap, @"m_n64MesSvrID", NULL);
    if (!local || !server) return nil;
    return @{@"local": local, @"server": server, @"statusCode": SRReadUnsignedInteger(wrap, @"m_uiStatus", NULL) ?: (id)NSNull.null};
}
- (void)appendMetadata:(NSDictionary *)metadata source:(NSString *)source {
    BOOL localPresent = [metadata[@"local"] unsignedLongLongValue] != 0, serverPresent = [metadata[@"server"] unsignedLongLongValue] != 0;
    BOOL localConflict = self.localID && localPresent && ![self.localID isEqual:metadata[@"local"]];
    BOOL serverConflict = self.serverID && serverPresent && ![self.serverID isEqual:metadata[@"server"]];
    if (localConflict || serverConflict) self.conflicts++;
    else {
        if (localPresent && !self.localID) self.localID = metadata[@"local"];
        if (serverPresent && !self.serverID) self.serverID = metadata[@"server"];
    }
    NSDictionary *sample = @{@"source": source, @"localIDPresent": @(localPresent), @"serverIDPresent": @(serverPresent),
        @"localIDConflict": @(localConflict), @"serverIDConflict": @(serverConflict), @"statusCode": metadata[@"statusCode"]};
    if (![self.samples.lastObject isEqual:sample]) {
        if (self.samples.count == 32) { [self.samples removeObjectAtIndex:0]; self.dropped++; }
        [self.samples addObject:sample];
    }
}
- (void)observeManager:(id)manager session:(id)session wrap:(id)wrap {
    NSString *account, *group; NSUInteger generation;
    @synchronized(self) {
        if (!self.armed || ![session isKindOfClass:NSString.class] || ![session isEqual:self.group]) return;
        if (self.queued >= 16) { self.dropped++; return; }
        account = self.account; group = self.group; generation = self.generation; self.queued++;
    }
    NSDictionary *metadata = nil;
    @try { metadata = [self metadata:wrap account:account group:group]; } @catch (__unused NSException *exception) { }
    if (!metadata) { @synchronized(self) { if (generation == self.generation) self.queued--; } return; }
    __weak typeof(self) weakSelf = self; __weak id weakManager = manager, weakWrap = wrap;
    dispatch_async(dispatch_get_main_queue(), ^{
        SRWeChatSendProbe *probe = weakSelf; if (!probe) return;
        if (![probe validateGeneration:generation]) return;
        @synchronized(probe) {
            if (!probe.armed || probe.generation != generation) return;
            probe.queued--; probe.outgoing++;
            if (probe.outgoing == 1) {
                probe.manager = weakManager; probe.originalWrap = weakWrap; probe.state = @"observing";
                [probe appendMetadata:metadata source:@"after_add"];
            }
        }
        [probe notify];
    });
}
- (void)finish:(NSString *)state generation:(NSUInteger)generation {
    BOOL changed = NO;
    @synchronized(SRSendProbeTaps()) {
        @synchronized(self) {
            if (!self.armed || self.generation != generation) return;
            self.armed = NO; self.generation++; self.state = state;
            if (self.tap.listener == self) self.tap.listener = nil;
            if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
            self.account = nil; self.group = nil; self.manager = nil; self.originalWrap = nil; self.localID = nil; self.serverID = nil; self.queued = 0;
            if ([state isEqual:@"account_changed"]) {
                [self.samples removeAllObjects]; self.outgoing = 0; self.lookupMisses = 0; self.conflicts = 0; self.dropped = 0;
            }
            changed = YES;
        }
    }
    if (changed) [self notify];
}
- (BOOL)validateGeneration:(NSUInteger)generation {
    NSString *account; double deadline;
    @synchronized(self) { if (!self.armed || self.generation != generation) return NO; account = self.account; deadline = self.deadline; }
    NSString *failure = nil;
    @try {
        double now = self.clock();
        if (!isfinite(now)) failure = @"invalid_clock";
        else if (![self.currentAccount() isEqual:account]) failure = @"account_changed";
        else if (now >= deadline) failure = @"expired";
    } @catch (__unused NSException *exception) { failure = @"account_changed"; }
    if (failure) { [self finish:failure generation:generation]; return NO; }
    return YES;
}
- (void)poll {
    if (!NSThread.isMainThread) return;
    NSUInteger generation; @synchronized(self) { generation = self.generation; }
    if (![self validateGeneration:generation]) return;
    NSString *account, *group; NSNumber *local; id manager, original;
    @synchronized(self) { account = self.account; group = self.group; local = self.localID; manager = self.manager; original = self.originalWrap; }
    if (!manager) return;
    NSDictionary *metadata = nil; NSString *source = @"live_wrap";
    if (local && SRProbeLookupSignature(manager)) {
        id found = SRReadObjectWithObjectAndUnsignedInteger(manager, @"GetMsg:LocalID:", group, local, NULL);
        metadata = [self metadata:found account:account group:group]; source = @"local_readback";
        if (metadata && ![metadata[@"local"] isEqual:local]) metadata = nil;
        if (!metadata) { @synchronized(self) { self.lookupMisses++; } }
    } else metadata = [self metadata:original account:account group:group];
    if (![self validateGeneration:generation] || !metadata) return;
    @synchronized(self) { if (self.armed && self.generation == generation) [self appendMetadata:metadata source:source]; }
    [self notify];
}
- (void)stop { NSUInteger generation; @synchronized(self) { generation = self.generation; } [self finish:@"stopped" generation:generation]; }
- (void)cancelForInactivity { NSUInteger generation; @synchronized(self) { generation = self.generation; } [self finish:@"inactive" generation:generation]; }
- (NSDictionary *)diagnostics {
    @synchronized(self) {
        Class manager = self.resolver(@"CMessageMgr"), wrap = self.resolver(@"CMessageWrap");
        NSMutableArray *methods = [NSMutableArray array];
        for (NSString *name in @[@"AddMsg:MsgWrap:", @"GetMsg:LocalID:", @"MessageReturn:MessageInfo:Event:"])
            [methods addObject:SRDescribeInstanceMethod(manager, name)];
        for (NSString *name in @[@"m_nsFromUsr", @"m_nsToUsr", @"m_uiMessageType", @"m_uiMesLocalID", @"m_n64MesSvrID", @"m_uiStatus"])
            [methods addObject:SRDescribeInstanceMethod(wrap, name)];
        return @{@"wechatVersion": self.version, @"observerOnly": @YES, @"sendingEnabled": @NO, @"deliveryOutcome": @"not_determined",
            @"armed": @(self.armed), @"installed": @(self.tap != nil), @"state": self.state, @"problem": self.problem ?: @"",
            @"windowSeconds": @120, @"observedOutgoing": @(self.outgoing), @"lookupMisses": @(self.lookupMisses),
            @"identityConflicts": @(self.conflicts), @"droppedSamplesOrCallbacks": @(self.dropped),
            @"samples": [self.samples copy], @"methods": methods};
    }
}
@end
