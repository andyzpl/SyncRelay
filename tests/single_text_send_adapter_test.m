#import <Foundation/Foundation.h>
#import "Adapter/SRWeChatTextSendAdapter.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

@interface FakeMessageMgr : NSObject
- (void)AddMsg:(id)session MsgWrap:(id)wrap;
@end
@implementation FakeMessageMgr
- (void)AddMsg:(id)session MsgWrap:(id)wrap { (void)session; (void)wrap; }
@end
@interface FakeMessageWrap : NSObject
- (NSString *)m_nsFromUsr;
- (NSString *)m_nsToUsr;
- (NSString *)m_nsContent;
- (unsigned int)m_uiMessageType;
- (unsigned int)m_uiMesLocalID;
- (long long)m_n64MesSvrID;
- (unsigned int)m_uiStatus;
@end
@implementation FakeMessageWrap
- (NSString *)m_nsFromUsr { return nil; }
- (NSString *)m_nsToUsr { return nil; }
- (NSString *)m_nsContent { return nil; }
- (unsigned int)m_uiMessageType { return 0; }
- (unsigned int)m_uiMesLocalID { return 0; }
- (long long)m_n64MesSvrID { return 0; }
- (unsigned int)m_uiStatus { return 0; }
@end
@interface WrongMessageMgr : NSObject
- (id)AddMsg:(id)session MsgWrap:(id)wrap;
@end
@implementation WrongMessageMgr
- (id)AddMsg:(id)session MsgWrap:(id)wrap { (void)session; (void)wrap; return nil; }
@end

static NSDictionary *source(void) {
    return @{
        @"account": @"account", @"group": @"mother@chatroom", @"sender": @"wxid_sender",
        @"messageID": @"source-message", @"type": @"text", @"generatedByRelay": @NO,
        @"payload": @{@"text": @"source text"}
    };
}

static Class (^resolverFor(Class manager))(NSString *) {
    return ^Class(NSString *name) {
        if ([name isEqual:@"CMessageMgr"]) return manager;
        if ([name isEqual:@"CMessageWrap"]) return FakeMessageWrap.class;
        return Nil;
    };
}

int main(void) {
    @autoreleasepool {
        __block BOOL environment = YES;
        SRWeChatTextSendAdapter *disabled = [[SRWeChatTextSendAdapter alloc] initWithVersion:@"8.0.79"
            classResolver:resolverFor(FakeMessageMgr.class) currentAccount:^NSString *{ return @"account"; }
            environmentAllowed:^BOOL{ return environment; } operation:nil];
        CHECK([disabled prepareForAccount:@"account" targetGroup:@"target@chatroom" sourceSnapshot:source() confirmed:YES error:NULL]);
        CHECK(![disabled canSendForAccount:@"account"]);
        CHECK(![disabled.diagnostics[@"operationInjected"] boolValue] && [disabled.diagnostics[@"abiValidated"] boolValue]);

        __block NSUInteger calls = 0; __block NSDictionary *request = nil; __block NSString *result = nil;
        SRWeChatTextSendAdapter *adapter = [[SRWeChatTextSendAdapter alloc] initWithVersion:@"8.0.79"
            classResolver:resolverFor(FakeMessageMgr.class) currentAccount:^NSString *{ return @"account"; }
            environmentAllowed:^BOOL{ return environment; }
            operation:^(NSDictionary *value, SRSendCompletion completion) {
                calls++; request = value; completion(@"confirmed", @"server-message", nil);
            }];
        CHECK([adapter prepareForAccount:@"account" targetGroup:@"target@chatroom" sourceSnapshot:source() confirmed:YES error:NULL]);
        CHECK([adapter canSendForAccount:@"account"]);
        NSDictionary *delivery = @{ @"id": @"delivery", @"target": @"target@chatroom", @"position": @0,
            @"state": @"submitting", @"attempt_id": @"attempt" };
        [adapter submitDelivery:delivery snapshot:source() completion:^(NSString *state, NSString *messageID, NSString *reason) {
            (void)messageID; (void)reason; result = state;
        }];
        CHECK(calls == 1 && [result isEqual:@"confirmed"] && [request[@"type"] isEqual:@"text"]);
        CHECK([request[@"target"] isEqual:@"target@chatroom"] && [request[@"payload"][@"text"] isEqual:@"source text"]);
        CHECK([adapter.diagnostics[@"outcome"] isEqual:@"confirmed"] && [adapter.diagnostics[@"callbackCount"] isEqual:@1]);
        [adapter submitDelivery:delivery snapshot:source() completion:^(NSString *state, NSString *messageID, NSString *reason) {
            (void)messageID; (void)reason; CHECK([state isEqual:@"uncertain"]);
        }];
        CHECK(calls == 1);

        SRWeChatTextSendAdapter *blocked = [[SRWeChatTextSendAdapter alloc] initWithVersion:@"8.0.79"
            classResolver:resolverFor(FakeMessageMgr.class) currentAccount:^NSString *{ return @"account"; }
            environmentAllowed:^BOOL{ return environment; } operation:^(__unused NSDictionary *request, __unused SRSendCompletion completion) {}];
        CHECK(![blocked prepareForAccount:@"account" targetGroup:@"target@chatroom" sourceSnapshot:source() confirmed:NO error:NULL]);
        CHECK([blocked prepareForAccount:@"account" targetGroup:@"target@chatroom" sourceSnapshot:source() confirmed:YES error:NULL]);

        SRWeChatTextSendAdapter *wrongABI = [[SRWeChatTextSendAdapter alloc] initWithVersion:@"8.0.79"
            classResolver:resolverFor(WrongMessageMgr.class) currentAccount:^NSString *{ return @"account"; }
            environmentAllowed:^BOOL{ return YES; } operation:nil];
        CHECK(![wrongABI prepareForAccount:@"account" targetGroup:@"target@chatroom" sourceSnapshot:source() confirmed:YES error:NULL]);
        puts("PASS: single-target text adapter confirmation, ABI gate, frozen snapshot, disabled default and no retry");
    }
    return 0;
}
