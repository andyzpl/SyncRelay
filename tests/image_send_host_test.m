#import <Foundation/Foundation.h>
#import "Adapter/SRWeChatImageSendHost.h"
#import <objc/runtime.h>
#import "Core/SRImageAssetStore.h"

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "FAIL:%d %s\n", __LINE__, #condition); return 1; } } while (0)

static NSUInteger ImageWrites;
static BOOL ThrowImageSetter, MutateImageIdentity, InvalidImageABI, RejectImageMaterial, UseLongSetter;
static void (^OnImageSetter)(void);
@interface SRFakeUIImage : NSObject
@end
@implementation SRFakeUIImage
@end
@interface SRFakeImageExtension : NSObject
- (void)setImage:(id)image withData:(id)data isOriginImage:(BOOL)flag;
@end
@implementation SRFakeImageExtension
- (void)setImage:(id)image withData:(id)data isOriginImage:(BOOL)flag {
    NSCAssert([image isKindOfClass:SRFakeUIImage.class] && [data isKindOfClass:NSData.class] && !flag, @"image arguments");
    ImageWrites++; if (OnImageSetter) OnImageSetter();
    if (ThrowImageSetter) @throw @"private image data and path";
}
@end
@interface SRFakeLongImageExtension : SRFakeImageExtension
- (void)setImage:(id)image withData:(id)data isLongOriginImage:(bool)flag;
@end
@implementation SRFakeLongImageExtension
- (void)setImage:(id)image withData:(id)data isLongOriginImage:(bool)flag {
    NSCAssert([image isKindOfClass:SRFakeUIImage.class] && [data isKindOfClass:NSData.class] && !flag, @"long image arguments");
    ImageWrites++;
}
@end
@interface SRFakeBadImageExtension : NSObject
- (void)setImage:(id)image withData:(id)data isOriginImage:(double)flag;
@end
@implementation SRFakeBadImageExtension
- (void)setImage:(__unused id)image withData:(__unused id)data isOriginImage:(__unused double)flag { abort(); }
@end
static NSDictionary *imagePayload(void) {
    return @{@"snapshotSchema": @1, @"mediaReference": @"00000000-0000-0000-0000-000000000001",
        @"sha256": [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],
        @"scopeSHA256": [@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0],
        @"byteCount": @4, @"pixelWidth": @1, @"pixelHeight": @1, @"format": @"png"};
}
static SRImageMaterialLoader material = ^NSDictionary *(__unused NSDictionary *source, __unused NSError **error) {
    return RejectImageMaterial ? nil : @{@"image": SRFakeUIImage.new, @"data": [@"jpeg" dataUsingEncoding:NSUTF8StringEncoding]};
};
@interface SRFakeMessageWrap : NSObject
@property(nonatomic, copy) NSString *m_nsFromUsr;
@property(nonatomic, copy) NSString *m_nsToUsr;
@property(nonatomic, copy) NSString *m_nsContent;
@property(nonatomic) unsigned int m_uiMessageType;
@property(nonatomic) unsigned int m_uiMesLocalID;
@property(nonatomic) unsigned long long m_n64MesSvrID;
@property(nonatomic) unsigned int m_uiCreateTime;
@property(nonatomic) unsigned int m_uiStatus;
@property(nonatomic) unsigned long long initializerArgument;
@end

@interface SRFakeMessageWrapI32 : SRFakeMessageWrap
- (instancetype)initWithMsgType:(int)type;
@end
@interface SRFakeMessageWrapU32 : SRFakeMessageWrap
- (instancetype)initWithMsgType:(unsigned int)type;
@end
@interface SRFakeMessageWrapI64 : SRFakeMessageWrap
- (instancetype)initWithMsgType:(long long)type;
@end
@interface SRFakeMessageWrapU64 : SRFakeMessageWrap
- (instancetype)initWithMsgType:(unsigned long long)type;
@end
@interface SRFakeMessageWrapFloat : SRFakeMessageWrap
- (instancetype)initWithMsgType:(double)type;
@end
@interface SRFakeMessageWrapObject : SRFakeMessageWrap
- (instancetype)initWithMsgType:(id)type;
@end

@interface SRFakeMessageMgr : NSObject
@property(nonatomic, strong) SRFakeMessageWrap *lastWrap;
@property(nonatomic, copy) NSString *lastTarget;
@property(nonatomic) NSUInteger addCount;
@property(nonatomic) BOOL deferServerID;
@property(nonatomic) BOOL missLookup;
@property(nonatomic) BOOL conflictLookup;
@property(nonatomic) BOOL throwAfterAdd;
@end

@interface SRFakeMMContext : NSObject
@property(nonatomic, strong) SRFakeMessageMgr *manager;
@property(nonatomic, strong) SRFakeMessageMgr *substitute;
@property(nonatomic) NSUInteger serviceReads;
@property(nonatomic) NSUInteger substituteOnRead;
@property(nonatomic) BOOL rejectServiceSignature;
@end

@implementation SRFakeMessageWrap
- (id)m_extendInfoWithMsgType {
    if (MutateImageIdentity) self.m_nsToUsr = @"wrong@chatroom";
    return InvalidImageABI ? SRFakeBadImageExtension.new : (UseLongSetter ? SRFakeLongImageExtension.new : SRFakeImageExtension.new);
}
@end
@implementation SRFakeMessageWrapI32
- (instancetype)initWithMsgType:(int)type { self = [super init]; if (self) { self.m_uiMessageType = (unsigned int)type; self.initializerArgument = (unsigned long long)type; } return self; }
@end
@implementation SRFakeMessageWrapU32
- (instancetype)initWithMsgType:(unsigned int)type { self = [super init]; if (self) { self.m_uiMessageType = type; self.initializerArgument = type; } return self; }
@end
@implementation SRFakeMessageWrapI64
- (instancetype)initWithMsgType:(long long)type { self = [super init]; if (self) { self.m_uiMessageType = (unsigned int)type; self.initializerArgument = (unsigned long long)type; } return self; }
@end
@implementation SRFakeMessageWrapU64
- (instancetype)initWithMsgType:(unsigned long long)type { self = [super init]; if (self) { self.m_uiMessageType = (unsigned int)type; self.initializerArgument = type; } return self; }
@end
@implementation SRFakeMessageWrapFloat
- (instancetype)initWithMsgType:(double)type { self = [super init]; if (self) self.m_uiMessageType = (unsigned int)type; return self; }
@end
@implementation SRFakeMessageWrapObject
- (instancetype)initWithMsgType:(__unused id)type { return [super init]; }
@end

@implementation SRFakeMessageMgr
- (void)AddMsg:(NSString *)target MsgWrap:(SRFakeMessageWrap *)wrap {
    self.lastTarget = target; self.lastWrap = wrap; self.addCount++;
    wrap.m_uiMesLocalID = 42; wrap.m_n64MesSvrID = self.deferServerID ? 0 : 9001;
    if (self.throwAfterAdd) @throw [NSException exceptionWithName:@"Test" reason:@"private body" userInfo:nil];
}
- (SRFakeMessageWrap *)GetMsg:(NSString *)target LocalID:(unsigned int)localID {
    if (self.missLookup) return nil;
    if (self.conflictLookup) self.lastWrap.m_nsToUsr = @"wrong@chatroom";
    return [target isEqual:self.lastTarget] && localID == self.lastWrap.m_uiMesLocalID ? self.lastWrap : nil;
}
@end

@interface SRFakeInheritedMessageMgr : SRFakeMessageMgr
@end
@implementation SRFakeInheritedMessageMgr
@end

@interface SRFakeReflectedMessageMgr : SRFakeMessageMgr
@end
@implementation SRFakeReflectedMessageMgr
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (selector == NSSelectorFromString(@"AddMsg:MsgWrap:")) return nil;
    return [super methodSignatureForSelector:selector];
}
@end

@interface SRFakeServiceProxy : NSProxy
@property(nonatomic, strong) SRFakeMessageMgr *service;
@property(nonatomic) NSUInteger forwardAdds;
@property(nonatomic) NSUInteger forwardLookups;
@property(nonatomic) NSUInteger signatureMode;
@property(nonatomic) BOOL denyIdentity;
@property(nonatomic) BOOL denyLookup;
@property(nonatomic) BOOL throwMetadata;
@end
@implementation SRFakeServiceProxy
- (BOOL)isKindOfClass:(Class)type { return !self.denyIdentity && [self.service isKindOfClass:type]; }
- (BOOL)respondsToSelector:(SEL)selector {
    return !(self.denyLookup && selector == NSSelectorFromString(@"GetMsg:LocalID:")) && [self.service respondsToSelector:selector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (self.throwMetadata) @throw [NSException exceptionWithName:@"Test" reason:@"private proxy body" userInfo:nil];
    if (self.signatureMode == 1 && selector == NSSelectorFromString(@"AddMsg:MsgWrap:")) return nil;
    if (self.signatureMode == 2 && selector == NSSelectorFromString(@"AddMsg:MsgWrap:"))
        return [NSMethodSignature signatureWithObjCTypes:"@32@0:8@16@24"];
    if (self.signatureMode == 3 && selector == NSSelectorFromString(@"GetMsg:LocalID:"))
        return [NSMethodSignature signatureWithObjCTypes:"@32@0:8@16Q24"];
    return [self.service methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    if (invocation.selector == NSSelectorFromString(@"AddMsg:MsgWrap:")) self.forwardAdds++;
    if (invocation.selector == NSSelectorFromString(@"GetMsg:LocalID:")) self.forwardLookups++;
    [invocation invokeWithTarget:self.service];
}
@end

@interface SRFakeBadDeclaredAddProxy : SRFakeServiceProxy
@end
@implementation SRFakeBadDeclaredAddProxy
- (id)AddMsg:(__unused id)target MsgWrap:(__unused id)wrap { abort(); }
@end
@interface SRFakeBadDeclaredLookupProxy : SRFakeServiceProxy
@end
@implementation SRFakeBadDeclaredLookupProxy
- (id)GetMsg:(__unused id)target LocalID:(__unused unsigned long long)localID { abort(); }
@end

@interface SRFakeServiceWrapper : NSObject
@property(nonatomic, strong) SRFakeMessageMgr *service;
@property(nonatomic) NSUInteger forwardAdds;
@end
@implementation SRFakeServiceWrapper
- (BOOL)isKindOfClass:(Class)type { return [super isKindOfClass:type] || [self.service isKindOfClass:type]; }
- (BOOL)respondsToSelector:(SEL)selector { return [super respondsToSelector:selector] || [self.service respondsToSelector:selector]; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [super methodSignatureForSelector:selector] ?: [self.service methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    if (invocation.selector == NSSelectorFromString(@"AddMsg:MsgWrap:")) self.forwardAdds++;
    [invocation invokeWithTarget:self.service];
}
@end

@interface SRFakeIdentityOnly : NSObject
@end
@implementation SRFakeIdentityOnly
- (BOOL)isKindOfClass:(Class)type { return type == SRFakeMessageMgr.class || [super isKindOfClass:type]; }
@end

static void forbiddenMethod(__unused id object, __unused SEL selector, __unused id first, __unused id second) { abort(); }
static Class managerWithMethod(NSString *name, NSString *selector, const char *encoding) {
    Class type = objc_allocateClassPair(SRFakeMessageMgr.class, name.UTF8String, 0);
    if (!type || !class_addMethod(type, NSSelectorFromString(selector), (IMP)forbiddenMethod, encoding)) abort();
    objc_registerClassPair(type); return type;
}

@implementation SRFakeMMContext
+ (instancetype)currentContext {
    static SRFakeMMContext *context; static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [SRFakeMMContext new]; context.manager = [SRFakeMessageMgr new]; });
    return context;
}
- (id)getService:(Class)type {
    self.serviceReads++;
    return type != SRFakeMessageMgr.class ? nil :
        (self.substituteOnRead && self.serviceReads >= self.substituteOnRead ? self.substitute : self.manager);
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (self.rejectServiceSignature && selector == NSSelectorFromString(@"getService:"))
        return [NSMethodSignature signatureWithObjCTypes:"v24@0:8#16"];
    return [super methodSignatureForSelector:selector];
}
@end

static SRWeChatImageSendHost *makeHostWithWrap(Class wrap, NSString *version, NSString *(^account)(void), BOOL (^allowed)(void)) {
    return [[SRWeChatImageSendHost alloc] initWithVersion:version classResolver:^Class(NSString *name) {
        return @{ @"MMContext": SRFakeMMContext.class, @"CMessageMgr": SRFakeMessageMgr.class,
                  @"CMessageWrap": wrap, @"UIImage": SRFakeUIImage.class }[name];
    } currentAccount:account environmentAllowed:allowed materialLoader:material];
}
static SRWeChatImageSendHost *makeHost(NSString *version, NSString *(^account)(void), BOOL (^allowed)(void)) {
    return makeHostWithWrap(SRFakeMessageWrapI64.class, version, account, allowed);
}

int main(void) {
    @autoreleasepool {
        SRFakeMessageMgr *manager = [SRFakeMMContext currentContext].manager;
        NSString *(^account)(void) = ^NSString * { return @"wxid_account"; };
        BOOL (^allowed)(void) = ^BOOL { return YES; };
        SRWeChatImageSendHost *host = makeHost(@"8.0.79", account, allowed);
        NSDictionary *request = @{ @"account": @"wxid_account", @"target": @"room@chatroom", @"type": @"image",
            @"sourceGroup": @"mother@chatroom", @"sourceSender": @"wxid_sender", @"sourceMessageID": @"source-1",
            @"payload": imagePayload() };
        NSError *readyError = nil;
        BOOL ready = [host readyForAccount:@"wxid_account" error:&readyError];
        if (!ready) fprintf(stderr, "ready error: %s\n", readyError.localizedDescription.UTF8String);
        CHECK(ready);
        __block NSString *state = nil; __block NSString *reason = nil; __block BOOL callbackShapeOK = NO;
        [host submitRequest:request completion:^(NSString *value, NSString *messageID, NSString *detail) {
            state = [value copy]; reason = [detail copy]; callbackShapeOK = messageID == nil;
        }];
        CHECK(manager.addCount == 1);
        CHECK([manager.lastTarget isEqual:@"room@chatroom"]);
        CHECK([manager.lastWrap.m_nsFromUsr isEqual:@"wxid_account"]);
        CHECK([manager.lastWrap.m_nsToUsr isEqual:@"room@chatroom"]);
        CHECK(manager.lastWrap.m_nsContent == nil && ImageWrites == 1);
        CHECK([host.diagnostics[@"imageSetterInvoked"] boolValue] && [host.diagnostics[@"selectedSelector"] isEqual:@"origin"]);
        CHECK(manager.lastWrap.m_uiMessageType == 3 && manager.lastWrap.m_uiMesLocalID == 42);
        CHECK(manager.lastWrap.initializerArgument == 3);
        CHECK([host.diagnostics[@"initializerArgumentType"] isEqual:@"q"]);
        CHECK([host.diagnostics[@"initializerCallType"] isEqual:@"q"]);
        CHECK([host.diagnostics[@"serviceEvidenceSchema"] isEqual:@2]);
        CHECK([host.diagnostics[@"serviceChecks"] count] == 2);
        CHECK([host.diagnostics[@"serviceChecks"][@"pre_submit"][@"add"][@"issue"] isEqual:@"compatible"]);
        CHECK(callbackShapeOK);
        CHECK([state isEqual:@"uncertain"]);
        CHECK([reason containsString:@"unknown"] || [reason containsString:@"delivery"]);
        CHECK([host.diagnostics[@"state"] isEqual:@"uncertain"]);
        NSUInteger count = manager.addCount;
        [host submitRequest:request completion:nil];
        CHECK(manager.addCount == count);
        [host submitRequest:@{ @"account": @"wxid_account", @"target": @"not-a-group", @"type": @"image",
            @"sourceGroup": @"mother@chatroom", @"sourceSender": @"wxid_sender", @"sourceMessageID": @"source-1",
            @"payload": imagePayload() }
            completion:^(NSString *value, NSString *messageID, NSString *detail) {
                callbackShapeOK = [value isEqual:@"uncertain"] && messageID == nil && detail.length > 0;
            }];
        CHECK(manager.addCount == count);
        CHECK(callbackShapeOK);

        CHECK(![makeHost(@"8.0.80", account, allowed) readyForAccount:@"wxid_account" error:NULL]);
        CHECK(![makeHost(@"8.0.79", account, ^BOOL { return NO; }) readyForAccount:@"wxid_account" error:NULL]);
        CHECK(![makeHost(@"8.0.79", ^NSString * { return @"wxid_other"; }, allowed) readyForAccount:@"wxid_account" error:NULL]);
        SRWeChatImageSendHost *missing = [[SRWeChatImageSendHost alloc] initWithVersion:@"8.0.79"
            classResolver:^Class(__unused NSString *name) { return Nil; } currentAccount:account environmentAllowed:allowed materialLoader:material];
        CHECK(![missing readyForAccount:@"wxid_account" error:NULL]);
        CHECK(manager.addCount == count);

        NSArray *wraps = @[SRFakeMessageWrapI32.class, SRFakeMessageWrapU32.class, SRFakeMessageWrapI64.class, SRFakeMessageWrapU64.class];
        NSArray *encodings = @[@"i", @"I", @"q", @"Q"];
        for (NSUInteger index = 0; index < wraps.count; index++) {
            SRWeChatImageSendHost *typed = makeHostWithWrap(wraps[index], @"8.0.79", account, allowed);
            __block NSUInteger typedCompletions = 0;
            [typed submitRequest:request completion:^(NSString *value, NSString *messageID, __unused NSString *detail) {
                if ([value isEqual:@"uncertain"] && !messageID) typedCompletions++;
            }];
            CHECK(manager.addCount == ++count && typedCompletions == 1);
            CHECK([manager.lastWrap isKindOfClass:wraps[index]] && manager.lastWrap.initializerArgument == 3);
            CHECK([typed.diagnostics[@"initializerArgumentType"] isEqual:encodings[index]]);
            CHECK([typed.diagnostics[@"initializerCallType"] isEqual:encodings[index]]);
            CHECK([typed.diagnostics[@"deliveryOutcome"] isEqual:@"uncertain"]);
        }
        for (Class wrap in @[SRFakeMessageWrapFloat.class, SRFakeMessageWrapObject.class, SRFakeMessageWrap.class]) {
            SRWeChatImageSendHost *wrongABI = makeHostWithWrap(wrap, @"8.0.79", account, allowed);
            CHECK(![wrongABI readyForAccount:@"wxid_account" error:NULL]);
            [wrongABI submitRequest:request completion:nil];
            CHECK([wrongABI.diagnostics[@"problem"] isEqual:@"initializer_abi_incompatible"]);
            CHECK([wrongABI.diagnostics[@"initializerArgumentType"] isEqual:@"unsupported"]);
            CHECK(![wrongABI.diagnostics[@"submissionAttempted"] boolValue] && manager.addCount == count);
        }

        SRFakeMMContext *context = [SRFakeMMContext currentContext];
        for (Class type in @[SRFakeInheritedMessageMgr.class, SRFakeReflectedMessageMgr.class]) {
            SRFakeMessageMgr *subclass = [type new]; context.manager = subclass;
            SRWeChatImageSendHost *concrete = makeHost(@"8.0.79", account, allowed);
            CHECK([concrete readyForAccount:@"wxid_account" error:NULL] && subclass.addCount == 0);
            CHECK([concrete.diagnostics[@"serviceChecks"][@"preflight"][@"managerClassCode"] isEqual:@2]);
            CHECK([concrete.diagnostics[@"serviceChecks"][@"preflight"][@"add"][@"sameMethodAsNamedClass"] boolValue]);
            [concrete submitRequest:request completion:nil];
            CHECK(subclass.addCount == 1 && [concrete.diagnostics[@"submissionAttempted"] boolValue]);
        }
        NSArray *badEncodings = @[@"@32@0:8@16@24", @"v24@0:8@16", @"v32@0:8q16@24", @"v32@0:8@16@?24"];
        NSArray *issues = @[@"return_type", @"argument_count", @"first_argument", @"second_argument"];
        Class badAdd = Nil;
        for (NSUInteger i = 0; i < badEncodings.count; i++) {
            Class type = managerWithMethod([NSString stringWithFormat:@"SRFakeBadAdd%lu", (unsigned long)i],
                @"AddMsg:MsgWrap:", [badEncodings[i] UTF8String]);
            if (!i) badAdd = type;
            SRFakeMessageMgr *bad = [type new]; context.manager = bad;
            SRWeChatImageSendHost *blocked = makeHost(@"8.0.79", account, allowed);
            CHECK(![blocked readyForAccount:@"wxid_account" error:NULL] && bad.addCount == 0);
            CHECK([blocked.diagnostics[@"abiValidated"] boolValue]);
            CHECK([blocked.diagnostics[@"problem"] isEqual:@"concrete_add_abi_incompatible"]);
            CHECK([blocked.diagnostics[@"validationStage"] isEqual:@"concrete_service"]);
            NSDictionary *check = blocked.diagnostics[@"serviceChecks"][@"preflight"];
            CHECK([check[@"managerClassCode"] isEqual:@2]);
            CHECK([check[@"add"][@"issue"] isEqual:issues[i]]);
            CHECK(![check[@"add"][@"sameMethodAsNamedClass"] boolValue]);
            CHECK([blocked.diagnostics[@"initializerCallType"] isEqual:@"not_called"]);
            [blocked submitRequest:request completion:nil];
            CHECK(![blocked.diagnostics[@"submissionAttempted"] boolValue] && bad.addCount == 0);
        }
        Class badLookup = managerWithMethod(@"SRFakeBadLookup", @"GetMsg:LocalID:", "@32@0:8@16d24");
        context.manager = [badLookup new];
        SRWeChatImageSendHost *lookupBlocked = makeHost(@"8.0.79", account, allowed);
        CHECK(![lookupBlocked readyForAccount:@"wxid_account" error:NULL]);
        CHECK([lookupBlocked.diagnostics[@"problem"] isEqual:@"concrete_lookup_abi_incompatible"]);
        CHECK([lookupBlocked.diagnostics[@"serviceChecks"][@"preflight"][@"lookup"][@"issue"] isEqual:@"second_argument"]);
        for (id service in @[(id)SRFakeMessageMgr.class, [NSObject new], [SRFakeIdentityOnly new], NSNull.null]) {
            context.manager = service == NSNull.null ? nil : service;
            SRWeChatImageSendHost *identityBlocked = makeHost(@"8.0.79", account, allowed);
            CHECK(![identityBlocked readyForAccount:@"wxid_account" error:NULL]);
            CHECK(([@[@"service_identity_rejected", @"service_forwarding_unverified"] containsObject:identityBlocked.diagnostics[@"problem"]]));
            CHECK(![identityBlocked.diagnostics[@"submissionAttempted"] boolValue]);
        }
        SRFakeMessageMgr *forwardedManager = [SRFakeMessageMgr new];
        SRFakeServiceProxy *proxy = [SRFakeServiceProxy alloc]; proxy.service = forwardedManager;
        context.manager = (id)proxy;
        SRWeChatImageSendHost *proxied = makeHost(@"8.0.79", account, allowed);
        CHECK([proxied readyForAccount:@"wxid_account" error:NULL]);
        CHECK(forwardedManager.addCount == 0 && proxy.forwardAdds == 0 && proxy.forwardLookups == 0);
        NSDictionary *proxyCheck = proxied.diagnostics[@"serviceChecks"][@"preflight"];
        CHECK([proxyCheck[@"managerClassCode"] isEqual:@3]);
        CHECK([proxyCheck[@"add"][@"issue"] isEqual:@"missing_method"]);
        CHECK([proxyCheck[@"route"] isEqual:@"forwarding_proxy"]);
        CHECK([proxyCheck[@"forwarding"][@"rootCode"] isEqual:@2]);
        [proxied submitRequest:request completion:nil];
        CHECK(forwardedManager.addCount == 1 && proxy.forwardAdds == 1 && proxy.forwardLookups == 1);
        CHECK([proxied.diagnostics[@"submissionAttempted"] boolValue]);
        CHECK([proxied.diagnostics[@"deliveryOutcome"] isEqual:@"uncertain"]);
        [proxied submitRequest:request completion:nil]; CHECK(proxy.forwardAdds == 1);
        for (NSUInteger mode = 1; mode <= 6; mode++) {
            proxy.signatureMode = mode <= 3 ? mode : 0;
            proxy.denyIdentity = mode == 4; proxy.denyLookup = mode == 5; proxy.throwMetadata = mode == 6;
            SRWeChatImageSendHost *badProxy = makeHost(@"8.0.79", account, allowed);
            CHECK(![badProxy readyForAccount:@"wxid_account" error:NULL]);
            CHECK([badProxy.diagnostics[@"problem"] isEqual:@"service_forwarding_unverified"]);
            [badProxy submitRequest:request completion:nil];
            CHECK(![badProxy.diagnostics[@"submissionAttempted"] boolValue] && proxy.forwardAdds == 1 && proxy.forwardLookups == 1);
            CHECK(![[badProxy.diagnostics description] containsString:@"private proxy body"]);
        }
        proxy.signatureMode = 0; proxy.denyIdentity = NO; proxy.denyLookup = NO; proxy.throwMetadata = NO;
        for (Class type in @[SRFakeBadDeclaredAddProxy.class, SRFakeBadDeclaredLookupProxy.class]) {
            SRFakeServiceProxy *conflicting = [type alloc]; conflicting.service = [SRFakeMessageMgr new];
            context.manager = (id)conflicting;
            SRWeChatImageSendHost *declaredConflict = makeHost(@"8.0.79", account, allowed);
            CHECK(![declaredConflict readyForAccount:@"wxid_account" error:NULL]);
            [declaredConflict submitRequest:request completion:nil];
            CHECK(conflicting.forwardAdds == 0 && conflicting.service.addCount == 0);
            CHECK([declaredConflict.diagnostics[@"problem"] isEqual:@"service_forwarding_unverified"]);
        }
        context.manager = (id)proxy;
        __block NSUInteger proxyAccountReads = 0;
        SRWeChatImageSendHost *proxyChanged = makeHost(@"8.0.79", ^NSString * {
            if (++proxyAccountReads == 2) proxy.signatureMode = 3;
            return @"wxid_account";
        }, allowed);
        [proxyChanged submitRequest:request completion:nil];
        CHECK(![proxyChanged.diagnostics[@"submissionAttempted"] boolValue] && proxy.forwardAdds == 1);
        CHECK([proxyChanged.diagnostics[@"serviceChecks"][@"pre_submit"][@"forwarding"][@"lookupMatchesNamedABI"] isEqual:@NO]);
        proxy.signatureMode = 0; forwardedManager.deferServerID = YES;
        SRWeChatImageSendHost *proxyObservation = makeHost(@"8.0.79", account, allowed);
        [proxyObservation submitRequest:request completion:nil];
        CHECK([proxyObservation.diagnostics[@"observing"] boolValue]);
        NSUInteger proxyReads = proxy.forwardLookups;
        proxy.signatureMode = 3; [proxyObservation poll];
        CHECK(![proxyObservation.diagnostics[@"observing"] boolValue] && proxy.forwardLookups == proxyReads);
        CHECK([proxyObservation.diagnostics[@"observationServiceCheckFailed"] boolValue]);
        CHECK([proxyObservation.diagnostics[@"deliveryOutcome"] isEqual:@"uncertain"]);
        SRFakeServiceWrapper *wrapper = [SRFakeServiceWrapper new]; wrapper.service = [SRFakeMessageMgr new];
        context.manager = (id)wrapper;
        SRWeChatImageSendHost *wrapped = makeHost(@"8.0.79", account, allowed);
        CHECK([wrapped readyForAccount:@"wxid_account" error:NULL] && wrapper.forwardAdds == 0);
        CHECK([wrapped.diagnostics[@"serviceChecks"][@"preflight"][@"forwarding"][@"rootCode"] isEqual:@1]);
        [wrapped submitRequest:request completion:nil];
        CHECK(wrapper.forwardAdds == 1 && wrapper.service.addCount == 1);
        CHECK(![[wrapped.diagnostics description] containsString:@"SRFake"]);
        context.manager = manager;
        context.rejectServiceSignature = YES;
        SRWeChatImageSendHost *serviceReadBlocked = makeHost(@"8.0.79", account, allowed);
        CHECK(![serviceReadBlocked readyForAccount:@"wxid_account" error:NULL]);
        CHECK([serviceReadBlocked.diagnostics[@"serviceChecks"][@"preflight"][@"serviceReadFailed"] boolValue]);
        CHECK([serviceReadBlocked.diagnostics[@"serviceChecks"][@"preflight"][@"contextClassCode"] isEqual:@1]);
        CHECK([serviceReadBlocked.diagnostics[@"serviceChecks"][@"preflight"][@"managerClassCode"] isEqual:@0]);
        context.rejectServiceSignature = NO;
        context.serviceReads = 0; context.substituteOnRead = 2; context.substitute = [badAdd new];
        SRWeChatImageSendHost *resolvedChanged = makeHost(@"8.0.79", account, allowed);
        __block NSUInteger blockedCompletions = 0;
        [resolvedChanged submitRequest:request completion:^(__unused NSString *value, NSString *messageID, NSString *detail) {
            if (!messageID && [detail isEqual:@"concrete_add_abi_incompatible"]) blockedCompletions++;
        }];
        CHECK(blockedCompletions == 1 && ![resolvedChanged.diagnostics[@"submissionAttempted"] boolValue]);
        CHECK([resolvedChanged.diagnostics[@"initializerCallType"] isEqual:@"not_called"]);
        CHECK([resolvedChanged.diagnostics[@"serviceChecks"][@"pre_submit"][@"add"][@"issue"] isEqual:@"return_type"]);
        context.substituteOnRead = 0; context.substitute = nil;
        __block NSUInteger accountReads = 0;
        SRWeChatImageSendHost *changed = makeHost(@"8.0.79", ^NSString * {
            if (++accountReads == 2) object_setClass(manager, badAdd);
            return @"wxid_account";
        }, allowed);
        [changed submitRequest:request completion:nil];
        CHECK([changed.diagnostics[@"initializerCallType"] isEqual:@"q"]);
        CHECK([changed.diagnostics[@"serviceChecks"][@"preflight"][@"add"][@"issue"] isEqual:@"compatible"]);
        CHECK([changed.diagnostics[@"serviceChecks"][@"pre_submit"][@"add"][@"issue"] isEqual:@"return_type"]);
        CHECK(![changed.diagnostics[@"submissionAttempted"] boolValue]);
        object_setClass(manager, SRFakeMessageMgr.class); CHECK(manager.addCount == count);
        CHECK(![changed readyForAccount:@"wxid_account" error:NULL]);
        CHECK([changed.diagnostics[@"attemptConsumed"] boolValue]);
        CHECK([changed.diagnostics[@"serviceChecks"] count] == 2);
        CHECK([changed.diagnostics[@"initializerCallType"] isEqual:@"q"]);
        CHECK(![[changed.diagnostics description] containsString:@"wxid_account"]);
        CHECK(![[changed.diagnostics description] containsString:@"hello"]);
        CHECK(![[changed.diagnostics description] containsString:@"SRFake"]);

        manager.deferServerID = YES;
        SRWeChatImageSendHost *delayed = makeHost(@"8.0.76", account, allowed);
        __block NSUInteger completions = 0;
        [delayed submitRequest:request completion:^(__unused NSString *value, __unused NSString *messageID, __unused NSString *detail) { completions++; }];
        CHECK([delayed.diagnostics[@"observing"] boolValue] && completions == 0);
        manager.lastWrap.m_n64MesSvrID = 9002; [delayed poll];
        CHECK(![delayed.diagnostics[@"observing"] boolValue] && completions == 1);
        [delayed stopObservation]; [delayed poll]; CHECK(completions == 1);

        SRWeChatImageSendHost *stopped = makeHost(@"8.0.79", account, allowed);
        completions = 0;
        [stopped submitRequest:request completion:^(__unused NSString *value, __unused NSString *messageID, __unused NSString *detail) { completions++; }];
        CHECK(completions == 0); [stopped stopObservation]; [stopped stopObservation]; CHECK(completions == 1);

        __block BOOL environment = YES;
        SRWeChatImageSendHost *inactive = makeHost(@"8.0.79", account, ^BOOL { return environment; });
        completions = 0;
        [inactive submitRequest:request completion:^(__unused NSString *value, __unused NSString *messageID, __unused NSString *detail) { completions++; }];
        environment = NO; [inactive poll]; CHECK(completions == 1);
        CHECK([inactive.diagnostics[@"problem"] isEqual:@"observation_environment_changed"]);

        manager.missLookup = YES;
        SRWeChatImageSendHost *bounded = makeHost(@"8.0.79", account, allowed);
        completions = 0;
        [bounded submitRequest:request completion:^(__unused NSString *value, __unused NSString *messageID, __unused NSString *detail) { completions++; }];
        for (NSUInteger index = 0; index < 40; index++) [bounded poll];
        CHECK(completions == 1 && [bounded.diagnostics[@"lookupAttempts"] unsignedIntegerValue] == 30);
        CHECK([bounded.diagnostics[@"lookupMisses"] unsignedIntegerValue] == 30);
        manager.missLookup = NO; manager.conflictLookup = YES;
        SRWeChatImageSendHost *conflict = makeHost(@"8.0.79", account, allowed);
        [conflict submitRequest:request completion:nil];
        CHECK([conflict.diagnostics[@"identityConflicts"] unsignedIntegerValue] == 1);
        CHECK(![conflict.diagnostics[@"observing"] boolValue]);
        manager.conflictLookup = NO; manager.throwAfterAdd = YES;
        SRWeChatImageSendHost *exception = makeHost(@"8.0.79", account, allowed);
        completions = 0;
        [exception submitRequest:request completion:^(__unused NSString *value, __unused NSString *messageID, __unused NSString *detail) { completions++; }];
        CHECK(completions == 1 && [exception.diagnostics[@"submissionAttempted"] boolValue]);
        CHECK(![exception.diagnostics[@"hostReturned"] boolValue]);
        CHECK([exception.diagnostics[@"deliveryOutcome"] isEqual:@"uncertain"]);
        CHECK(![[exception.diagnostics description] containsString:@"private body"]);
        count = manager.addCount; [exception submitRequest:request completion:nil]; CHECK(manager.addCount == count);
        context.manager = manager; context.substitute = nil; context.substituteOnRead = 0;
        manager.deferServerID = NO; manager.throwAfterAdd = NO; manager.conflictLookup = NO; manager.missLookup = NO;
        NSUInteger adds = manager.addCount, writes = ImageWrites;
        RejectImageMaterial = YES;
        SRWeChatImageSendHost *noMaterial = makeHost(@"8.0.79", account, allowed);
        [noMaterial submitRequest:request completion:nil];
        CHECK(manager.addCount == adds && ImageWrites == writes && [noMaterial.diagnostics[@"attemptConsumed"] boolValue]);
        RejectImageMaterial = NO; [noMaterial submitRequest:request completion:nil]; CHECK(manager.addCount == adds);
        InvalidImageABI = YES;
        SRWeChatImageSendHost *badImage = makeHost(@"8.0.79", account, allowed);
        [badImage submitRequest:request completion:nil];
        CHECK(manager.addCount == adds && ImageWrites == writes && ![badImage.diagnostics[@"imageSetterInvoked"] boolValue]);
        InvalidImageABI = NO; ThrowImageSetter = YES;
        SRWeChatImageSendHost *setterThrows = makeHost(@"8.0.79", account, allowed);
        [setterThrows submitRequest:request completion:nil];
        CHECK(manager.addCount == adds && ImageWrites == ++writes && [setterThrows.diagnostics[@"imageSetterInvoked"] boolValue]);
        CHECK(![setterThrows.diagnostics[@"submissionAttempted"] boolValue] && [setterThrows.diagnostics[@"nativeImageSideEffectsPossible"] boolValue]);
        CHECK(![[setterThrows.diagnostics description] containsString:@"private image"]);
        ThrowImageSetter = NO; [setterThrows submitRequest:request completion:nil]; CHECK(ImageWrites == writes);
        MutateImageIdentity = YES;
        SRWeChatImageSendHost *identityChanged = makeHost(@"8.0.79", account, allowed);
        [identityChanged submitRequest:request completion:nil];
        CHECK(manager.addCount == adds && ImageWrites == writes); MutateImageIdentity = NO;
        __block BOOL imageEnvironment = YES;
        SRWeChatImageSendHost *setterChangesAccount = makeHost(@"8.0.79", account, ^BOOL { return imageEnvironment; });
        OnImageSetter = ^{ imageEnvironment = NO; };
        [setterChangesAccount submitRequest:request completion:nil];
        CHECK(manager.addCount == adds && ImageWrites == ++writes); OnImageSetter = nil;
        __block SRWeChatImageSendHost *reentrant = makeHost(@"8.0.79", account, allowed);
        OnImageSetter = ^{ [reentrant submitRequest:request completion:nil]; };
        [reentrant submitRequest:request completion:nil];
        CHECK(manager.addCount <= adds + 1 && ImageWrites == ++writes);
        OnImageSetter = nil; [reentrant stopObservation]; reentrant = nil;
        UseLongSetter = YES; adds = manager.addCount;
        SRWeChatImageSendHost *longImage = makeHost(@"8.0.79", account, allowed);
        [longImage submitRequest:request completion:nil];
        CHECK(ImageWrites == ++writes && manager.addCount == adds + 1);
        CHECK([longImage.diagnostics[@"selectedSelector"] isEqual:@"long"]);
        UseLongSetter = NO;
        puts("PASS: image type-3 i/I/q/Q construction, original proxy service contract, origin BOOL setter, material/identity gates, side effects, reentrancy, bounded exact-ID observation and no retries");
    }
    return 0;
}
