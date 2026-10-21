#import "SRWeChatTextSendHost.h"
#import "SRRuntime.h"
#import <objc/runtime.h>
#include <limits.h>
#include <math.h>
#include <string.h>

@protocol SRTextWrapInitializer <NSObject>
- (instancetype)initWithMsgType:(unsigned int)type;
@end

@interface SRWeChatTextSendHost ()
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) Class (^resolver)(NSString *);
@property(nonatomic, copy) NSString *(^currentAccount)(void);
@property(nonatomic, copy) BOOL (^environmentAllowed)(void);
@property(nonatomic, copy) NSString *state;
@property(nonatomic, copy) NSString *problem;
@property(nonatomic) BOOL abiValidated;
@property(nonatomic) BOOL consumed;
@property(nonatomic) BOOL addInvoked;
@property(nonatomic) BOOL addReturned;
@property(nonatomic) BOOL observing;
@property(nonatomic) NSUInteger lookupAttempts;
@property(nonatomic) NSUInteger lookupMisses;
@property(nonatomic) NSUInteger identityConflicts;
@property(nonatomic) double deadline;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSString *target;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, strong) id manager;
@property(nonatomic, copy) NSNumber *localID;
@property(nonatomic, copy) NSNumber *serverID;
@property(nonatomic, strong) NSMutableArray *samples;
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, copy) SRWeChatTextSendHostCompletion completion;
@end

static const char *SRHostType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}
static BOOL SRHostObject(const char *type) {
    type = SRHostType(type);
    return type[0] == '@' && type[1] != '?';
}
static BOOL SRHostInteger(const char *type) {
    type = SRHostType(type);
    return type[0] && !type[1] && strchr("iIqQlLsScC", type[0]);
}
static NSMethodSignature *SRHostSignature(Class type, NSString *name) {
    Method method = type ? class_getInstanceMethod(type, NSSelectorFromString(name)) : NULL;
    return method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
}
static BOOL SRHostIdentifier(id value, BOOL group) {
    return [value isKindOfClass:NSString.class] && [value length] &&
        [value rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound &&
        (group ? [value length] > @"@chatroom".length && [value hasSuffix:@"@chatroom"] : ![value hasSuffix:@"@chatroom"]);
}

/* Validate the actual method, not the message object's overridden reflection. */
static BOOL SRHostSetObject(id target, NSString *name, id value) {
    NSMethodSignature *s = SRHostSignature(object_getClass(target), name);
    if (!s || s.numberOfArguments != 3 || strcmp(SRHostType(s.methodReturnType), "v") ||
        !SRHostObject([s getArgumentTypeAtIndex:2])) return NO;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:s];
    invocation.target = target; invocation.selector = NSSelectorFromString(name);
    __unsafe_unretained id argument = value;
    [invocation setArgument:&argument atIndex:2]; [invocation invoke]; return YES;
}
static BOOL SRHostSetInteger(id target, NSString *name, unsigned long long value) {
    NSMethodSignature *s = SRHostSignature(object_getClass(target), name);
    if (!s || s.numberOfArguments != 3 || strcmp(SRHostType(s.methodReturnType), "v")) return NO;
    const char *type = SRHostType([s getArgumentTypeAtIndex:2]);
    if (!SRHostInteger(type)) return NO;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:s];
    invocation.target = target; invocation.selector = NSSelectorFromString(name);
    switch (type[0]) {
#define SR_HOST_SET_INTEGER(encoding, ctype, maximum) \
        case encoding: { if (value > (unsigned long long)(maximum)) return NO; ctype scalar = (ctype)value; [invocation setArgument:&scalar atIndex:2]; break; }
        SR_HOST_SET_INTEGER('i', int, INT_MAX)
        SR_HOST_SET_INTEGER('I', unsigned int, UINT_MAX)
        SR_HOST_SET_INTEGER('q', long long, LLONG_MAX)
        SR_HOST_SET_INTEGER('Q', unsigned long long, ULLONG_MAX)
        SR_HOST_SET_INTEGER('l', long, LONG_MAX)
        SR_HOST_SET_INTEGER('L', unsigned long, ULONG_MAX)
        SR_HOST_SET_INTEGER('s', short, SHRT_MAX)
        SR_HOST_SET_INTEGER('S', unsigned short, USHRT_MAX)
        SR_HOST_SET_INTEGER('c', signed char, SCHAR_MAX)
        SR_HOST_SET_INTEGER('C', unsigned char, UCHAR_MAX)
#undef SR_HOST_SET_INTEGER
        default: return NO;
    }
    [invocation invoke]; return YES;
}

@implementation SRWeChatTextSendHost
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class (^)(NSString *))resolver
                 currentAccount:(NSString *(^)(void))currentAccount environmentAllowed:(BOOL (^)(void))environmentAllowed {
    self = [super init];
    if (self) {
        _version = [version copy]; _resolver = [resolver copy]; _currentAccount = [currentAccount copy];
        _environmentAllowed = [environmentAllowed copy]; _state = @"idle"; _samples = [NSMutableArray array];
    }
    return self;
}
- (void)dealloc { if (_timer) dispatch_source_cancel(_timer); }
- (BOOL)fail:(NSString *)reason error:(NSError **)error {
    self.state = @"blocked"; self.problem = reason;
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.TextSendHost" code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
    return NO;
}
- (BOOL)validateClasses:(NSError **)error {
    self.abiValidated = NO;
    Class context = self.resolver(@"MMContext"), manager = self.resolver(@"CMessageMgr"), wrap = self.resolver(@"CMessageWrap");
    NSMethodSignature *current = SRHostSignature(object_getClass(context), @"currentContext");
    NSMethodSignature *service = SRHostSignature(context, @"getService:");
    if (!context || !manager || !wrap || !current || current.numberOfArguments != 2 || !SRHostObject(current.methodReturnType) ||
        !service || service.numberOfArguments != 3 || !SRHostObject(service.methodReturnType) ||
        (strcmp(SRHostType([service getArgumentTypeAtIndex:2]), "#") && !SRHostObject([service getArgumentTypeAtIndex:2])))
        return [self fail:@"service_abi_incompatible" error:error];
    NSMethodSignature *add = SRHostSignature(manager, @"AddMsg:MsgWrap:"), *get = SRHostSignature(manager, @"GetMsg:LocalID:");
    if (!add || add.numberOfArguments != 4 || strcmp(SRHostType(add.methodReturnType), "v") ||
        !SRHostObject([add getArgumentTypeAtIndex:2]) || !SRHostObject([add getArgumentTypeAtIndex:3]) ||
        !get || get.numberOfArguments != 4 || !SRHostObject(get.methodReturnType) ||
        !SRHostObject([get getArgumentTypeAtIndex:2]) || !SRHostInteger([get getArgumentTypeAtIndex:3]))
        return [self fail:@"message_manager_abi_incompatible" error:error];
    NSMethodSignature *initializer = SRHostSignature(wrap, @"initWithMsgType:");
    const char *argument = initializer && initializer.numberOfArguments == 3 ? SRHostType([initializer getArgumentTypeAtIndex:2]) : "";
    if (!initializer || !SRHostObject(initializer.methodReturnType) || (strcmp(argument, "I") && strcmp(argument, "i")))
        return [self fail:@"initializer_abi_incompatible" error:error];
    for (NSString *name in @[@"setM_nsFromUsr:", @"setM_nsToUsr:", @"setM_nsContent:"]) {
        NSMethodSignature *s = SRHostSignature(wrap, name);
        if (!s || s.numberOfArguments != 3 || strcmp(SRHostType(s.methodReturnType), "v") || !SRHostObject([s getArgumentTypeAtIndex:2]))
            return [self fail:@"text_setter_abi_incompatible" error:error];
    }
    for (NSString *name in @[@"m_nsFromUsr", @"m_nsToUsr", @"m_nsContent"]) {
        NSMethodSignature *s = SRHostSignature(wrap, name);
        if (!s || s.numberOfArguments != 2 || !SRHostObject(s.methodReturnType))
            return [self fail:@"text_getter_abi_incompatible" error:error];
    }
    for (NSString *name in @[@"setM_uiMesLocalID:", @"setM_uiCreateTime:"]) {
        NSMethodSignature *s = SRHostSignature(wrap, name);
        if (!s || s.numberOfArguments != 3 || strcmp(SRHostType(s.methodReturnType), "v") || !SRHostInteger([s getArgumentTypeAtIndex:2]))
            return [self fail:@"integer_setter_abi_incompatible" error:error];
    }
    for (NSString *name in @[@"m_uiMessageType", @"m_uiMesLocalID", @"m_n64MesSvrID", @"m_uiCreateTime", @"m_uiStatus"]) {
        NSMethodSignature *s = SRHostSignature(wrap, name);
        if (!s || s.numberOfArguments != 2 || !SRHostInteger(s.methodReturnType))
            return [self fail:@"integer_getter_abi_incompatible" error:error];
    }
    self.abiValidated = YES; return YES;
}
- (BOOL)readyForAccount:(NSString *)account error:(NSError **)error {
    if (!NSThread.isMainThread) return [self fail:@"main_thread_required" error:error];
    if (self.consumed) return [self fail:@"one_attempt_per_launch" error:error];
    if (![@[@"8.0.76", @"8.0.79"] containsObject:self.version]) return [self fail:@"unsupported_version" error:error];
    @try {
        if (!SRHostIdentifier(account, NO) || !self.resolver || !self.currentAccount || !self.environmentAllowed ||
            ![self.currentAccount() isEqual:account] || !self.environmentAllowed())
            return [self fail:@"account_or_environment_changed" error:error];
        if (![self validateClasses:error]) return NO;
    } @catch (__unused id exception) { return [self fail:@"capability_check_exception" error:error]; }
    self.state = @"ready"; self.problem = nil; return YES;
}
- (BOOL)matches:(id)message localID:(NSNumber *)local {
    return [message isKindOfClass:self.resolver(@"CMessageWrap")] &&
        [SRReadDeclaredString(message, @"m_nsFromUsr", NULL) isEqual:self.account] &&
        [SRReadDeclaredString(message, @"m_nsToUsr", NULL) isEqual:self.target] &&
        [SRReadDeclaredString(message, @"m_nsContent", NULL) isEqual:self.text] &&
        [SRReadUnsignedInteger(message, @"m_uiMessageType", NULL) isEqual:@1] &&
        (!local || [SRReadUnsignedInteger(message, @"m_uiMesLocalID", NULL) isEqual:local]);
}
- (void)sample:(id)message source:(NSString *)source {
    NSNumber *server = SRReadUnsignedInteger(message, @"m_n64MesSvrID", NULL);
    if (!server) { self.identityConflicts++; return; }
    if (self.serverID && server.unsignedLongLongValue && ![server isEqual:self.serverID]) { self.identityConflicts++; return; }
    if (server.unsignedLongLongValue) self.serverID = server;
    NSDictionary *sample = @{@"source": source, @"localIDPresent": @(self.localID.unsignedLongLongValue > 0),
        @"serverIDPresent": @(server.unsignedLongLongValue > 0), @"statusCode": SRReadUnsignedInteger(message, @"m_uiStatus", NULL) ?: (id)NSNull.null};
    if (![self.samples.lastObject isEqual:sample] && self.samples.count < 8) [self.samples addObject:sample];
}
- (void)submitRequest:(NSDictionary *)request completion:(SRWeChatTextSendHostCompletion)completion {
    if (!NSThread.isMainThread) { if (completion) completion(@"uncertain", nil, @"main_thread_required"); return; }
    NSString *reason = nil;
    @try {
        if (![request isKindOfClass:NSDictionary.class] || ![request[@"payload"] isKindOfClass:NSDictionary.class] ||
            ![request[@"type"] isEqual:@"text"] || !SRHostIdentifier(request[@"account"], NO) || !SRHostIdentifier(request[@"target"], YES) ||
            !SRHostIdentifier(request[@"sourceGroup"], YES) || [request[@"sourceGroup"] isEqual:request[@"target"]] ||
            !SRHostIdentifier(request[@"sourceSender"], NO) || !SRHostIdentifier(request[@"sourceMessageID"], NO) ||
            ![request[@"payload"][@"text"] isKindOfClass:NSString.class] || ![request[@"payload"][@"text"] length]) {
            reason = @"invalid_request";
        } else {
            NSError *error = nil;
            if (![self readyForAccount:request[@"account"] error:&error]) reason = error.localizedDescription;
            else {
                self.account = request[@"account"]; self.target = request[@"target"]; self.text = request[@"payload"][@"text"];
                Class contextClass = self.resolver(@"MMContext"), managerClass = self.resolver(@"CMessageMgr"), wrapClass = self.resolver(@"CMessageWrap");
                id context = SRReadObject(contextClass, @"currentContext", @[], NULL);
                id manager = SRReadObject(context, @"getService:", @[managerClass], NULL);
                id message = [(id<SRTextWrapInitializer>)[wrapClass alloc] initWithMsgType:1];
                double now = NSDate.date.timeIntervalSince1970;
                if (![context isKindOfClass:contextClass] || ![manager isKindOfClass:managerClass] || ![message isKindOfClass:wrapClass] ||
                    !isfinite(now) || now < 1 || now > UINT_MAX ||
                    !SRHostSetObject(message, @"setM_nsFromUsr:", self.account) || !SRHostSetObject(message, @"setM_nsToUsr:", self.target) ||
                    !SRHostSetObject(message, @"setM_nsContent:", self.text) || !SRHostSetInteger(message, @"setM_uiMesLocalID:", 0) ||
                    !SRHostSetInteger(message, @"setM_uiCreateTime:", (unsigned long long)now) || ![self matches:message localID:@0] ||
                    ![SRReadUnsignedInteger(message, @"m_n64MesSvrID", NULL) isEqual:@0] ||
                    ![SRReadUnsignedInteger(message, @"m_uiCreateTime", NULL) isEqual:@((unsigned long long)now)]) reason = @"construction_rejected";
                else if (![self.currentAccount() isEqual:self.account] || !self.environmentAllowed()) reason = @"account_or_environment_changed";
                else {
                    NSMethodSignature *s = SRHostSignature(object_getClass(manager), @"AddMsg:MsgWrap:");
                    if (!s || s.numberOfArguments != 4 || strcmp(SRHostType(s.methodReturnType), "v") ||
                        !SRHostObject([s getArgumentTypeAtIndex:2]) || !SRHostObject([s getArgumentTypeAtIndex:3])) reason = @"message_manager_abi_incompatible";
                    else {
                        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:s];
                        invocation.target = manager; invocation.selector = NSSelectorFromString(@"AddMsg:MsgWrap:");
                        __unsafe_unretained id target = self.target, wrap = message;
                        [invocation setArgument:&target atIndex:2]; [invocation setArgument:&wrap atIndex:3];
                        self.consumed = YES; self.addInvoked = YES; self.state = @"submitting";
                        [invocation invoke]; self.addReturned = YES;
                        self.localID = SRReadUnsignedInteger(message, @"m_uiMesLocalID", NULL);
                        if (!self.localID.unsignedLongLongValue || ![self matches:message localID:self.localID]) reason = @"post_submit_identity_unavailable";
                        else {
                            self.manager = manager; [self sample:message source:@"after_add"];
                            self.completion = completion;
                            self.observing = YES; self.state = @"observing"; self.deadline = NSProcessInfo.processInfo.systemUptime + 30;
                            __weak typeof(self) weakSelf = self;
                            self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
                            dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_MSEC * 100);
                            dispatch_source_set_event_handler(self.timer, ^{ [weakSelf poll]; }); dispatch_resume(self.timer);
                            [self poll];
                            return;
                        }
                    }
                }
            }
        }
    } @catch (__unused id exception) { reason = self.addInvoked ? @"submission_exception" : @"construction_exception"; }
    if (reason) { self.problem = reason; self.state = self.addInvoked ? @"uncertain" : @"blocked"; }
    if (!self.observing) { self.manager = nil; self.account = nil; self.target = nil; self.text = nil; }
    if (completion) completion(@"uncertain", nil, reason ?: @"submitted_delivery_unknown");
}
- (void)poll {
    if (!NSThread.isMainThread || !self.observing) return;
    @try {
        if (![self.currentAccount() isEqual:self.account] || !self.environmentAllowed()) {
            self.problem = @"observation_environment_changed"; [self stopObservation]; return;
        }
        if (self.lookupAttempts >= 30 || NSProcessInfo.processInfo.systemUptime >= self.deadline) { [self stopObservation]; return; }
        self.lookupAttempts++;
        id found = SRReadObjectWithObjectAndUnsignedInteger(self.manager, @"GetMsg:LocalID:", self.target, self.localID, NULL);
        if (!found) self.lookupMisses++;
        else if (![self matches:found localID:self.localID]) { self.identityConflicts++; self.problem = @"readback_identity_conflict"; [self stopObservation]; }
        else { [self sample:found source:@"local_readback"]; if (self.serverID || self.identityConflicts) [self stopObservation]; }
    } @catch (__unused id exception) { self.problem = @"observation_exception"; [self stopObservation]; }
}
- (void)stopObservation {
    if (!NSThread.isMainThread) return;
    if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
    if (self.observing) self.state = @"uncertain";
    self.observing = NO; self.manager = nil; self.account = nil; self.target = nil; self.text = nil;
    SRWeChatTextSendHostCompletion completion = self.completion; self.completion = nil;
    if (completion) completion(@"uncertain", nil, self.problem ?: @"submitted_delivery_unknown");
}
- (NSDictionary *)diagnostics {
    NSMutableArray *methods = [NSMutableArray array];
    @try {
        [methods addObject:SRDescribeInstanceMethod(object_getClass(self.resolver(@"MMContext")), @"currentContext")];
        [methods addObject:SRDescribeInstanceMethod(self.resolver(@"MMContext"), @"getService:")];
        for (NSString *name in @[@"AddMsg:MsgWrap:", @"GetMsg:LocalID:"]) [methods addObject:SRDescribeInstanceMethod(self.resolver(@"CMessageMgr"), name)];
        for (NSString *name in @[@"initWithMsgType:", @"setM_nsFromUsr:", @"setM_nsToUsr:", @"setM_nsContent:", @"setM_uiMesLocalID:", @"setM_uiCreateTime:"])
            [methods addObject:SRDescribeInstanceMethod(self.resolver(@"CMessageWrap"), name)];
    } @catch (__unused id exception) { }
    return @{@"schema": @1, @"wechatVersion": self.version, @"abiValidated": @(self.abiValidated),
        @"activeSendImplemented": @YES, @"batchSendingEnabled": @NO, @"deviceVerified": @NO,
        @"submissionAttempted": @(self.addInvoked), @"hostReturned": @(self.addReturned), @"observing": @(self.observing),
        @"localIDPresent": @(self.localID.unsignedLongLongValue > 0), @"serverIDPresent": @(self.serverID.unsignedLongLongValue > 0),
        @"lookupAttempts": @(self.lookupAttempts), @"lookupMisses": @(self.lookupMisses), @"identityConflicts": @(self.identityConflicts),
        @"state": self.state, @"problem": self.problem ?: @"", @"samples": [self.samples copy], @"methods": methods,
        @"deliveryOutcome": self.addInvoked ? @"uncertain" : @"not_submitted"};
}
@end
