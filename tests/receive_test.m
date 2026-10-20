#import <Foundation/Foundation.h>
#import "Adapter/SRRuntime.h"
#import "Adapter/SRWeChatReceiver.h"
#import "Core/SRConfiguration.h"
#import "Core/SRSourceCapture.h"
#import "Core/SRStore.h"
#include <assert.h>
#include <limits.h>
#define CHECK(...) assert((__VA_ARGS__))

@interface ReceiveWrap : NSObject
@property(nonatomic, copy) NSString *m_nsFromUsr;
@property(nonatomic, copy) NSString *m_nsToUsr;
@property(nonatomic, copy) NSString *m_nsRealChatUsr;
@property(nonatomic, copy) NSString *m_nsContent;
@property(nonatomic) unsigned int m_uiMessageType;
@property(nonatomic) unsigned long long m_n64MesSvrID;
@end
@implementation ReceiveWrap
@end
@interface ReceiveManager : NSObject
@property(nonatomic) NSUInteger calls;
- (void)AsyncOnAddMsg:(id)session MsgWrap:(id)wrap;
@end
@implementation ReceiveManager
- (void)AsyncOnAddMsg:(__unused id)session MsgWrap:(__unused id)wrap { self.calls++; }
@end
@interface InvalidReceiveManager : NSObject
- (id)AsyncOnAddMsg:(id)session MsgWrap:(id)wrap;
@end
@implementation InvalidReceiveManager
- (id)AsyncOnAddMsg:(__unused id)session MsgWrap:(__unused id)wrap { abort(); }
@end
@interface InheritedReceiveManager : ReceiveManager
@end
@implementation InheritedReceiveManager
@end
@interface ScalarTraps : NSObject
- (double)floating;
- (id)object;
- (void *)pointer;
- (long long)negative;
- (unsigned long long)maximum;
- (unsigned int)integer;
- (long long)throwing;
@end
@implementation ScalarTraps
- (double)floating { abort(); }
- (id)object { abort(); }
- (void *)pointer { abort(); }
- (long long)negative { return -1; }
- (unsigned long long)maximum { return ULLONG_MAX; }
- (unsigned int)integer { return 3; }
- (long long)throwing { @throw [NSException exceptionWithName:@"Fixture" reason:@"secret message body" userInfo:nil]; }
@end
static ReceiveWrap *wrap(void) {
    ReceiveWrap *value = [[ReceiveWrap alloc] init];
    value.m_nsFromUsr = @"mother@chatroom"; value.m_nsToUsr = @"wxid_account";
    value.m_nsRealChatUsr = @"wxid_sender"; value.m_nsContent = @"original message";
    value.m_uiMessageType = 1; value.m_n64MesSvrID = 9007199254740993ULL; return value;
}
static void pump(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false); }
static NSMutableDictionary *draft(void) {
    NSMutableDictionary *value = [SRConfiguration emptyDraft];
    value[@"sourceGroup"] = @{@"id": @"mother@chatroom", @"name": @"Mother"};
    value[@"senders"] = @[@{@"id": @"wxid_sender", @"name": @"Same name"}];
    value[@"rules"] = @[@{@"id": @"rule", @"name": @"First", @"targets": @[@{@"id": @"target@chatroom", @"name": @"Target"}]}];
    return value;
}
int main(void) {
    @autoreleasepool {
        ScalarTraps *traps = [[ScalarTraps alloc] init];
        for (NSString *name in @[@"floating", @"object", @"pointer", @"missing", @"negative", @"throwing"])
            CHECK(!SRReadUnsignedInteger(traps, name, NULL));
        CHECK([SRReadUnsignedInteger(traps, @"maximum", NULL) unsignedLongLongValue] == ULLONG_MAX);
        CHECK([SRReadUnsignedInteger(traps, @"integer", NULL) isEqual:@3]);
        NSError *error = nil; CHECK(!SRReadUnsignedInteger(traps, @"throwing", &error));
        CHECK(error && ![error.localizedDescription containsString:@"secret message"]);
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        SRStore *store = [[SRStore alloc] initWithPath:[directory stringByAppendingPathComponent:@"receive.sqlite3"] error:NULL]; CHECK(store);
        SRSourceCapture *capture = [[SRSourceCapture alloc] initWithStore:store];
        __block NSString *current = @"wxid_account"; NSMutableArray *received = [NSMutableArray array];
        __block __weak SRWeChatReceiver *weakReceiver;
        SRWeChatReceiver *(^makeReceiver)(NSString *, Class) = ^(NSString *version, Class manager) {
            return [[SRWeChatReceiver alloc] initWithVersion:version classResolver:^Class(NSString *name) {
                return [name isEqual:@"CMessageMgr"] ? manager : ([name isEqual:@"CMessageWrap"] ? ReceiveWrap.class : Nil);
            } currentAccount:^NSString *{ CHECK(NSThread.isMainThread); return current; } received:^(NSDictionary *message) {
                CHECK(NSThread.isMainThread); [received addObject:message];
                if ([capture offerEnvelope:message]) [weakReceiver stop];
            }];
        };
        SRWeChatReceiver *receiver = makeReceiver(@"8.0.79", ReceiveManager.class); weakReceiver = receiver;
        ReceiveManager *manager = [[ReceiveManager alloc] init];
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:wrap()]; pump(); CHECK(manager.calls == 1 && !received.count);
        CHECK(![makeReceiver(@"8.0.80", ReceiveManager.class) armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        CHECK(![makeReceiver(@"8.0.79", InvalidReceiveManager.class) armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        SRWeChatReceiver *missingWrap = [[SRWeChatReceiver alloc] initWithVersion:@"8.0.79" classResolver:^Class(NSString *name) {
            return [name isEqual:@"CMessageMgr"] ? ReceiveManager.class : Nil;
        } currentAccount:^NSString *{ return current; } received:^(__unused NSDictionary *message) { abort(); }];
        CHECK(![missingWrap armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        CHECK([capture armForAccount:current configuration:draft() error:NULL]);
        CHECK([receiver armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        CHECK(![receiver armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        CHECK(![makeReceiver(@"8.0.76", ReceiveManager.class) armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        for (NSString *key in @[@"m_nsFromUsr", @"m_nsToUsr", @"m_nsRealChatUsr"]) {
            ReceiveWrap *bad = wrap(); [bad setValue:@"wrong@chatroom" forKey:key];
            [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:bad];
        }
        ReceiveWrap *selfMessage = wrap(); selfMessage.m_nsRealChatUsr = current;
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:selfMessage];
        ReceiveWrap *missingSender = wrap(); missingSender.m_nsRealChatUsr = nil;
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:missingSender];
        ReceiveWrap *localOnly = wrap(); localOnly.m_n64MesSvrID = 0;
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:localOnly];
        ReceiveWrap *image = wrap(); image.m_uiMessageType = 3;
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:image];
        [manager AsyncOnAddMsg:@"other@chatroom" MsgWrap:wrap()]; pump();
        CHECK(received.count == 0 && !capture.preview);
        ReceiveWrap *otherSender = wrap(); otherSender.m_nsRealChatUsr = @"wxid_other";
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:otherSender]; pump();
        CHECK(received.count == 1 && !capture.preview);
        ReceiveWrap *original = wrap(); NSUInteger before = manager.calls;
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:original]; original.m_nsContent = @"mutated"; pump();
        CHECK(manager.calls == before + 1 && received.count == 2);
        CHECK([capture.preview[@"payload"][@"text"] isEqual:@"original message"]);
        CHECK([capture.preview[@"messageID"] isEqual:@"svr:9007199254740993"]);
        CHECK([capture.status[@"state"] isEqual:@"preview"] && ![receiver.diagnostics[@"armed"] boolValue]);
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:wrap()]; pump(); CHECK(received.count == 2);
        CHECK([store plansForAccount:current limit:50 offset:0 error:NULL].count == 0);
        CHECK(![capture confirmForCurrentAccount:@"wxid_other" error:NULL]);
        NSString *plan = [capture confirmForCurrentAccount:current error:NULL]; CHECK(plan);
        CHECK([store plansForAccount:current limit:50 offset:0 error:NULL].count == 1);
        CHECK([capture.status[@"state"] isEqual:@"idle"]);
        CHECK([[store ruleCardsForPlan:plan account:current error:NULL][0][@"latestRun"] isEqual:NSNull.null]);
        NSString *diagnostics = receiver.diagnostics.description;
        CHECK(![diagnostics containsString:@"wxid_account"] && ![diagnostics containsString:@"original message"]);

        // Stopped/re-armed captures must not consume a callback queued by an older generation.
        CHECK([capture armForAccount:current configuration:draft() error:NULL]);
        CHECK([receiver armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:wrap()];
        [receiver stop]; [capture cancel];
        CHECK([capture armForAccount:current configuration:draft() error:NULL]);
        CHECK([receiver armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]); pump();
        CHECK(!capture.preview && received.count == 2);
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:wrap()]; current = @"wxid_switched"; pump();
        CHECK(!capture.preview && received.count == 2 && ![receiver.diagnostics[@"armed"] boolValue]);
        [capture cancel]; current = @"wxid_account";
        SRWeChatReceiver *replacement = makeReceiver(@"8.0.76", ReceiveManager.class); weakReceiver = replacement;
        CHECK([replacement armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        before = manager.calls; [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:wrap()]; pump();
        CHECK(manager.calls == before + 1 && received.count == 3); [replacement stop];
        SRWeChatReceiver *inherited = makeReceiver(@"8.0.79", InheritedReceiveManager.class); weakReceiver = inherited;
        CHECK([inherited armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        InheritedReceiveManager *subclass = [[InheritedReceiveManager alloc] init];
        [subclass AsyncOnAddMsg:@"mother@chatroom" MsgWrap:wrap()]; pump();
        CHECK(subclass.calls == 1 && received.count == 4); [inherited stop];
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:wrap()]; pump(); CHECK(received.count == 4);
        [receiver stop]; [capture cancel]; receiver = nil; replacement = nil; inherited = nil; makeReceiver = nil; capture = nil; store = nil;
        CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: guarded receive candidate, original hook chain, exact server IDs, wxid/text filters, frozen preview and account/generation cancellation");
    }
    return 0;
}
