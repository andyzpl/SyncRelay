#import "SRWeChatTextSendHost.h"
#import "SRRuntime.h"
#import <objc/runtime.h>
#include <limits.h>
#include <string.h>

@interface SRWeChatTextSendHost ()
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) Class (^resolver)(NSString *);
@property(nonatomic, copy) NSString *(^currentAccount)(void);
@property(nonatomic, copy) BOOL (^environmentAllowed)(void);
@property(nonatomic, copy) NSString *state;
@property(nonatomic, copy) NSString *problem;
@property(nonatomic) NSUInteger attempts;
@property(nonatomic) BOOL abiValidated;
@end

static const char *SRHostType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL SRHostObjectType(const char *type) {
    type = SRHostType(type);
    return type[0] == '@' && type[1] != '?';
}

static BOOL SRHostIntegerType(const char *type) {
    type = SRHostType(type);
    return type[0] && !type[1] && strchr("iIqQlLsScC", type[0]) != NULL;
}

static BOOL SRHostVoidObjects(id target, NSString *name, NSArray *arguments) {
    @try {
        SEL selector = NSSelectorFromString(name);
        NSMethodSignature *signature = [target methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments != arguments.count + 2 ||
            strcmp(SRHostType(signature.methodReturnType), "v") != 0) return NO;
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target;
        invocation.selector = selector;
        for (NSUInteger index = 0; index < arguments.count; index++) {
            const char *type = SRHostType([signature getArgumentTypeAtIndex:index + 2]);
            id argument = arguments[index] == NSNull.null ? nil : arguments[index];
            if (!SRHostObjectType(type) || (type[0] == '#' && !object_isClass(argument))) return NO;
            __unsafe_unretained id value = argument;
            [invocation setArgument:&value atIndex:index + 2];
        }
        [invocation invoke];
        return YES;
    } @catch (__unused id exception) {
        return NO;
    }
}

static BOOL SRHostVoidInteger(id target, NSString *name, unsigned long long value) {
    @try {
        SEL selector = NSSelectorFromString(name);
        NSMethodSignature *signature = [target methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments != 3 ||
            strcmp(SRHostType(signature.methodReturnType), "v") != 0) return NO;
        const char *type = SRHostType([signature getArgumentTypeAtIndex:2]);
        if (!SRHostIntegerType(type)) return NO;
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target;
        invocation.selector = selector;
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
        [invocation invoke];
        return YES;
    } @catch (__unused id exception) {
        return NO;
    }
}

static BOOL SRHostSafeIdentifier(NSString *value, BOOL group) {
    if (![value isKindOfClass:NSString.class] || !value.length ||
        [value rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound)
        return NO;
    return !group || [value hasSuffix:@"@chatroom"];
}

static NSError *SRHostError(NSString *reason) {
    return [NSError errorWithDomain:@"SyncRelay.TextSendHost" code:1
                            userInfo:@{NSLocalizedDescriptionKey: reason}];
}

@implementation SRWeChatTextSendHost

- (instancetype)initWithVersion:(NSString *)version classResolver:(Class (^)(NSString *))resolver
                 currentAccount:(NSString *(^)(void))currentAccount
            environmentAllowed:(BOOL (^)(void))environmentAllowed {
    self = [super init];
    if (self) {
        _version = [version copy];
        _resolver = [resolver copy];
        _currentAccount = [currentAccount copy];
        _environmentAllowed = [environmentAllowed copy];
        _state = @"idle";
    }
    return self;
}

- (BOOL)fail:(NSString *)reason error:(NSError **)error {
    self.state = @"blocked";
    self.problem = reason;
    if (error) *error = SRHostError(reason);
    return NO;
}

- (BOOL)validateClasses:(NSError **)error {
    if (![@[@"8.0.76", @"8.0.79"] containsObject:self.version])
        return [self fail:@"This WeChat version has no text-send host candidate" error:error];
    Class context = self.resolver ? self.resolver(@"MMContext") : Nil;
    Class manager = self.resolver ? self.resolver(@"CMessageMgr") : Nil;
    Class wrap = self.resolver ? self.resolver(@"CMessageWrap") : Nil;
    if (!context || !manager || !wrap)
        return [self fail:@"MMContext/CMessageMgr/CMessageWrap is unavailable" error:error];
    SEL current = NSSelectorFromString(@"currentContext");
    NSMethodSignature *currentSignature = [context methodSignatureForSelector:current];
    if (!currentSignature || currentSignature.numberOfArguments != 2 ||
        !SRHostObjectType(currentSignature.methodReturnType))
        return [self fail:@"MMContext currentContext ABI is incompatible" error:error];
    Method addMethod = class_getInstanceMethod(manager, NSSelectorFromString(@"AddMsg:MsgWrap:"));
    NSMethodSignature *add = addMethod ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(addMethod)] : nil;
    if (!add || add.numberOfArguments != 4 || strcmp(SRHostType(add.methodReturnType), "v") != 0 ||
        !SRHostObjectType([add getArgumentTypeAtIndex:2]) || !SRHostObjectType([add getArgumentTypeAtIndex:3]))
        return [self fail:@"CMessageMgr AddMsg:MsgWrap: ABI is incompatible" error:error];
    Method getMethod = class_getInstanceMethod(manager, NSSelectorFromString(@"GetMsg:LocalID:"));
    NSMethodSignature *get = getMethod ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(getMethod)] : nil;
    if (!get || get.numberOfArguments != 4 || !SRHostObjectType(get.methodReturnType) ||
        !SRHostObjectType([get getArgumentTypeAtIndex:2]) || !SRHostIntegerType([get getArgumentTypeAtIndex:3]))
        return [self fail:@"CMessageMgr GetMsg:LocalID: ABI is incompatible" error:error];
    Method initMethod = class_getInstanceMethod(wrap, NSSelectorFromString(@"initWithMsgType:"));
    NSMethodSignature *initializer = initMethod ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(initMethod)] : nil;
    if (!initializer || initializer.numberOfArguments != 3 || !SRHostObjectType(initializer.methodReturnType) ||
        !SRHostIntegerType([initializer getArgumentTypeAtIndex:2]))
        return [self fail:@"CMessageWrap initWithMsgType: ABI is incompatible" error:error];
    for (NSString *name in @[@"m_nsFromUsr", @"m_nsToUsr", @"m_nsContent"]) {
        NSString *setter = [@"set" stringByAppendingString:name];
        setter = [setter stringByAppendingString:@":"];
        Method method = class_getInstanceMethod(wrap, NSSelectorFromString(setter));
        NSMethodSignature *signature = method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
        if (!signature || signature.numberOfArguments != 3 || strcmp(SRHostType(signature.methodReturnType), "v") != 0 ||
            !SRHostObjectType([signature getArgumentTypeAtIndex:2]))
            return [self fail:@"CMessageWrap text setter ABI is incompatible" error:error];
    }
    NSString *localSetter = @"setM_uiMesLocalID:";
    Method localMethod = class_getInstanceMethod(wrap, NSSelectorFromString(localSetter));
    NSMethodSignature *local = localMethod ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(localMethod)] : nil;
    if (!local || local.numberOfArguments != 3 || strcmp(SRHostType(local.methodReturnType), "v") != 0 ||
        !SRHostIntegerType([local getArgumentTypeAtIndex:2]))
        return [self fail:@"CMessageWrap local ID setter ABI is incompatible" error:error];
    for (NSString *name in @[@"m_uiMessageType", @"m_uiMesLocalID", @"m_n64MesSvrID"]) {
        Method method = class_getInstanceMethod(wrap, NSSelectorFromString(name));
        NSMethodSignature *signature = method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
        if (!signature || signature.numberOfArguments != 2 || !SRHostIntegerType(signature.methodReturnType))
            return [self fail:@"CMessageWrap message ID/type getter ABI is incompatible" error:error];
    }
    self.abiValidated = YES;
    return YES;
}

- (BOOL)readyForAccount:(NSString *)account error:(NSError **)error {
    if (!NSThread.isMainThread) return [self fail:@"Text-send host checks must run on the main thread" error:error];
    if (!SRHostSafeIdentifier(account, NO) || [account hasSuffix:@"@chatroom"])
        return [self fail:@"A stable current account is required" error:error];
    if (!self.resolver || !self.currentAccount || !self.environmentAllowed)
        return [self fail:@"Text-send host verification callbacks are missing" error:error];
    if (![self validateClasses:error]) return NO;
    @try {
        if (![self.currentAccount() isEqual:account]) return [self fail:@"Current account changed" error:error];
        if (!self.environmentAllowed()) return [self fail:@"The execution environment is not allowed" error:error];
    } @catch (__unused id exception) {
        return [self fail:@"Current account or environment check failed" error:error];
    }
    self.state = @"ready";
    self.problem = nil;
    return YES;
}

- (void)submitRequest:(NSDictionary *)request completion:(SRWeChatTextSendHostCompletion)completion {
    if (!NSThread.isMainThread) {
        if (completion) completion(@"uncertain", nil, @"Text-send host submission must run on the main thread");
        return;
    }
    self.attempts++;
    NSString *account = request[@"account"];
    NSString *target = request[@"target"];
    NSString *text = request[@"payload"][@"text"];
    NSError *error = nil;
    if (!SRHostSafeIdentifier(account, NO) || !SRHostSafeIdentifier(target, YES) ||
        ![text isKindOfClass:NSString.class] || !text.length || ![self readyForAccount:account error:&error]) {
        self.state = @"blocked";
        self.problem = error.localizedDescription ?: @"Invalid text-send request";
        if (completion) completion(@"uncertain", nil, self.problem);
        return;
    }
    Class contextClass = self.resolver(@"MMContext");
    Class managerClass = self.resolver(@"CMessageMgr");
    Class wrapClass = self.resolver(@"CMessageWrap");
    id context = SRReadObject(contextClass, @"currentContext", @[], &error);
    id manager = SRReadObject(context, @"getService:", @[managerClass], &error);
    id message = SRReadObjectWithIntegers([wrapClass alloc], @"initWithMsgType:", @[@1], &error);
    if (!context || !manager || !message || !SRHostVoidObjects(message, @"setM_nsFromUsr:", @[account]) ||
        !SRHostVoidObjects(message, @"setM_nsToUsr:", @[target]) || !SRHostVoidObjects(message, @"setM_nsContent:", @[text]) ||
        !SRHostVoidInteger(message, @"setM_uiMesLocalID:", 0) ||
        !SRHostVoidObjects(manager, @"AddMsg:MsgWrap:", @[target, message])) {
        self.state = @"uncertain";
        self.problem = error.localizedDescription ?: @"Host rejected the text message construction or submission";
        if (completion) completion(@"uncertain", nil, self.problem);
        return;
    }
    NSNumber *local = SRReadUnsignedInteger(message, @"m_uiMesLocalID", NULL);
    NSNumber *type = SRReadUnsignedInteger(message, @"m_uiMessageType", NULL);
    if (!local || !local.unsignedLongLongValue || !type || type.unsignedIntValue != 1) {
        self.state = @"uncertain";
        self.problem = @"Host submission returned no validated local text message ID";
        if (completion) completion(@"uncertain", nil, self.problem);
        return;
    }
    /* A non-zero server ID proves host association only, not group delivery. */
    id readback = SRReadObjectWithObjectAndUnsignedInteger(manager, @"GetMsg:LocalID:", target, local, NULL);
    NSNumber *server = SRReadUnsignedInteger(readback, @"m_n64MesSvrID", NULL);
    self.state = server.unsignedLongLongValue ? @"associated" : @"submitted";
    self.problem = server.unsignedLongLongValue ? @"Server ID associated; delivery still requires device verification" : @"Awaiting server ID association";
    if (completion) completion(@"uncertain", nil, self.problem);
}

- (NSDictionary *)diagnostics {
    return @{ @"wechatVersion": self.version ?: @"", @"abiValidated": @(self.abiValidated),
        @"attempts": @(self.attempts), @"state": self.state ?: @"idle", @"problem": self.problem ?: @"",
        @"sendingEnabled": @NO, @"deviceVerified": @NO };
}

@end
