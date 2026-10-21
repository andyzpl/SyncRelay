#import "SRWeChatImageSendProbe.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <limits.h>
#include <string.h>

@protocol SRImageProbeInitI32 <NSObject>
- (instancetype)initWithMsgType:(int)type;
@end
@protocol SRImageProbeInitU32 <NSObject>
- (instancetype)initWithMsgType:(unsigned int)type;
@end
@protocol SRImageProbeInitI64 <NSObject>
- (instancetype)initWithMsgType:(long long)type;
@end
@protocol SRImageProbeInitU64 <NSObject>
- (instancetype)initWithMsgType:(unsigned long long)type;
@end

@interface SRWeChatImageSendProbe ()
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) Class (^resolver)(NSString *);
@property(nonatomic, copy) NSString *(^currentAccount)(void);
@property(nonatomic, copy) BOOL (^environmentAllowed)(void);
@property(nonatomic, copy) NSString *state;
@property(nonatomic, strong) NSMutableDictionary *checks;
@property(nonatomic) BOOL checking;
@property(nonatomic) BOOL constructorInvoked;
@property(nonatomic) BOOL extensionGetterInvoked;
@property(nonatomic) BOOL longCompatible;
@property(nonatomic) BOOL originCompatible;
@property(nonatomic) BOOL fieldsCompatible;
@end

static const char *SRImageProbeType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}
static BOOL SRImageProbeObject(const char *type) {
    type = SRImageProbeType(type);
    return type[0] == '@' && type[1] != '?';
}
static NSString *SRImageProbeToken(const char *type) {
    type = SRImageProbeType(type);
    if (SRImageProbeObject(type)) return @"@";
    if (type[0] && !type[1] && strchr("v#:iIqQlLsScCBfd", type[0])) return [NSString stringWithFormat:@"%c", type[0]];
    return @"other";
}
static NSMethodSignature *SRImageProbeSignature(Class type, NSString *name, NSMutableDictionary *checks) {
    Method method = type ? class_getInstanceMethod(type, NSSelectorFromString(name)) : NULL;
    NSMethodSignature *s = method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
    NSMutableArray *arguments = [NSMutableArray array];
    for (NSUInteger i = 2; s && i < MIN(s.numberOfArguments, (NSUInteger)8); i++)
        [arguments addObject:SRImageProbeToken([s getArgumentTypeAtIndex:i])];
    checks[name] = @{@"available": @(s != nil), @"argumentCount": @(s.numberOfArguments),
        @"returnType": s ? SRImageProbeToken(s.methodReturnType) : @"unavailable", @"arguments": arguments};
    if (!s || s.numberOfArguments < 2 || strcmp(SRImageProbeType([s getArgumentTypeAtIndex:0]), "@") ||
        strcmp(SRImageProbeType([s getArgumentTypeAtIndex:1]), ":")) return nil;
    return s;
}
static BOOL SRImageProbeInteger(const char *type) {
    type = SRImageProbeType(type);
    return type[0] && !type[1] && strchr("iIqQlLsScC", type[0]);
}
static BOOL SRImageProbeInstance(id object, Class expected) {
    if (!object || object_isClass(object) || !expected) return NO;
    for (Class type = object_getClass(object); type; type = class_getSuperclass(type)) if (type == expected) return YES;
    return NO;
}
static id SRImageProbeCreate(Class type, char argument) {
    // Typed init-family calls preserve ARC ownership for each supported native ABI.
    switch (argument) {
        case 'i': return [(id<SRImageProbeInitI32>)[type alloc] initWithMsgType:(int)3];
        case 'I': return [(id<SRImageProbeInitU32>)[type alloc] initWithMsgType:(unsigned int)3];
        case 'q': return [(id<SRImageProbeInitI64>)[type alloc] initWithMsgType:(long long)3];
        case 'Q': return [(id<SRImageProbeInitU64>)[type alloc] initWithMsgType:(unsigned long long)3];
        default: return nil;
    }
}
static BOOL SRImageProbeImageSetter(NSMethodSignature *s) {
    if (!s || s.numberOfArguments != 5 || strcmp(SRImageProbeType(s.methodReturnType), "v") ||
        !SRImageProbeObject([s getArgumentTypeAtIndex:2]) || !SRImageProbeObject([s getArgumentTypeAtIndex:3])) return NO;
    const char *flag = SRImageProbeType([s getArgumentTypeAtIndex:4]);
    return !strcmp(flag, "B") || !strcmp(flag, "c");
}
static unsigned long long SRImageProbeRead(id object, NSString *name, NSMethodSignature *s) {
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:s];
    invocation.target = object; invocation.selector = NSSelectorFromString(name); [invocation invoke];
    switch (SRImageProbeType(s.methodReturnType)[0]) {
#define SR_IMAGE_PROBE_READ(token, type) case token: { type value = 0; [invocation getReturnValue:&value]; return (unsigned long long)value; }
        SR_IMAGE_PROBE_READ('i', int) SR_IMAGE_PROBE_READ('I', unsigned int)
        SR_IMAGE_PROBE_READ('q', long long) SR_IMAGE_PROBE_READ('Q', unsigned long long)
        SR_IMAGE_PROBE_READ('l', long) SR_IMAGE_PROBE_READ('L', unsigned long)
        SR_IMAGE_PROBE_READ('s', short) SR_IMAGE_PROBE_READ('S', unsigned short)
        SR_IMAGE_PROBE_READ('c', signed char) SR_IMAGE_PROBE_READ('C', unsigned char)
#undef SR_IMAGE_PROBE_READ
        default: return ULLONG_MAX;
    }
}

@implementation SRWeChatImageSendProbe
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class (^)(NSString *))resolver
                 currentAccount:(NSString *(^)(void))currentAccount environmentAllowed:(BOOL (^)(void))environmentAllowed {
    self = [super init];
    if (self) {
        _version = [version copy]; _resolver = [resolver copy]; _currentAccount = [currentAccount copy];
        _environmentAllowed = [environmentAllowed copy]; _state = @"not_checked"; _checks = [NSMutableDictionary dictionary];
    }
    return self;
}
- (BOOL)fail:(NSString *)state error:(NSError **)error {
    self.state = state;
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.ImageSendProbe" code:1 userInfo:@{NSLocalizedDescriptionKey: state}];
    return NO;
}
- (BOOL)environmentForAccount:(NSString *)account {
    return self.currentAccount && self.environmentAllowed && [self.currentAccount() isEqual:account] && self.environmentAllowed();
}
- (BOOL)inspectForAccount:(NSString *)account error:(NSError **)error {
    if (!NSThread.isMainThread) return [self fail:@"main_thread_required" error:error];
    if (self.checking) return NO;
    self.checking = YES;
    self.constructorInvoked = NO; self.extensionGetterInvoked = NO;
    self.longCompatible = NO; self.originCompatible = NO; self.fieldsCompatible = NO;
    [self.checks removeAllObjects];
    @try {
        if (![@[@"8.0.76", @"8.0.79"] containsObject:self.version]) return [self fail:@"unsupported_version" error:error];
        if (![account isKindOfClass:NSString.class] || !account.length || [account hasSuffix:@"@chatroom"] ||
            [account rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
            ![self environmentForAccount:account]) return [self fail:@"account_or_environment_changed" error:error];
        Class wrapClass = self.resolver ? self.resolver(@"CMessageWrap") : Nil;
        if (!wrapClass) return [self fail:@"wrap_class_unavailable" error:error];
        NSMethodSignature *initializer = SRImageProbeSignature(wrapClass, @"initWithMsgType:", self.checks);
        NSString *argument = initializer.numberOfArguments == 3 ? SRImageProbeToken([initializer getArgumentTypeAtIndex:2]) : @"";
        if (!initializer || !SRImageProbeObject(initializer.methodReturnType) || argument.length != 1 ||
            !strchr("iIqQ", [argument characterAtIndex:0])) return [self fail:@"initializer_abi_incompatible" error:error];
        BOOL fields = YES;
        for (NSString *name in @[@"setM_nsFromUsr:", @"setM_nsToUsr:"]) {
            NSMethodSignature *s = SRImageProbeSignature(wrapClass, name, self.checks);
            fields &= s && s.numberOfArguments == 3 && !strcmp(SRImageProbeType(s.methodReturnType), "v") &&
                SRImageProbeObject([s getArgumentTypeAtIndex:2]);
        }
        for (NSString *name in @[@"setM_uiCreateTime:", @"setM_uiStatus:", @"setM_uiMesLocalID:"]) {
            NSMethodSignature *s = SRImageProbeSignature(wrapClass, name, self.checks);
            fields &= s && s.numberOfArguments == 3 && !strcmp(SRImageProbeType(s.methodReturnType), "v") &&
                SRImageProbeInteger([s getArgumentTypeAtIndex:2]);
        }
        for (NSString *name in @[@"m_nsFromUsr", @"m_nsToUsr"]) {
            NSMethodSignature *s = SRImageProbeSignature(wrapClass, name, self.checks);
            fields &= s && s.numberOfArguments == 2 && SRImageProbeObject(s.methodReturnType);
        }
        NSMutableDictionary *getters = [NSMutableDictionary dictionary];
        for (NSString *name in @[@"m_uiMessageType", @"m_uiMesLocalID", @"m_n64MesSvrID", @"m_uiCreateTime", @"m_uiStatus"]) {
            NSMethodSignature *s = SRImageProbeSignature(wrapClass, name, self.checks);
            BOOL valid = s && s.numberOfArguments == 2 && SRImageProbeInteger(s.methodReturnType);
            fields &= valid; if (valid) getters[name] = s;
        }
        self.fieldsCompatible = fields;
        if (!fields) return [self fail:@"wrap_fields_abi_incompatible" error:error];
        NSMethodSignature *extensionGetter = SRImageProbeSignature(wrapClass, @"m_extendInfoWithMsgType", self.checks);
        if (!extensionGetter) return [self fail:@"extension_getter_unavailable" error:error];
        if (extensionGetter.numberOfArguments != 2 || !SRImageProbeObject(extensionGetter.methodReturnType))
            return [self fail:@"extension_getter_abi_incompatible" error:error];
        if (![self environmentForAccount:account]) return [self fail:@"account_or_environment_changed" error:error];
        self.constructorInvoked = YES;
        id wrap = SRImageProbeCreate(wrapClass, argument.UTF8String[0]);
        if (!SRImageProbeInstance(wrap, wrapClass)) return [self fail:@"constructed_wrap_rejected" error:error];
        // An init-family call may return a subclass. Check its real getter ABIs again.
        for (NSString *name in @[@"m_uiMessageType", @"m_uiMesLocalID", @"m_n64MesSvrID"]) {
            NSMethodSignature *s = SRImageProbeSignature(object_getClass(wrap), name, self.checks);
            if (!s || s.numberOfArguments != 2 || !SRImageProbeInteger(s.methodReturnType))
                return [self fail:@"constructed_getter_abi_incompatible" error:error];
            getters[name] = s;
        }
        if (SRImageProbeRead(wrap, @"m_uiMessageType", getters[@"m_uiMessageType"]) != 3 ||
            SRImageProbeRead(wrap, @"m_uiMesLocalID", getters[@"m_uiMesLocalID"]) != 0 ||
            SRImageProbeRead(wrap, @"m_n64MesSvrID", getters[@"m_n64MesSvrID"]) != 0)
            return [self fail:@"constructed_identity_rejected" error:error];
        extensionGetter = SRImageProbeSignature(object_getClass(wrap), @"m_extendInfoWithMsgType", self.checks);
        if (!extensionGetter || extensionGetter.numberOfArguments != 2 || !SRImageProbeObject(extensionGetter.methodReturnType))
            return [self fail:@"extension_getter_abi_incompatible" error:error];
        self.extensionGetterInvoked = YES;
        id extension = ((id (*)(id, SEL))objc_msgSend)(wrap, NSSelectorFromString(@"m_extendInfoWithMsgType"));
        if (!extension) return [self fail:@"extension_not_ready" error:error];
        if (!SRImageProbeInstance(extension, NSObject.class)) return [self fail:@"extension_identity_rejected" error:error];
        self.longCompatible = SRImageProbeImageSetter(SRImageProbeSignature(object_getClass(extension), @"setImage:withData:isLongOriginImage:", self.checks));
        self.originCompatible = SRImageProbeImageSetter(SRImageProbeSignature(object_getClass(extension), @"setImage:withData:isOriginImage:", self.checks));
        if (![self environmentForAccount:account]) return [self fail:@"account_or_environment_changed" error:error];
        if (!self.longCompatible && !self.originCompatible) return [self fail:@"image_setter_abi_incompatible" error:error];
        self.state = @"contract_compatible_not_sent"; return YES;
    } @catch (__unused id exception) { return [self fail:@"inspection_exception" error:error]; }
    @finally { self.checking = NO; }
}
- (NSDictionary *)diagnostics {
    return @{@"schema": @1, @"state": self.state, @"constructorInvoked": @(self.constructorInvoked),
        @"extensionGetterInvoked": @(self.extensionGetterInvoked), @"wrapFieldsCompatible": @(self.fieldsCompatible),
        @"longSelectorCompatible": @(self.longCompatible), @"originSelectorCompatible": @(self.originCompatible),
        @"selectedSelector": self.longCompatible ? @"long" : (self.originCompatible ? @"origin" : @"none"),
        @"methods": [self.checks copy], @"imageSetterInvoked": @NO, @"serviceResolved": @NO,
        @"submissionAttempted": @NO, @"sendingEnabled": @NO, @"deliveryOutcome": @"not_submitted"};
}
@end
