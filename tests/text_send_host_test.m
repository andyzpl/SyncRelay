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
- (instancetype)initWithMsgType:(unsigned int)type;
@end

@interface SRFakeMessageMgr : NSObject
@property(nonatomic, strong) SRFakeMessageWrap *lastWrap;
@property(nonatomic, copy) NSString *lastTarget;
@property(nonatomic) NSUInteger addCount;
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
    wrap.m_uiMesLocalID = 42; wrap.m_n64MesSvrID = 9001;
}
- (SRFakeMessageWrap *)GetMsg:(NSString *)target LocalID:(unsigned long long)localID {
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

int main(void) {
    @autoreleasepool {
        SRFakeMessageMgr *manager = [SRFakeMMContext currentContext].manager;
        SRWeChatTextSendHost *host = [[SRWeChatTextSendHost alloc] initWithVersion:@"8.0.79"
            classResolver:^Class(NSString *name) {
                return @{ @"MMContext": SRFakeMMContext.class, @"CMessageMgr": SRFakeMessageMgr.class,
                          @"CMessageWrap": SRFakeMessageWrap.class }[name];
            }
            currentAccount:^NSString *{ return @"wxid_account"; }
            environmentAllowed:^BOOL{ return YES; }];
        NSError *readyError = nil;
        BOOL ready = [host readyForAccount:@"wxid_account" error:&readyError];
        if (!ready) fprintf(stderr, "ready error: %s\n", readyError.localizedDescription.UTF8String);
        CHECK(ready);
        __block NSString *state = nil; __block NSString *reason = nil; __block BOOL callbackShapeOK = NO;
        [host submitRequest:@{ @"account": @"wxid_account", @"target": @"room@chatroom",
            @"payload": @{ @"text": @"hello" } } completion:^(NSString *value, NSString *messageID, NSString *detail) {
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
        CHECK([reason containsString:@"delivery"] || [reason containsString:@"association"]);
        CHECK([host.diagnostics[@"state"] isEqual:@"associated"]);
        NSUInteger count = manager.addCount;
        [host submitRequest:@{ @"account": @"wxid_account", @"target": @"not-a-group", @"payload": @{ @"text": @"x" } }
            completion:^(NSString *value, NSString *messageID, NSString *detail) {
                callbackShapeOK = [value isEqual:@"uncertain"] && messageID == nil && detail.length > 0;
            }];
        CHECK(manager.addCount == count);
        CHECK(callbackShapeOK);
        puts("PASS: version-gated single-text host construction, AddMsg invocation and non-delivery association gate");
    }
    return 0;
}
