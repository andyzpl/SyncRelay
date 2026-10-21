#import "SRWeChatTextSendHost.h"
#import "SRRuntime.h"
#import <objc/runtime.h>
#include <limits.h>
#include <math.h>
#include <string.h>

@protocol SRTextWrapInitializerI32 <NSObject>
- (instancetype)initWithMsgType:(int)type;
@end
@protocol SRTextWrapInitializerU32 <NSObject>
- (instancetype)initWithMsgType:(unsigned int)type;
@end
@protocol SRTextWrapInitializerI64 <NSObject>
- (instancetype)initWithMsgType:(long long)type;
@end
@protocol SRTextWrapInitializerU64 <NSObject>
- (instancetype)initWithMsgType:(unsigned long long)type;
@end

@interface SRWeChatTextSendHost ()
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) Class (^resolver)(NSString *);
@property(nonatomic, copy) NSString *(^currentAccount)(void);
@property(nonatomic, copy) BOOL (^environmentAllowed)(void);
@property(nonatomic, copy) NSString *state;
@property(nonatomic, copy) NSString *problem;
@property(nonatomic) BOOL abiValidated;
@property(nonatomic, copy) NSString *initializerArgumentType;
@property(nonatomic, copy) NSString *initializerCallType;
@property(nonatomic, copy) NSString *validationStage;
@property(nonatomic) NSUInteger contextClassCode;
@property(nonatomic) BOOL contextReadFailed;
@property(nonatomic) BOOL serviceReadFailed;
@property(nonatomic, strong) NSMutableDictionary *serviceChecks;
@property(nonatomic) BOOL consumed;
@property(nonatomic) BOOL addInvoked;
@property(nonatomic) BOOL addReturned;
@property(nonatomic) BOOL observing;
@property(nonatomic) NSUInteger lookupAttempts;
@property(nonatomic) NSUInteger lookupMisses;
@property(nonatomic) NSUInteger identityConflicts;
@property(nonatomic) BOOL observationServiceCheckFailed;
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
static NSUInteger SRHostClassCode(id object, Class expected) {
    if (!object) return 0;
    if (object_isClass(object)) return 4;
    Class actual = object_getClass(object);
    if (actual == expected) return 1;
    for (Class type = class_getSuperclass(actual); type; type = class_getSuperclass(type))
        if (type == expected) return 2;
    return 3;
}
static NSString *SRHostSignatureIssue(NSMethodSignature *s, BOOL lookup) {
    if (!s) return @"missing_method";
    if (s.numberOfArguments != 4) return @"argument_count";
    if (lookup ? !SRHostObject(s.methodReturnType) : strcmp(SRHostType(s.methodReturnType), "v") != 0)
        return @"return_type";
    if (!SRHostObject([s getArgumentTypeAtIndex:2])) return @"first_argument";
    if (lookup ? !SRHostInteger([s getArgumentTypeAtIndex:3]) : !SRHostObject([s getArgumentTypeAtIndex:3]))
        return @"second_argument";
    return @"compatible";
}
static NSString *SRHostDiagnosticType(const char *type) {
    type = SRHostType(type);
    if (SRHostObject(type)) return @"@";
    if (!strcmp(type, "@?")) return @"@?";
    if (type[0] && !type[1] && strchr("v#:iIqQlLsScCBfd*", type[0]))
        return [NSString stringWithFormat:@"%c", type[0]];
    return @"other";
}
static NSDictionary *SRHostMethodCheck(Class actual, Class named, NSString *name, NSMethodSignature *s, BOOL lookup) {
    NSMutableArray *arguments = [NSMutableArray array];
    for (NSUInteger i = 2; s && i < s.numberOfArguments && i < 10; i++)
        [arguments addObject:SRHostDiagnosticType([s getArgumentTypeAtIndex:i])];
    Method method = actual ? class_getInstanceMethod(actual, NSSelectorFromString(name)) : NULL;
    Method base = named ? class_getInstanceMethod(named, NSSelectorFromString(name)) : NULL;
    return @{@"available": @(s != nil), @"argumentCount": @(s.numberOfArguments),
        @"returnType": s ? SRHostDiagnosticType(s.methodReturnType) : @"unavailable", @"arguments": arguments,
        @"sameMethodAsNamedClass": @(method && method == base), @"issue": SRHostSignatureIssue(s, lookup)};
}
static BOOL SRHostSameABI(NSMethodSignature *left, NSMethodSignature *right) {
    if (!left || !right || left.numberOfArguments != right.numberOfArguments || left.numberOfArguments > 10 ||
        ![SRHostDiagnosticType(left.methodReturnType) isEqual:SRHostDiagnosticType(right.methodReturnType)]) return NO;
    for (NSUInteger i = 0; i < left.numberOfArguments; i++)
        if (![SRHostDiagnosticType([left getArgumentTypeAtIndex:i]) isEqual:SRHostDiagnosticType([right getArgumentTypeAtIndex:i])]) return NO;
    return YES;
}
static BOOL SRHostMetadataABI(Class actual, NSString *name, const char *result, const char *argument) {
    NSMethodSignature *s = SRHostSignature(actual, name);
    if (!s || s.numberOfArguments != 3 || strcmp(SRHostType([s getArgumentTypeAtIndex:0]), "@") ||
        strcmp(SRHostType([s getArgumentTypeAtIndex:1]), ":") || strcmp(SRHostType([s getArgumentTypeAtIndex:2]), argument)) return NO;
    const char *type = SRHostType(s.methodReturnType);
    return !strcmp(result, "bool") ? (!strcmp(type, "B") || !strcmp(type, "c")) : !strcmp(type, result);
}
static BOOL SRHostOverrides(Class actual, Class root, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(actual, selector), base = class_getInstanceMethod(root, selector);
    return method && base && method_getImplementation(method) != method_getImplementation(base);
}
static NSDictionary *SRHostForwardingCheck(id manager, Class named, NSMethodSignature **add, NSMethodSignature **lookup) {
    Class actual = object_getClass(manager), root = Nil;
    NSUInteger rootCode = 0;
    if (SRHostClassCode(manager, NSProxy.class) == 2) { root = NSProxy.class; rootCode = 2; }
    else if (SRHostClassCode(manager, NSObject.class) == 2) { root = NSObject.class; rootCode = 1; }
    BOOL signatureOverride = root && SRHostOverrides(actual, root, @"methodSignatureForSelector:");
    BOOL invocationOverride = root && SRHostOverrides(actual, root, @"forwardInvocation:");
    BOOL metadataABI = root && SRHostMetadataABI(actual, @"methodSignatureForSelector:", "@", ":") &&
        SRHostMetadataABI(actual, @"forwardInvocation:", "v", "@") &&
        SRHostMetadataABI(actual, @"isKindOfClass:", "bool", "#") &&
        SRHostMetadataABI(actual, @"respondsToSelector:", "bool", ":");
    BOOL claimsManager = NO, respondsAdd = NO, respondsLookup = NO, failed = NO;
    NSMethodSignature *forwardedAdd = nil, *forwardedLookup = nil;
    if (signatureOverride && invocationOverride && metadataABI) {
        @try {
            claimsManager = [manager isKindOfClass:named];
            respondsAdd = [manager respondsToSelector:NSSelectorFromString(@"AddMsg:MsgWrap:")];
            respondsLookup = [manager respondsToSelector:NSSelectorFromString(@"GetMsg:LocalID:")];
            id a = [manager methodSignatureForSelector:NSSelectorFromString(@"AddMsg:MsgWrap:")];
            id g = [manager methodSignatureForSelector:NSSelectorFromString(@"GetMsg:LocalID:")];
            if (SRHostClassCode(a, NSMethodSignature.class) == 1 || SRHostClassCode(a, NSMethodSignature.class) == 2) forwardedAdd = a;
            if (SRHostClassCode(g, NSMethodSignature.class) == 1 || SRHostClassCode(g, NSMethodSignature.class) == 2) forwardedLookup = g;
        } @catch (__unused id exception) { failed = YES; }
    }
    BOOL addMatches = [SRHostSignatureIssue(forwardedAdd, NO) isEqual:@"compatible"] &&
        SRHostSameABI(forwardedAdd, SRHostSignature(named, @"AddMsg:MsgWrap:"));
    BOOL lookupMatches = [SRHostSignatureIssue(forwardedLookup, YES) isEqual:@"compatible"] &&
        SRHostSameABI(forwardedLookup, SRHostSignature(named, @"GetMsg:LocalID:"));
    NSMethodSignature *declaredAdd = SRHostSignature(actual, @"AddMsg:MsgWrap:"), *declaredLookup = SRHostSignature(actual, @"GetMsg:LocalID:");
    BOOL declaredAddCompatible = !declaredAdd || ([SRHostSignatureIssue(declaredAdd, NO) isEqual:@"compatible"] && SRHostSameABI(declaredAdd, forwardedAdd));
    BOOL declaredLookupCompatible = !declaredLookup || ([SRHostSignatureIssue(declaredLookup, YES) isEqual:@"compatible"] && SRHostSameABI(declaredLookup, forwardedLookup));
    BOOL accepted = !failed && signatureOverride && invocationOverride && metadataABI && claimsManager &&
        respondsAdd && respondsLookup && addMatches && lookupMatches && declaredAddCompatible && declaredLookupCompatible;
    if (accepted) { if (add) *add = forwardedAdd; if (lookup) *lookup = forwardedLookup; }
    return @{@"rootCode": @(rootCode), @"signatureOverride": @(signatureOverride), @"invocationOverride": @(invocationOverride),
        @"metadataABICompatible": @(metadataABI), @"claimsManager": @(claimsManager), @"respondsAdd": @(respondsAdd),
        @"respondsLookup": @(respondsLookup), @"queryFailed": @(failed), @"addMatchesNamedABI": @(addMatches),
        @"lookupMatchesNamedABI": @(lookupMatches), @"declaredAddCompatible": @(declaredAddCompatible),
        @"declaredLookupCompatible": @(declaredLookupCompatible), @"accepted": @(accepted),
        @"add": SRHostMethodCheck(Nil, named, @"AddMsg:MsgWrap:", forwardedAdd, NO),
        @"lookup": SRHostMethodCheck(Nil, named, @"GetMsg:LocalID:", forwardedLookup, YES)};
}
static id SRHostLookup(id manager, NSString *target, NSNumber *localID, NSMethodSignature *signature) {
    if (!localID.unsignedLongLongValue || ![SRHostSignatureIssue(signature, YES) isEqual:@"compatible"]) return nil;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = manager; invocation.selector = NSSelectorFromString(@"GetMsg:LocalID:");
    __unsafe_unretained id argument = target; [invocation setArgument:&argument atIndex:2];
    unsigned long long value = localID.unsignedLongLongValue;
    switch (SRHostType([signature getArgumentTypeAtIndex:3])[0]) {
#define SR_HOST_LOOKUP(encoding, ctype, maximum) \
        case encoding: { if (value > (unsigned long long)(maximum)) return nil; ctype scalar = (ctype)value; [invocation setArgument:&scalar atIndex:3]; break; }
        SR_HOST_LOOKUP('i', int, INT_MAX)
        SR_HOST_LOOKUP('I', unsigned int, UINT_MAX)
        SR_HOST_LOOKUP('q', long long, LLONG_MAX)
        SR_HOST_LOOKUP('Q', unsigned long long, ULLONG_MAX)
        SR_HOST_LOOKUP('l', long, LONG_MAX)
        SR_HOST_LOOKUP('L', unsigned long, ULONG_MAX)
        SR_HOST_LOOKUP('s', short, SHRT_MAX)
        SR_HOST_LOOKUP('S', unsigned short, USHRT_MAX)
        SR_HOST_LOOKUP('c', signed char, SCHAR_MAX)
        SR_HOST_LOOKUP('C', unsigned char, UCHAR_MAX)
#undef SR_HOST_LOOKUP
        default: return nil;
    }
    [invocation invoke]; __unsafe_unretained id result = nil; [invocation getReturnValue:&result]; return result;
}
static char SRHostInitializerType(Class type) {
    NSMethodSignature *s = SRHostSignature(type, @"initWithMsgType:");
    if (!s || s.numberOfArguments != 3 || !SRHostObject(s.methodReturnType)) return 0;
    const char *argument = SRHostType([s getArgumentTypeAtIndex:2]);
    return argument[0] && !argument[1] && strchr("iIqQ", argument[0]) ? argument[0] : 0;
}
static id SRHostCreateTextWrap(Class type, char argument) {
    // Preserve init-family ARC ownership while matching the declared integer ABI.
    switch (argument) {
        case 'i': return [(id<SRTextWrapInitializerI32>)[type alloc] initWithMsgType:(int)1];
        case 'I': return [(id<SRTextWrapInitializerU32>)[type alloc] initWithMsgType:(unsigned int)1];
        case 'q': return [(id<SRTextWrapInitializerI64>)[type alloc] initWithMsgType:(long long)1];
        case 'Q': return [(id<SRTextWrapInitializerU64>)[type alloc] initWithMsgType:(unsigned long long)1];
        default: return nil;
    }
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
        _validationStage = @"not_checked"; _serviceChecks = [NSMutableDictionary dictionary];
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
    self.validationStage = @"named_classes";
    self.abiValidated = NO;
    self.initializerArgumentType = @"unchecked";
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
    char argument = SRHostInitializerType(wrap);
    self.initializerArgumentType = argument ? [NSString stringWithFormat:@"%c", argument] : @"unsupported";
    if (!argument)
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
- (BOOL)validateManager:(id)manager phase:(NSString *)phase validatedAdd:(NSMethodSignature **)validatedAdd
       validatedLookup:(NSMethodSignature **)validatedLookup error:(NSError **)error {
    if (validatedAdd) *validatedAdd = nil;
    if (validatedLookup) *validatedLookup = nil;
    if (phase) self.validationStage = @"concrete_service";
    Class named = self.resolver(@"CMessageMgr"), actual = object_getClass(manager);
    NSMethodSignature *add = SRHostSignature(actual, @"AddMsg:MsgWrap:"), *get = SRHostSignature(actual, @"GetMsg:LocalID:");
    NSUInteger code = SRHostClassCode(manager, named);
    // Fixed phases and scalar type tokens only: no object descriptions, IDs, class names or addresses.
    NSMutableDictionary *check = [@{@"managerClassCode": @(code), @"contextClassCode": @(self.contextClassCode),
        @"contextReadFailed": @(self.contextReadFailed), @"serviceReadFailed": @(self.serviceReadFailed),
        @"add": SRHostMethodCheck(actual, named, @"AddMsg:MsgWrap:", add, NO),
        @"lookup": SRHostMethodCheck(actual, named, @"GetMsg:LocalID:", get, YES), @"route": @"rejected"} mutableCopy];
    if (code == 3) {
        // Validate forwarding on the service returned by MMContext; never unwrap it or call a saved IMP.
        NSDictionary *forwarding = SRHostForwardingCheck(manager, named, &add, &get);
        check[@"forwarding"] = forwarding;
        if ([forwarding[@"accepted"] boolValue]) check[@"route"] = @"forwarding_proxy";
        if (phase) self.serviceChecks[phase] = check;
        if (![forwarding[@"accepted"] boolValue]) return [self fail:@"service_forwarding_unverified" error:error];
    } else {
        if (code == 1 || code == 2) check[@"route"] = @"direct_instance";
        if (phase) self.serviceChecks[phase] = check;
        if (code != 1 && code != 2) return [self fail:@"service_identity_rejected" error:error];
    }
    if (![SRHostSignatureIssue(add, NO) isEqual:@"compatible"])
        return [self fail:@"concrete_add_abi_incompatible" error:error];
    if (![SRHostSignatureIssue(get, YES) isEqual:@"compatible"])
        return [self fail:@"concrete_lookup_abi_incompatible" error:error];
    if (validatedAdd) *validatedAdd = add;
    if (validatedLookup) *validatedLookup = get;
    return YES;
}
- (id)resolveManagerForPhase:(NSString *)phase error:(NSError **)error {
    self.validationStage = @"service_resolution";
    Class contextClass = self.resolver(@"MMContext"), managerClass = self.resolver(@"CMessageMgr");
    NSError *readError = nil;
    id context = SRReadObject(contextClass, @"currentContext", @[], &readError);
    self.contextReadFailed = readError != nil; self.serviceReadFailed = NO;
    self.contextClassCode = SRHostClassCode(context, contextClass);
    id manager = nil;
    if (self.contextClassCode == 1 || self.contextClassCode == 2) {
        readError = nil;
        manager = SRReadObject(context, @"getService:", @[managerClass], &readError);
        self.serviceReadFailed = readError != nil;
    }
    if (![self validateManager:manager phase:phase validatedAdd:NULL validatedLookup:NULL error:error]) return nil;
    return manager;
}
- (BOOL)readyForAccount:(NSString *)account error:(NSError **)error {
    if (!NSThread.isMainThread) return [self fail:@"main_thread_required" error:error];
    if (self.consumed) return [self fail:@"one_attempt_per_launch" error:error];
    [self.serviceChecks removeAllObjects]; self.validationStage = @"prerequisites"; self.initializerCallType = nil;
    if (![@[@"8.0.76", @"8.0.79"] containsObject:self.version]) return [self fail:@"unsupported_version" error:error];
    @try {
        if (!SRHostIdentifier(account, NO) || !self.resolver || !self.currentAccount || !self.environmentAllowed ||
            ![self.currentAccount() isEqual:account] || !self.environmentAllowed())
            return [self fail:@"account_or_environment_changed" error:error];
        if (![self validateClasses:error]) return NO;
        if (![self resolveManagerForPhase:@"preflight" error:error]) return NO;
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
                Class wrapClass = self.resolver(@"CMessageWrap");
                id manager = [self resolveManagerForPhase:@"pre_submit" error:&error];
                if (!manager) {
                    self.account = nil; self.target = nil; self.text = nil;
                    if (completion) completion(@"uncertain", nil, error.localizedDescription);
                    return;
                }
                self.validationStage = @"construction";
                char argument = SRHostInitializerType(wrapClass);
                self.initializerCallType = argument ? [NSString stringWithFormat:@"%c", argument] : @"unsupported";
                id message = SRHostCreateTextWrap(wrapClass, argument);
                double now = NSDate.date.timeIntervalSince1970;
                if (![message isKindOfClass:wrapClass] ||
                    !isfinite(now) || now < 1 || now > UINT_MAX ||
                    !SRHostSetObject(message, @"setM_nsFromUsr:", self.account) || !SRHostSetObject(message, @"setM_nsToUsr:", self.target) ||
                    !SRHostSetObject(message, @"setM_nsContent:", self.text) || !SRHostSetInteger(message, @"setM_uiMesLocalID:", 0) ||
                    !SRHostSetInteger(message, @"setM_uiCreateTime:", (unsigned long long)now) || ![self matches:message localID:@0] ||
                    ![SRReadUnsignedInteger(message, @"m_n64MesSvrID", NULL) isEqual:@0] ||
                    ![SRReadUnsignedInteger(message, @"m_uiCreateTime", NULL) isEqual:@((unsigned long long)now)]) reason = @"construction_rejected";
                else if (![self.currentAccount() isEqual:self.account] || !self.environmentAllowed()) reason = @"account_or_environment_changed";
                else {
                    NSMethodSignature *s = nil;
                    if (![self validateManager:manager phase:@"pre_submit" validatedAdd:&s validatedLookup:NULL error:&error]) reason = error.localizedDescription;
                    else {
                        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:s];
                        invocation.target = manager; invocation.selector = NSSelectorFromString(@"AddMsg:MsgWrap:");
                        __unsafe_unretained id target = self.target, wrap = message;
                        [invocation setArgument:&target atIndex:2]; [invocation setArgument:&wrap atIndex:3];
                        self.consumed = YES; self.addInvoked = YES; self.state = @"submitting"; self.validationStage = @"invocation";
                        [invocation invoke]; self.addReturned = YES;
                        self.localID = SRReadUnsignedInteger(message, @"m_uiMesLocalID", NULL);
                        if (!self.localID.unsignedLongLongValue || ![self matches:message localID:self.localID]) reason = @"post_submit_identity_unavailable";
                        else {
                            self.manager = manager; [self sample:message source:@"after_add"];
                            self.completion = completion;
                            self.observing = YES; self.state = @"observing"; self.validationStage = @"observation";
                            self.deadline = NSProcessInfo.processInfo.systemUptime + 30;
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
        NSMethodSignature *lookup = nil;
        if (![self validateManager:self.manager phase:nil validatedAdd:NULL validatedLookup:&lookup error:NULL]) {
            self.observationServiceCheckFailed = YES;
            [self stopObservation]; return;
        }
        self.lookupAttempts++;
        id found = SRHostLookup(self.manager, self.target, self.localID, lookup);
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
        for (NSString *name in @[@"initWithMsgType:", @"setM_nsFromUsr:", @"setM_nsToUsr:", @"setM_nsContent:", @"setM_uiMesLocalID:", @"setM_uiCreateTime:",
            @"m_nsFromUsr", @"m_nsToUsr", @"m_nsContent", @"m_uiMessageType", @"m_uiMesLocalID", @"m_n64MesSvrID", @"m_uiCreateTime", @"m_uiStatus"])
            [methods addObject:SRDescribeInstanceMethod(self.resolver(@"CMessageWrap"), name)];
    } @catch (__unused id exception) { }
    return @{@"schema": @1, @"wechatVersion": self.version, @"abiValidated": @(self.abiValidated),
        @"initializerArgumentType": self.initializerArgumentType ?: @"unchecked", @"initializerCallType": self.initializerCallType ?: @"not_called",
        @"serviceEvidenceSchema": @2, @"validationStage": self.validationStage, @"serviceChecks": [self.serviceChecks copy],
        @"activeSendImplemented": @YES, @"batchSendingEnabled": @NO, @"deviceVerified": @NO,
        @"submissionAttempted": @(self.addInvoked), @"hostReturned": @(self.addReturned), @"observing": @(self.observing),
        @"localIDPresent": @(self.localID.unsignedLongLongValue > 0), @"serverIDPresent": @(self.serverID.unsignedLongLongValue > 0),
        @"lookupAttempts": @(self.lookupAttempts), @"lookupMisses": @(self.lookupMisses), @"identityConflicts": @(self.identityConflicts),
        @"observationServiceCheckFailed": @(self.observationServiceCheckFailed),
        @"state": self.state, @"problem": self.problem ?: @"", @"samples": [self.samples copy], @"methods": methods,
        @"deliveryOutcome": self.addInvoked ? @"uncertain" : @"not_submitted"};
}
@end
