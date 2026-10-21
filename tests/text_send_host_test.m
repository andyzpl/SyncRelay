#import <Foundation/Foundation.h>
#import "Adapter/SRWeChatTextSendHost.h"

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "FAIL:%d %s\n", __LINE__, #condition); return 1; } } while (0)

@interface SRFakeMessageWrap : NSObject
@property(nonatomic, copy) NSString *m_nsFromUsr;
@property(nonatomic, copy) NSString *m_nsToUsr;
@property(nonatomic, copy) NSString *m_nsContent;
@property(nonatomic) unsigned int m_uiMessageType;
@property(nonatomic) unsigned int m_uiMesLocalID;
@property(nonatomic) unsigned long long m_n64MesSvrID;
@property(nonatomic) unsigned int m_uiCreateTime;
@property(nonatomic) unsigned int m_uiStatus;
- (instancetype)initWithMsgType:(unsigned int)type;
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
@end

@implementation SRFakeMessageWrap
- (instancetype)initWithMsgType:(unsigned int)type { self = [super init]; if (self) _m_uiMessageType = type; return self; }
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

@implementation SRFakeMMContext
+ (instancetype)currentContext {
    static SRFakeMMContext *context; static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [SRFakeMMContext new]; context.manager = [SRFakeMessageMgr new]; });
    return context;
}
- (id)getService:(Class)type { return type == SRFakeMessageMgr.class ? self.manager : nil; }
@end

static SRWeChatTextSendHost *makeHost(NSString *version, NSString *(^account)(void), BOOL (^allowed)(void)) {
    return [[SRWeChatTextSendHost alloc] initWithVersion:version classResolver:^Class(NSString *name) {
        return @{ @"MMContext": SRFakeMMContext.class, @"CMessageMgr": SRFakeMessageMgr.class,
                  @"CMessageWrap": SRFakeMessageWrap.class }[name];
    } currentAccount:account environmentAllowed:allowed];
}

int main(void) {
    @autoreleasepool {
        SRFakeMessageMgr *manager = [SRFakeMMContext currentContext].manager;
        NSString *(^account)(void) = ^NSString * { return @"wxid_account"; };
        BOOL (^allowed)(void) = ^BOOL { return YES; };
        SRWeChatTextSendHost *host = makeHost(@"8.0.79", account, allowed);
        NSDictionary *request = @{ @"account": @"wxid_account", @"target": @"room@chatroom", @"type": @"text",
            @"sourceGroup": @"mother@chatroom", @"sourceSender": @"wxid_sender", @"sourceMessageID": @"source-1",
            @"payload": @{ @"text": @"hello" } };
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
        CHECK([manager.lastWrap.m_nsContent isEqual:@"hello"]);
        CHECK(manager.lastWrap.m_uiMessageType == 1 && manager.lastWrap.m_uiMesLocalID == 42);
        CHECK(callbackShapeOK);
        CHECK([state isEqual:@"uncertain"]);
        CHECK([reason containsString:@"unknown"] || [reason containsString:@"delivery"]);
        CHECK([host.diagnostics[@"state"] isEqual:@"uncertain"]);
        NSUInteger count = manager.addCount;
        [host submitRequest:request completion:nil];
        CHECK(manager.addCount == count);
        [host submitRequest:@{ @"account": @"wxid_account", @"target": @"not-a-group", @"type": @"text",
            @"sourceGroup": @"mother@chatroom", @"sourceSender": @"wxid_sender", @"sourceMessageID": @"source-1",
            @"payload": @{ @"text": @"x" } }
            completion:^(NSString *value, NSString *messageID, NSString *detail) {
                callbackShapeOK = [value isEqual:@"uncertain"] && messageID == nil && detail.length > 0;
            }];
        CHECK(manager.addCount == count);
        CHECK(callbackShapeOK);

        CHECK(![makeHost(@"8.0.80", account, allowed) readyForAccount:@"wxid_account" error:NULL]);
        CHECK(![makeHost(@"8.0.79", account, ^BOOL { return NO; }) readyForAccount:@"wxid_account" error:NULL]);
        CHECK(![makeHost(@"8.0.79", ^NSString * { return @"wxid_other"; }, allowed) readyForAccount:@"wxid_account" error:NULL]);
        SRWeChatTextSendHost *missing = [[SRWeChatTextSendHost alloc] initWithVersion:@"8.0.79"
            classResolver:^Class(__unused NSString *name) { return Nil; } currentAccount:account environmentAllowed:allowed];
        CHECK(![missing readyForAccount:@"wxid_account" error:NULL]);
        CHECK(manager.addCount == count);

        manager.deferServerID = YES;
        SRWeChatTextSendHost *delayed = makeHost(@"8.0.76", account, allowed);
        __block NSUInteger completions = 0;
        [delayed submitRequest:request completion:^(__unused NSString *value, __unused NSString *messageID, __unused NSString *detail) { completions++; }];
        CHECK([delayed.diagnostics[@"observing"] boolValue] && completions == 0);
        manager.lastWrap.m_n64MesSvrID = 9002; [delayed poll];
        CHECK(![delayed.diagnostics[@"observing"] boolValue] && completions == 1);
        [delayed stopObservation]; [delayed poll]; CHECK(completions == 1);

        SRWeChatTextSendHost *stopped = makeHost(@"8.0.79", account, allowed);
        completions = 0;
        [stopped submitRequest:request completion:^(__unused NSString *value, __unused NSString *messageID, __unused NSString *detail) { completions++; }];
        CHECK(completions == 0); [stopped stopObservation]; [stopped stopObservation]; CHECK(completions == 1);

        __block BOOL environment = YES;
        SRWeChatTextSendHost *inactive = makeHost(@"8.0.79", account, ^BOOL { return environment; });
        completions = 0;
        [inactive submitRequest:request completion:^(__unused NSString *value, __unused NSString *messageID, __unused NSString *detail) { completions++; }];
        environment = NO; [inactive poll]; CHECK(completions == 1);
        CHECK([inactive.diagnostics[@"problem"] isEqual:@"observation_environment_changed"]);

        manager.missLookup = YES;
        SRWeChatTextSendHost *bounded = makeHost(@"8.0.79", account, allowed);
        completions = 0;
        [bounded submitRequest:request completion:^(__unused NSString *value, __unused NSString *messageID, __unused NSString *detail) { completions++; }];
        for (NSUInteger index = 0; index < 40; index++) [bounded poll];
        CHECK(completions == 1 && [bounded.diagnostics[@"lookupAttempts"] unsignedIntegerValue] == 30);
        CHECK([bounded.diagnostics[@"lookupMisses"] unsignedIntegerValue] == 30);
        manager.missLookup = NO; manager.conflictLookup = YES;
        SRWeChatTextSendHost *conflict = makeHost(@"8.0.79", account, allowed);
        [conflict submitRequest:request completion:nil];
        CHECK([conflict.diagnostics[@"identityConflicts"] unsignedIntegerValue] == 1);
        CHECK(![conflict.diagnostics[@"observing"] boolValue]);
        manager.conflictLookup = NO; manager.throwAfterAdd = YES;
        SRWeChatTextSendHost *exception = makeHost(@"8.0.79", account, allowed);
        completions = 0;
        [exception submitRequest:request completion:^(__unused NSString *value, __unused NSString *messageID, __unused NSString *detail) { completions++; }];
        CHECK(completions == 1 && [exception.diagnostics[@"submissionAttempted"] boolValue]);
        CHECK(![exception.diagnostics[@"hostReturned"] boolValue]);
        CHECK([exception.diagnostics[@"deliveryOutcome"] isEqual:@"uncertain"]);
        CHECK(![[exception.diagnostics description] containsString:@"private body"]);
        count = manager.addCount; [exception submitRequest:request completion:nil]; CHECK(manager.addCount == count);
        puts("PASS: single-text ABI/account gates, one invocation, bounded observation, cancellation, conflicts and unknown delivery");
    }
    return 0;
}
