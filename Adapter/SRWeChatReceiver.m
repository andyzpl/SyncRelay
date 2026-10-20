#import "SRWeChatReceiver.h"
#import "SRRuntime.h"
#import "Core/SRSourceMessage.h"
#import <objc/runtime.h>
#include <string.h>

@class SRReceiveTap;
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
- (void)observeSession:(id)session wrap:(id)wrap;
@end

@interface SRReceiveTap : NSObject
@property(nonatomic) IMP original;
@property(nonatomic, weak) SRWeChatReceiver *listener;
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
    } @catch (__unused NSException *exception) { return NO; }
}
static BOOL SRReceiveGetter(Class type, NSString *name, BOOL integer) {
    Method method = type ? class_getInstanceMethod(type, NSSelectorFromString(name)) : NULL;
    if (!method) return NO;
    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        const char *result = SRReceiveType(signature.methodReturnType);
        if (signature.numberOfArguments != 2 || !result[0]) return NO;
        return integer ? strchr("iIqQlLsScC", result[0]) != NULL : (result[0] == '@' && result[1] != '?');
    } @catch (__unused NSException *exception) { return NO; }
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
- (BOOL)armForAccount:(NSString *)account sourceGroup:(NSString *)group error:(NSError **)error {
    if (!NSThread.isMainThread) return [self fail:@"Receive capture must be armed on the main thread" error:error];
    if (![@[@"8.0.76", @"8.0.79"] containsObject:self.version]) return [self fail:@"This version has no receive candidate" error:error];
    if (!account.length || [account hasSuffix:@"@chatroom"] || ![group hasSuffix:@"@chatroom"])
        return [self fail:@"A stable account and source group are required" error:error];
    @synchronized(self) { if (self.armed) return [self fail:@"Stop the current capture before arming again" error:error]; }
    @try { if (![self.currentAccount() isEqual:account]) return [self fail:@"Account changed before capture" error:error]; }
    @catch (__unused NSException *exception) { return [self fail:@"Cannot verify the current account" error:error]; }
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
                ((void (*)(id, SEL, id, id))installed.original)(object, selector, session, wrap);
                // Never let optional observation exceptions change WeChat's receive behavior.
                @try { [installed.listener observeSession:session wrap:wrap]; } @catch (__unused NSException *exception) { }
            });
            if (!class_addMethod(manager, selector, replacement, method_getTypeEncoding(method)))
                tap.original = method_setImplementation(class_getInstanceMethod(manager, selector), replacement);
            SRTaps()[key] = tap;
        }
        @synchronized(self) {
            self.account = account; self.group = group; self.problem = nil; self.generation++;
            self.tap = tap; self.armed = YES; tap.listener = self;
        }
    }
    return YES;
}
- (void)observeSession:(id)session wrap:(id)wrap {
    NSString *account, *group; NSUInteger generation;
    @synchronized(self) {
        if (!self.armed) return;
        account = self.account; group = self.group; generation = self.generation;
    }
    if (![session isKindOfClass:NSString.class] || ![session isEqual:group]) return;
    NSString *from = SRReadString(wrap, @"m_nsFromUsr"), *to = SRReadString(wrap, @"m_nsToUsr");
    NSString *sender = SRReadString(wrap, @"m_nsRealChatUsr");
    if (![from isEqual:group] || ![to isEqual:account] || !sender.length || [sender isEqual:account] ||
        [sender hasSuffix:@"@chatroom"] ||
        [sender rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return;
    NSNumber *type = SRReadUnsignedInteger(wrap, @"m_uiMessageType", NULL);
    NSNumber *serverID = SRReadUnsignedInteger(wrap, @"m_n64MesSvrID", NULL);
    // Images need verified media preparation; no XML-as-path or temporary/local ID fallback.
    if (![type isEqual:@1] || !serverID.unsignedLongLongValue) return;
    NSString *content = SRReadString(wrap, @"m_nsContent");
    if (!content.length) return;
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
                [receiver stop]; [receiver fail:@"Account changed; receive capture stopped" error:NULL]; return;
            }
            @synchronized(receiver) { if (!receiver.armed || receiver.generation != generation) return; }
            receiver.received(message);
        } @catch (__unused NSException *exception) {
            [receiver stop]; [receiver fail:@"Receive callback failed; capture stopped" error:NULL];
        }
    });
}
- (void)stop {
    @synchronized(SRTaps()) {
        @synchronized(self) {
            self.armed = NO; self.generation++;
            if (self.tap.listener == self) self.tap.listener = nil;
            self.account = nil; self.group = nil;
        }
    }
}
- (NSDictionary *)diagnostics {
    @synchronized(self) {
        Class manager = self.resolver(@"CMessageMgr"), wrap = self.resolver(@"CMessageWrap");
        NSMutableArray *methods = [NSMutableArray arrayWithObject:SRDescribeInstanceMethod(manager, @"AsyncOnAddMsg:MsgWrap:")];
        for (NSString *name in @[@"m_nsFromUsr", @"m_nsToUsr", @"m_nsRealChatUsr", @"m_uiMessageType", @"m_n64MesSvrID", @"m_nsContent"])
            [methods addObject:SRDescribeInstanceMethod(wrap, name)];
        return @{@"wechatVersion": self.version, @"armed": @(self.armed), @"installed": @(self.tap != nil),
            @"textOnlyCandidate": @YES, @"sendingEnabled": @NO, @"problem": self.problem ?: @"", @"methods": methods};
    }
}
@end
