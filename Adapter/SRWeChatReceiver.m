#import "SRWeChatReceiver.h"
#import "SRRuntime.h"
#import "Core/SRSourceMessage.h"
#import <objc/runtime.h>
#include <string.h>

@class SRReceiveTap;
@interface SRPendingOwnText : NSObject
@property(nonatomic, strong) id wrap;
@property(nonatomic, weak) id manager;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, copy) NSNumber *localID;
@end
@implementation SRPendingOwnText
@end

@interface SRDirectionObservation : NSObject
@property(nonatomic, weak) SRWeChatReceiver *owner;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, copy) NSDictionary *before;
@end
@implementation SRDirectionObservation
@end

@interface SRWeChatReceiver ()
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) Class (^resolver)(NSString *);
@property(nonatomic, copy) NSString *(^currentAccount)(void);
@property(nonatomic, copy) void (^received)(NSDictionary *);
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSString *group;
@property(nonatomic, copy) NSString *problem;
@property(nonatomic) BOOL armed;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, strong) SRReceiveTap *tap;
@property(nonatomic, strong) SRReceiveTap *outgoingTap;
@property(nonatomic, strong) SRPendingOwnText *pendingOutgoing;
@property(nonatomic, copy) NSString *ownTextState;
@property(nonatomic) NSUInteger queuedOutgoing;
@property(nonatomic, strong) NSMutableDictionary *counters;
@property(nonatomic) NSTimeInterval armedAt;
@property(nonatomic) NSTimeInterval lastCallbackAt;
@property(nonatomic, strong) NSMutableArray *directionSamples;
@property(nonatomic) NSUInteger directionReservations;
@property(nonatomic) NSUInteger directionDropped;
- (SRDirectionObservation *)beginDirectionForSession:(id)session wrap:(id)wrap;
- (void)finishDirection:(SRDirectionObservation *)observation path:(NSString *)path wrap:(id)wrap;
- (void)observeSession:(id)session wrap:(id)wrap;
- (void)observeOutgoingManager:(id)manager session:(id)session wrap:(id)wrap;
- (void)pollOutgoing:(SRPendingOwnText *)pending group:(NSString *)group account:(NSString *)account generation:(NSUInteger)generation remaining:(NSUInteger)remaining;
@end

@interface SRReceiveTap : NSObject
@property(nonatomic) IMP original;
@property(atomic, weak) SRWeChatReceiver *listener;
@end
@implementation SRReceiveTap
@end

static NSMutableDictionary *SRTaps(void) {
    static NSMutableDictionary *taps; static dispatch_once_t once;
    dispatch_once(&once, ^{ taps = [NSMutableDictionary dictionary]; }); return taps;
}
static const char *SRReceiveType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++; return type;
}
static BOOL SRReceiveSignature(Method method) {
    if (!method) return NO;
    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        if (strcmp(SRReceiveType(signature.methodReturnType), "v") || signature.numberOfArguments != 4) return NO;
        for (NSUInteger i = 2; i < 4; i++) {
            const char *type = SRReceiveType([signature getArgumentTypeAtIndex:i]);
            if (type[0] != '@' || type[1] == '?') return NO;
        }
        return YES;
    } @catch (__unused id exception) { return NO; }
}
static BOOL SRReceiveGetter(Class type, NSString *name, BOOL integer) {
    Method method = type ? class_getInstanceMethod(type, NSSelectorFromString(name)) : NULL;
    if (!method) return NO;
    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        const char *result = SRReceiveType(signature.methodReturnType);
        if (signature.numberOfArguments != 2 || !result[0]) return NO;
        return integer ? strchr("iIqQlLsScC", result[0]) != NULL : (result[0] == '@' && result[1] != '?');
    } @catch (__unused id exception) { return NO; }
}

// Diagnostic states only; raw identifiers never enter a snapshot or trace.
static NSString *SRDirectionString(id wrap, NSString *name, NSUInteger *state) {
    *state = 0;
    @try {
        if (!wrap) return nil;
        SEL selector = NSSelectorFromString(name);
        if (![wrap respondsToSelector:selector]) { *state = 1; return nil; }
        NSMethodSignature *signature = [wrap methodSignatureForSelector:selector];
        const char *type = signature ? SRReceiveType(signature.methodReturnType) : "";
        if (!signature || signature.numberOfArguments != 2 || type[0] != '@' || type[1] == '?') {
            *state = 2; return nil;
        }
        NSError *error = nil;
        id value = SRReadObject(wrap, name, @[], &error);
        if (error) { *state = 3; return nil; }
        if (!value) { *state = 4; return nil; }
        if (![value isKindOfClass:NSString.class]) { *state = 5; return nil; }
        *state = [value length] ? 7 : 6;
        return [value copy];
    } @catch (__unused id exception) { *state = 3; return nil; }
}
static NSDictionary *SRDirectionSnapshot(id wrap, Class expected, NSString *account, NSString *group) {
    NSUInteger fromState, toState, senderState;
    NSString *from = SRDirectionString(wrap, @"m_nsFromUsr", &fromState);
    NSString *to = SRDirectionString(wrap, @"m_nsToUsr", &toState);
    NSString *sender = SRDirectionString(wrap, @"m_nsRealChatUsr", &senderState);
    NSUInteger classCode = !wrap ? 0 : (expected && object_getClass(wrap) == expected ? 1 :
        (expected && [wrap isKindOfClass:expected] ? 2 : 3));
    NSNumber *type = SRReadUnsignedInteger(wrap, @"m_uiMessageType", NULL);
    return @{@"wrapClassCode": @(classCode), @"fromState": @(fromState), @"toState": @(toState), @"senderState": @(senderState),
        @"fromIsAccount": @([from isEqual:account]), @"fromIsSource": @([from isEqual:group]), @"fromIsGroup": @([from hasSuffix:@"@chatroom"]),
        @"toIsAccount": @([to isEqual:account]), @"toIsSource": @([to isEqual:group]), @"toIsGroup": @([to hasSuffix:@"@chatroom"]),
        @"senderIsAccount": @([sender isEqual:account]), @"senderIsSource": @([sender isEqual:group]),
        @"senderIsGroup": @([sender hasSuffix:@"@chatroom"]), @"fromEqualsTo": @(from.length && [from isEqual:to]),
        @"senderEqualsFrom": @(sender.length && [sender isEqual:from]), @"senderEqualsTo": @(sender.length && [sender isEqual:to]),
        @"typeReadable": @(type != nil), @"messageType": type ?: @0};
}

@implementation SRWeChatReceiver
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class (^)(NSString *))resolver
                currentAccount:(NSString *(^)(void))currentAccount received:(void (^)(NSDictionary *))received {
    self = [super init];
    if (self) { _version = [version copy]; _resolver = [resolver copy]; _currentAccount = [currentAccount copy]; _received = [received copy]; }
    return self;
}
- (BOOL)fail:(NSString *)reason error:(NSError **)error {
    @synchronized(self) { self.problem = reason; }
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.Receiver" code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
    return NO;
}
- (void)note:(NSString *)event {
    BOOL first;
    @synchronized(self) {
        if (!self.counters) self.counters = [NSMutableDictionary dictionary];
        NSUInteger count = [self.counters[event] unsignedIntegerValue]; first = count == 0;
        self.counters[event] = @(count == NSUIntegerMax ? count : count + 1);
        self.lastCallbackAt = NSDate.date.timeIntervalSince1970;
    }
    if (first) @try { if (self.trace) self.trace(event, @{}); } @catch (__unused id exception) { }
}
- (SRDirectionObservation *)beginDirectionForSession:(id)session wrap:(id)wrap {
    NSString *account, *group; NSUInteger generation;
    @synchronized(self) {
        if (!self.armed || ![session isKindOfClass:NSString.class] || ![session isEqual:self.group]) return nil;
        if (self.directionReservations >= 12) {
            if (self.directionDropped < NSUIntegerMax) self.directionDropped++;
            return nil;
        }
        self.directionReservations++; account = self.account; group = self.group; generation = self.generation;
    }
    SRDirectionObservation *observation = [[SRDirectionObservation alloc] init];
    observation.owner = self; observation.generation = generation;
    observation.before = SRDirectionSnapshot(wrap, self.resolver(@"CMessageWrap"), account, group);
    return observation;
}
- (void)finishDirection:(SRDirectionObservation *)observation path:(NSString *)path wrap:(id)wrap {
    if (!observation || observation.owner != self) return;
    NSString *account, *group;
    @synchronized(self) {
        if (!self.armed || self.generation != observation.generation) return;
        account = self.account; group = self.group;
    }
    NSDictionary *after = SRDirectionSnapshot(wrap, self.resolver(@"CMessageWrap"), account, group);
    @synchronized(self) {
        if (!self.armed || self.generation != observation.generation) return;
        [self.directionSamples addObject:@{@"path": path, @"time": @(NSDate.date.timeIntervalSince1970),
            @"before": observation.before, @"after": after}];
    }
}
- (BOOL)armForAccount:(NSString *)account sourceGroup:(NSString *)group error:(NSError **)error {
    if (!NSThread.isMainThread) return [self fail:@"Receive capture must be armed on the main thread" error:error];
    if (![@[@"8.0.76", @"8.0.79"] containsObject:self.version]) return [self fail:@"This version has no receive candidate" error:error];
    if (!account.length || [account hasSuffix:@"@chatroom"] || ![group hasSuffix:@"@chatroom"])
        return [self fail:@"A stable account and source group are required" error:error];
    @synchronized(self) { if (self.armed) return [self fail:@"Stop the current capture before arming again" error:error]; }
    @try { if (![self.currentAccount() isEqual:account]) return [self fail:@"Account changed before capture" error:error]; }
    @catch (__unused id exception) { return [self fail:@"Cannot verify the current account" error:error]; }
    Class manager = self.resolver(@"CMessageMgr"); SEL selector = NSSelectorFromString(@"AsyncOnAddMsg:MsgWrap:");
    Method method = manager ? class_getInstanceMethod(manager, selector) : NULL;
    if (!SRReceiveSignature(method)) return [self fail:@"Receive entry is absent or is not void(object, object)" error:error];
    Class wrapClass = self.resolver(@"CMessageWrap");
    for (NSString *name in @[@"m_nsFromUsr", @"m_nsToUsr", @"m_nsRealChatUsr", @"m_nsContent"])
        if (!SRReceiveGetter(wrapClass, name, NO)) return [self fail:@"Message string getters are absent or incompatible" error:error];
    for (NSString *name in @[@"m_uiMessageType", @"m_n64MesSvrID"])
        if (!SRReceiveGetter(wrapClass, name, YES)) return [self fail:@"Message integer getters are absent or incompatible" error:error];
    @synchronized(SRTaps()) {
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)manager];
        SRReceiveTap *tap = SRTaps()[key];
        if (tap.listener && tap.listener != self) return [self fail:@"Another receiver owns this capture entry" error:error];
        if (!tap) {
            tap = [[SRReceiveTap alloc] init]; tap.original = method_getImplementation(method);
            SRReceiveTap *installed = tap;
            IMP replacement = imp_implementationWithBlock(^(id object, id session, id wrap) {
                SRDirectionObservation *observation = nil;
                @try { observation = [installed.listener beginDirectionForSession:session wrap:wrap]; } @catch (__unused id exception) { }
                ((void (*)(id, SEL, id, id))installed.original)(object, selector, session, wrap);
                // Never let optional observation exceptions change WeChat's receive behavior.
                @try { [installed.listener finishDirection:observation path:@"receive" wrap:wrap]; } @catch (__unused id exception) { }
                @try { [installed.listener observeSession:session wrap:wrap]; } @catch (__unused id exception) { }
            });
            if (!class_addMethod(manager, selector, replacement, method_getTypeEncoding(method)))
                tap.original = method_setImplementation(class_getInstanceMethod(manager, selector), replacement);
            SRTaps()[key] = tap;
        }
        @synchronized(self) {
            self.account = account; self.group = group; self.problem = nil; self.generation++;
            self.counters = [NSMutableDictionary dictionary]; self.armedAt = NSDate.date.timeIntervalSince1970; self.lastCallbackAt = 0;
            self.directionSamples = [NSMutableArray array]; self.directionReservations = 0; self.directionDropped = 0;
            self.pendingOutgoing = nil; self.queuedOutgoing = 0; self.ownTextState = @"unavailable";
            self.tap = tap; self.armed = YES; tap.listener = self;
        }
        // Optional outgoing observation. Never invoke AddMsg ourselves.
        SEL outgoingSelector = NSSelectorFromString(@"AddMsg:MsgWrap:");
        Method outgoingMethod = class_getInstanceMethod(manager, outgoingSelector);
        if (SRReceiveSignature(outgoingMethod)) {
            NSString *outgoingKey = [NSString stringWithFormat:@"%p:AddMsg", manager];
            SRReceiveTap *outgoing = SRTaps()[outgoingKey];
            if (!outgoing) {
                outgoing = [[SRReceiveTap alloc] init]; outgoing.original = method_getImplementation(outgoingMethod);
                SRReceiveTap *installed = outgoing;
                IMP replacement = imp_implementationWithBlock(^(id object, id session, id wrap) {
                    SRDirectionObservation *observation = nil;
                    @try { observation = [installed.listener beginDirectionForSession:session wrap:wrap]; } @catch (__unused id exception) { }
                    ((void (*)(id, SEL, id, id))installed.original)(object, outgoingSelector, session, wrap);
                    @try { [installed.listener finishDirection:observation path:@"outgoing" wrap:wrap]; } @catch (__unused id exception) { }
                    @try { [installed.listener observeOutgoingManager:object session:session wrap:wrap]; } @catch (__unused id exception) { }
                });
                if (!class_addMethod(manager, outgoingSelector, replacement, method_getTypeEncoding(outgoingMethod)))
                    outgoing.original = method_setImplementation(class_getInstanceMethod(manager, outgoingSelector), replacement);
                SRTaps()[outgoingKey] = outgoing;
            }
            if (!outgoing.listener || outgoing.listener == self) {
                self.outgoingTap = outgoing; outgoing.listener = self; self.ownTextState = @"waiting";
            }
        }
    }
    [self note:@"receiver_arm"];
    return YES;
}
- (void)observeSession:(id)session wrap:(id)wrap {
    NSString *account, *group; NSUInteger generation;
    @synchronized(self) {
        if (!self.armed) return;
        account = self.account; group = self.group; generation = self.generation;
    }
    [self note:@"receive_callback"];
    if (![session isKindOfClass:NSString.class] || ![session isEqual:group]) { [self note:@"receive_wrong_session"]; return; }
    NSString *from = SRReadString(wrap, @"m_nsFromUsr"), *to = SRReadString(wrap, @"m_nsToUsr");
    NSString *sender = SRReadString(wrap, @"m_nsRealChatUsr");
    BOOL outgoing = [from isEqual:account] && [to isEqual:group];
    if (outgoing) {
        if (sender.length && ![sender isEqual:account]) { [self note:@"receive_invalid_sender"]; return; }
        sender = account;
    }
    if (!outgoing && (![from isEqual:group] || ![to isEqual:account])) { [self note:@"receive_wrong_direction"]; return; }
    if (!sender.length ||
        [sender hasSuffix:@"@chatroom"] ||
        [sender rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) { [self note:@"receive_invalid_sender"]; return; }
    NSNumber *type = SRReadUnsignedInteger(wrap, @"m_uiMessageType", NULL);
    NSNumber *serverID = SRReadUnsignedInteger(wrap, @"m_n64MesSvrID", NULL);
    // Images need verified media preparation; no XML-as-path or temporary/local ID fallback.
    if (![type isEqual:@1]) { [self note:@"receive_not_text"]; return; }
    if (!serverID.unsignedLongLongValue) { [self note:@"receive_no_server_id"]; return; }
    NSString *content = SRReadString(wrap, @"m_nsContent");
    if (!content.length) { [self note:@"receive_empty_text"]; return; }
    NSDictionary *message = [SRSourceMessage frozenJSON:@{@"account": account, @"group": group, @"sender": sender,
        @"messageID": [@"svr:" stringByAppendingString:serverID.stringValue], @"type": @"text",
        @"generatedByRelay": @NO, @"payload": @{@"text": content}}];
    if (!message) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SRWeChatReceiver *receiver = weakSelf; if (!receiver) return;
        @synchronized(receiver) { if (!receiver.armed || receiver.generation != generation) return; }
        @try {
            if (![receiver.currentAccount() isEqual:account]) {
                [receiver note:@"account_changed"];
                [receiver stop]; [receiver fail:@"Account changed; receive capture stopped" error:NULL]; return;
            }
            @synchronized(receiver) { if (!receiver.armed || receiver.generation != generation) return; }
            [receiver note:@"source_candidate"]; receiver.received(message);
        } @catch (__unused id exception) {
            [receiver stop]; [receiver fail:@"Receive callback failed; capture stopped" error:NULL];
        }
    });
}
- (void)observeOutgoingManager:(id)manager session:(id)session wrap:(id)wrap {
    NSString *account, *group; NSUInteger generation;
    @synchronized(self) {
        if (!self.armed) return;
        account = self.account; group = self.group; generation = self.generation;
    }
    [self note:@"outgoing_callback"];
    if (![session isKindOfClass:NSString.class] || ![session isEqual:group]) { [self note:@"outgoing_wrong_session"]; return; }
    if (![SRReadString(wrap, @"m_nsFromUsr") isEqual:account] || ![SRReadString(wrap, @"m_nsToUsr") isEqual:group]) {
        [self note:@"outgoing_wrong_direction"]; return;
    }
    if (![SRReadUnsignedInteger(wrap, @"m_uiMessageType", NULL) isEqual:@1]) { [self note:@"outgoing_not_text"]; return; }
    NSString *text = [SRReadString(wrap, @"m_nsContent") copy];
    if (!text.length) return;
    SRPendingOwnText *pending = [[SRPendingOwnText alloc] init];
    pending.wrap = wrap; pending.manager = manager; pending.text = text;
    pending.localID = SRReadUnsignedInteger(wrap, @"m_uiMesLocalID", NULL);
    @synchronized(self) {
        if (!self.armed || self.generation != generation || self.pendingOutgoing || self.queuedOutgoing >= 16) return;
        self.queuedOutgoing++;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SRWeChatReceiver *receiver = weakSelf;
        if (!receiver) return;
        @synchronized(receiver) {
            if (!receiver.armed || receiver.generation != generation) return;
            receiver.queuedOutgoing--;
            if (receiver.pendingOutgoing) return;
            receiver.pendingOutgoing = pending; receiver.ownTextState = @"awaiting_server_id";
        }
        [receiver note:@"own_pending"];
        [receiver pollOutgoing:pending group:group account:account generation:generation remaining:30];
    });
}
- (BOOL)ownWrap:(id)wrap matchesPending:(SRPendingOwnText *)pending group:(NSString *)group account:(NSString *)account {
    NSString *sender = SRReadString(wrap, @"m_nsRealChatUsr");
    return [SRReadString(wrap, @"m_nsFromUsr") isEqual:account] && [SRReadString(wrap, @"m_nsToUsr") isEqual:group] &&
        [SRReadString(wrap, @"m_nsContent") isEqual:pending.text] && (!sender.length || [sender isEqual:account]) &&
        [SRReadUnsignedInteger(wrap, @"m_uiMessageType", NULL) isEqual:@1] &&
        (!pending.localID.unsignedLongLongValue || [SRReadUnsignedInteger(wrap, @"m_uiMesLocalID", NULL) isEqual:pending.localID]);
}
- (void)pollOutgoing:(SRPendingOwnText *)pending group:(NSString *)group account:(NSString *)account generation:(NSUInteger)generation remaining:(NSUInteger)remaining {
    @synchronized(self) { if (!self.armed || self.generation != generation || self.pendingOutgoing != pending) return; }
    @try {
        if (![self.currentAccount() isEqual:account]) { [self note:@"account_changed"]; [self stop]; return; }
        if (![self ownWrap:pending.wrap matchesPending:pending group:group account:account]) {
            self.pendingOutgoing = nil; self.ownTextState = @"conflict";
            [self note:@"own_conflict"];
            [self fail:@"Own message fields changed; no source was captured" error:NULL]; return;
        }
        id wrap = pending.wrap;
        // Some hosts replace the wrap after sending. Only read back its exact, observed local ID.
        if (!SRReadUnsignedInteger(wrap, @"m_n64MesSvrID", NULL).unsignedLongLongValue && pending.localID.unsignedLongLongValue) {
            id stored = SRReadObjectWithObjectAndUnsignedInteger(pending.manager, @"GetMsg:LocalID:", group, pending.localID, NULL);
            [self note:@"own_readback"];
            if (stored && [self ownWrap:stored matchesPending:pending group:group account:account]) wrap = stored;
        }
        if (SRReadUnsignedInteger(wrap, @"m_n64MesSvrID", NULL).unsignedLongLongValue) {
            if (![self.currentAccount() isEqual:account]) { [self stop]; return; }
            [self observeSession:group wrap:wrap]; self.pendingOutgoing = nil; self.ownTextState = @"source_candidate"; return;
        }
        if (!remaining) {
            self.pendingOutgoing = nil; self.ownTextState = @"timed_out";
            [self note:@"own_timeout"];
            [self fail:@"Own text has no server message ID after 30 seconds; no source was captured" error:NULL]; return;
        }
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakSelf pollOutgoing:pending group:group account:account generation:generation remaining:remaining - 1];
        });
    } @catch (__unused id exception) {
        self.pendingOutgoing = nil; self.ownTextState = @"error"; [self fail:@"Own text observation failed" error:NULL];
    }
}
- (void)stop {
    BOOL wasArmed;
    @synchronized(SRTaps()) {
        @synchronized(self) {
            wasArmed = self.armed;
            self.armed = NO; self.generation++;
            if (self.tap.listener == self) self.tap.listener = nil;
            if (self.outgoingTap.listener == self) self.outgoingTap.listener = nil;
            self.pendingOutgoing = nil;
            self.queuedOutgoing = 0;
            self.account = nil; self.group = nil;
        }
    }
    if (wasArmed) [self note:@"receiver_stopped"];
}
- (NSDictionary *)diagnostics {
    @synchronized(self) {
        Class manager = self.resolver(@"CMessageMgr"), wrap = self.resolver(@"CMessageWrap");
        NSMutableArray *methods = [NSMutableArray arrayWithObject:SRDescribeInstanceMethod(manager, @"AsyncOnAddMsg:MsgWrap:")];
        [methods addObject:SRDescribeInstanceMethod(manager, @"AddMsg:MsgWrap:")];
        [methods addObject:SRDescribeInstanceMethod(manager, @"GetMsg:LocalID:")];
        for (NSString *name in @[@"m_nsFromUsr", @"m_nsToUsr", @"m_nsRealChatUsr", @"m_uiMessageType", @"m_n64MesSvrID", @"m_nsContent", @"m_uiMesLocalID"])
            [methods addObject:SRDescribeInstanceMethod(wrap, name)];
        return @{@"wechatVersion": self.version, @"armed": @(self.armed), @"installed": @(self.tap != nil),
            @"ownTextHookAvailable": @(self.outgoingTap != nil), @"ownTextPending": @(self.pendingOutgoing != nil),
            @"ownTextState": self.ownTextState ?: @"idle",
            @"armedAt": @(self.armedAt), @"lastEventAt": @(self.lastCallbackAt), @"counters": [self.counters copy] ?: @{},
            @"directionEvidenceSchema": @1, @"directionSampleLimit": @12, @"directionSamples": [self.directionSamples copy] ?: @[],
            @"directionSamplesDropped": @(self.directionDropped),
            @"textOnlyCandidate": @YES, @"sendingEnabled": @NO, @"problem": self.problem ?: @"", @"methods": methods};
    }
}
@end
