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
@property(nonatomic) unsigned int m_uiMesLocalID;
@end
@implementation ReceiveWrap
@end
@interface ReceiveManager : NSObject
@property(nonatomic) NSUInteger calls;
@property(nonatomic) BOOL raiseOriginal;
@property(nonatomic, strong) ReceiveWrap *stored;
@property(nonatomic, copy) NSString *lookupGroup;
@property(nonatomic) unsigned int lookupLocalID;
- (void)AsyncOnAddMsg:(id)session MsgWrap:(id)wrap;
- (void)AddMsg:(id)session MsgWrap:(id)wrap;
- (id)GetMsg:(NSString *)group LocalID:(unsigned int)localID;
@end
@implementation ReceiveManager
- (void)AsyncOnAddMsg:(__unused id)session MsgWrap:(__unused id)wrap { self.calls++; }
- (void)AddMsg:(__unused id)session MsgWrap:(__unused id)wrap {
    self.calls++; if (self.raiseOriginal) @throw @"OriginalOutgoingException";
}
- (id)GetMsg:(NSString *)group LocalID:(unsigned int)localID {
    self.lookupGroup = group; self.lookupLocalID = localID; return self.stored;
}
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
@interface ThrowingReceiveWrap : ReceiveWrap
@end
@implementation ThrowingReceiveWrap
- (NSString *)m_nsContent { @throw @"OptionalGetterException"; }
@end
@interface ReflectedReceiveWrap : ReceiveWrap
@end
@implementation ReflectedReceiveWrap
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (selector == @selector(m_nsFromUsr) || selector == @selector(m_nsToUsr) ||
        selector == @selector(m_nsRealChatUsr) || selector == @selector(m_nsContent))
        return [NSMethodSignature signatureWithObjCTypes:"v@:"];
    return [super methodSignatureForSelector:selector];
}
@end
@interface DirectionManager : ReceiveManager
@property(nonatomic) BOOL rewriteDirection;
@property(nonatomic, copy) void (^duringOriginal)(void);
@end
@implementation DirectionManager
- (void)AddMsg:(id)session MsgWrap:(id)value {
    [super AddMsg:session MsgWrap:value];
    if (self.duringOriginal) self.duringOriginal();
    if (self.rewriteDirection && [value isKindOfClass:ReceiveWrap.class])
        ((ReceiveWrap *)value).m_nsFromUsr = session;
}
@end
@interface DirectionThrowWrap : ReceiveWrap
@end
@implementation DirectionThrowWrap
- (NSString *)m_nsFromUsr { @throw @"private getter exception"; }
@end
@interface DirectionNumberWrap : ReceiveWrap
@end
@implementation DirectionNumberWrap
- (NSString *)m_nsFromUsr { return (id)@123; }
@end
@interface DirectionScalarWrap : NSObject
- (double)m_nsFromUsr;
@end
@implementation DirectionScalarWrap
- (double)m_nsFromUsr { abort(); }
@end
@interface DirectionBodyWrap : ReceiveWrap
@property(nonatomic) NSUInteger bodyReads;
@end
@implementation DirectionBodyWrap
- (NSString *)m_nsContent { self.bodyReads++; return @"private diagnostic body"; }
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
    value.m_uiMessageType = 1; value.m_n64MesSvrID = 9007199254740993ULL; value.m_uiMesLocalID = 42; return value;
}
static void pump(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false); }
static NSMutableDictionary *draft(void) {
    NSMutableDictionary *value = [SRConfiguration emptyDraft];
    value[@"sourceGroup"] = @{@"id": @"mother@chatroom", @"name": @"Mother"};
    value[@"senders"] = @[@{@"id": @"wxid_sender", @"name": @"Same name"}];
    value[@"rules"] = @[@{@"id": @"rule", @"name": @"First", @"targets": @[@{@"id": @"target@chatroom", @"name": @"Target"}]}];
    return value;
}
@interface SRWeChatReceiver (ImageFixture)
- (void)pollImage:(id)pending generation:(NSUInteger)generation remaining:(NSUInteger)remaining;
@end
static NSDictionary *imagePayload(void) {
    return @{@"snapshotSchema": @1, @"mediaReference": @"11111111-2222-4333-8444-555555555555",
        @"sha256": [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],
        @"scopeSHA256": [@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0],
        @"byteCount": @100, @"pixelWidth": @2, @"pixelHeight": @3, @"format": @"png"};
}
static void checkImageCapture(void) {
    __block NSString *account = @"wxid_account";
    __block NSUInteger reads = 0, discards = 0, mode = 0;
    NSMutableArray *received = [NSMutableArray array];
    SRWeChatReceiver *receiver = [[SRWeChatReceiver alloc] initWithVersion:@"8.0.79" classResolver:^Class(NSString *name) {
        return [name isEqual:@"CMessageMgr"] ? ReceiveManager.class : ([name isEqual:@"CMessageWrap"] ? ReceiveWrap.class : Nil);
    } currentAccount:^NSString *{ return account; } received:^(NSDictionary *message) { [received addObject:message]; }];
    __weak SRWeChatReceiver *weak = receiver;
    receiver.prepareImage = ^NSDictionary *(id value, __unused NSDictionary *source, NSError **error) {
        CHECK(NSThread.isMainThread); reads++;
        if (mode == 1) return nil;
        if (mode == 2) { *error = [NSError errorWithDomain:@"fixture" code:1 userInfo:nil]; return nil; }
        if (mode == 3) account = @"wxid_changed";
        if (mode == 4) ((ReceiveWrap *)value).m_n64MesSvrID++;
        if (mode == 5) [weak stop];
        return imagePayload();
    };
    receiver.discardImage = ^(__unused NSDictionary *payload) { discards++; };
    NSMutableDictionary *configuration = draft(); configuration[@"types"] = @[@"image"];
    ReceiveManager *manager = [[ReceiveManager alloc] init];
    CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
    ReceiveWrap *text = wrap(); [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:text];
    ReceiveWrap *unselected = wrap(); unselected.m_uiMessageType = 3; unselected.m_nsRealChatUsr = @"wxid_other";
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:unselected]; pump();
    CHECK(!reads && !received.count && ![receiver.diagnostics[@"imagePending"] boolValue]);
    // Image capture never reads XML/body as a media path.
    ThrowingReceiveWrap *image = [[ThrowingReceiveWrap alloc] init];
    image.m_nsFromUsr = @"mother@chatroom"; image.m_nsToUsr = account; image.m_nsRealChatUsr = @"wxid_sender";
    image.m_uiMessageType = 3; image.m_n64MesSvrID = 11;
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:image]; pump();
    CHECK(reads == 1 && received.count == 1 && [received[0][@"type"] isEqual:@"image"]);
    CHECK([receiver.diagnostics[@"imageState"] isEqual:@"snapshot_ready"]); [receiver stop];
    // No source is offered until the actual raster becomes ready.
    mode = 1; CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:image]; pump();
    CHECK(reads == 2 && received.count == 1 && [receiver.diagnostics[@"imagePending"] boolValue]);
    mode = 0; CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.15, false);
    CHECK(reads == 3 && received.count == 2); [receiver stop];
    // Exercise the terminal bounded-wait branch without sleeping 30 seconds per suite.
    mode = 1; CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:image]; pump();
    [receiver pollImage:[receiver valueForKey:@"pendingImage"] generation:[[receiver valueForKey:@"generation"] unsignedIntegerValue] remaining:0];
    CHECK([receiver.diagnostics[@"imageState"] isEqual:@"timed_out"] && ![receiver.diagnostics[@"armed"] boolValue]);
    CHECK(received.count == 2);
    for (mode = 2; mode <= 5; mode++) {
        account = @"wxid_account"; image.m_n64MesSvrID = 11;
        CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:image]; pump();
        CHECK(received.count == 2 && ![receiver.diagnostics[@"armed"] boolValue]);
    }
    CHECK(discards == 3);
    account = @"wxid_account"; mode = 0;
    CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:image]; [receiver stop];
    NSUInteger before = reads; CHECK([receiver armForAccount:account configuration:configuration error:NULL]); pump();
    CHECK(reads == before && received.count == 2); [receiver stop];
    // Own images require a server ID; exact local-ID readback can supply the settled wrap.
    configuration[@"senders"] = @[@{@"id": account, @"name": @"Self"}];
    CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
    ReceiveWrap *own = wrap(); own.m_uiMessageType = 3; own.m_nsFromUsr = account; own.m_nsToUsr = @"mother@chatroom";
    own.m_nsRealChatUsr = nil; own.m_n64MesSvrID = 0;
    ReceiveWrap *settled = wrap(); settled.m_uiMessageType = 3; settled.m_nsFromUsr = account; settled.m_nsToUsr = @"mother@chatroom";
    settled.m_nsRealChatUsr = nil; settled.m_n64MesSvrID = 9007199254740995ULL; manager.stored = settled;
    [manager AddMsg:@"mother@chatroom" MsgWrap:own]; pump(); pump();
    CHECK(received.count == 3 && [received.lastObject[@"sender"] isEqual:account]);
    CHECK([received.lastObject[@"messageID"] isEqual:@"svr:9007199254740995"]);
    CHECK(manager.lookupLocalID == own.m_uiMesLocalID); [receiver stop];
    NSString *diagnostics = receiver.diagnostics.description;
    for (NSString *secret in @[@"wxid_account", @"mother@chatroom", @"9007199254740995", @"mediaReference", @"sha256"])
        CHECK(![diagnostics containsString:secret]);
}
static void checkDirectionEvidence(void) {
    __block NSUInteger accepted = 0;
    SRWeChatReceiver *receiver = [[SRWeChatReceiver alloc] initWithVersion:@"8.0.79" classResolver:^Class(NSString *name) {
        return [name isEqual:@"CMessageMgr"] ? DirectionManager.class : ([name isEqual:@"CMessageWrap"] ? ReceiveWrap.class : Nil);
    } currentAccount:^NSString *{ return @"wxid_account"; } received:^(__unused NSDictionary *message) { accepted++; }];
    DirectionManager *manager = [[DirectionManager alloc] init];
    CHECK([receiver armForAccount:@"wxid_account" sourceGroup:@"mother@chatroom" error:NULL]);
    [manager AddMsg:@"other@chatroom" MsgWrap:wrap()];
    CHECK([receiver.diagnostics[@"directionSamples"] count] == 0);
    ReceiveWrap *own = wrap(); own.m_nsFromUsr = @"wxid_account"; own.m_nsToUsr = @"mother@chatroom";
    own.m_nsRealChatUsr = nil; manager.rewriteDirection = YES;
    [manager AddMsg:@"mother@chatroom" MsgWrap:own]; pump();
    NSDictionary *sample = [receiver.diagnostics[@"directionSamples"] lastObject];
    CHECK([sample[@"path"] isEqual:@"outgoing"]);
    CHECK([sample[@"before"][@"fromIsAccount"] boolValue] && [sample[@"before"][@"toIsSource"] boolValue]);
    CHECK([sample[@"after"][@"fromIsSource"] boolValue] && [sample[@"after"][@"fromEqualsTo"] boolValue]);
    CHECK([sample[@"before"][@"senderState"] isEqual:@4]);
    CHECK(!accepted && [receiver.diagnostics[@"counters"][@"outgoing_wrong_direction"] isEqual:@1]);
    manager.rewriteDirection = NO;
    // Rejected directions must not cause diagnostics to read a message body.
    DirectionBodyWrap *private = [[DirectionBodyWrap alloc] init];
    private.m_nsFromUsr = @"other@chatroom"; private.m_nsToUsr = @"unknown_private_account";
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:private]; pump();
    sample = [receiver.diagnostics[@"directionSamples"] lastObject];
    CHECK([sample[@"path"] isEqual:@"receive"] && [sample[@"after"][@"wrapClassCode"] isEqual:@2]);
    CHECK([sample[@"after"][@"fromIsGroup"] boolValue] && ![sample[@"after"][@"fromIsSource"] boolValue]);
    CHECK(!private.bodyReads && !accepted);
    ReceiveWrap *empty = wrap(); empty.m_nsFromUsr = @"";
    NSArray *values = @[[[DirectionThrowWrap alloc] init], [[DirectionNumberWrap alloc] init],
        [[DirectionScalarWrap alloc] init], NSObject.new, empty, NSNull.null];
    NSArray *states = @[@3, @5, @2, @1, @6, @0];
    for (NSUInteger index = 0; index < values.count; index++) {
        id value = values[index] == NSNull.null ? nil : values[index];
        NSUInteger before = manager.calls;
        [manager AddMsg:@"mother@chatroom" MsgWrap:value];
        sample = [receiver.diagnostics[@"directionSamples"] lastObject];
        CHECK(manager.calls == before + 1 && [sample[@"before"][@"fromState"] isEqual:states[index]]);
        CHECK([sample[@"after"][@"fromState"] isEqual:states[index]]);
    }
    // Diagnostics cannot swallow an exception from the original implementation.
    manager.raiseOriginal = YES; BOOL propagated = NO;
    @try { [manager AddMsg:@"mother@chatroom" MsgWrap:own]; }
    @catch (id exception) { propagated = [exception isEqual:@"OriginalOutgoingException"]; }
    CHECK(propagated); manager.raiseOriginal = NO;
    for (NSUInteger index = 0; index < 25; index++) [manager AddMsg:@"mother@chatroom" MsgWrap:empty];
    NSDictionary *diagnostic = receiver.diagnostics;
    CHECK([diagnostic[@"directionSamples"] count] <= 12 && [diagnostic[@"directionSamplesDropped"] unsignedIntegerValue] > 0);
    CHECK([diagnostic[@"directionEvidenceSchema"] isEqual:@2]);
    NSSet *sampleKeys = [NSSet setWithArray:@[@"path", @"time", @"before", @"after"]];
    for (NSDictionary *entry in diagnostic[@"directionSamples"]) {
        CHECK([[NSSet setWithArray:entry.allKeys] isEqual:sampleKeys]);
        for (NSString *phase in @[@"before", @"after"]) for (id fact in [entry[phase] allValues])
            CHECK([fact isKindOfClass:NSNumber.class]);
    }
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:diagnostic options:0 error:NULL] encoding:NSUTF8StringEncoding];
    for (NSString *secret in @[@"wxid_account", @"mother@chatroom", @"other@chatroom", @"unknown_private_account",
        @"private diagnostic body", @"private getter exception", @"9007199254740993"])
        CHECK(![json containsString:secret]);
    [receiver stop];
    CHECK([receiver armForAccount:@"wxid_account" sourceGroup:@"mother@chatroom" error:NULL]);
    CHECK([receiver.diagnostics[@"directionSamples"] count] == 0 && [receiver.diagnostics[@"directionSamplesDropped"] isEqual:@0]);
    CHECK([diagnostic[@"directionSamples"] count] > 0);
    [manager AddMsg:@"mother@chatroom" MsgWrap:empty];
    CHECK([receiver.diagnostics[@"directionSamples"] count] == 1);
    __weak SRWeChatReceiver *weakReceiver = receiver;
    manager.duringOriginal = ^{
        [weakReceiver stop];
        CHECK([weakReceiver armForAccount:@"wxid_account" sourceGroup:@"mother@chatroom" error:NULL]);
    };
    [manager AddMsg:@"mother@chatroom" MsgWrap:empty];
    CHECK([receiver.diagnostics[@"directionSamples"] count] == 0);
    manager.duringOriginal = nil;
    [manager AddMsg:@"mother@chatroom" MsgWrap:empty];
    CHECK([receiver.diagnostics[@"directionSamples"] count] == 1);
    [receiver stop]; pump(); CHECK(!accepted);
}
static void checkReflectedMessage(void) {
    __block NSMutableArray *received = [NSMutableArray array];
    SRWeChatReceiver *receiver = [[SRWeChatReceiver alloc] initWithVersion:@"8.0.79" classResolver:^Class(NSString *name) {
        return [name isEqual:@"CMessageMgr"] ? DirectionManager.class : ([name isEqual:@"CMessageWrap"] ? ReflectedReceiveWrap.class : Nil);
    } currentAccount:^NSString *{ return @"wxid_account"; } received:^(NSDictionary *message) { [received addObject:message]; }];
    DirectionManager *manager = [[DirectionManager alloc] init];
    ReflectedReceiveWrap *own = [[ReflectedReceiveWrap alloc] init];
    own.m_nsFromUsr = @"wxid_account"; own.m_nsToUsr = @"mother@chatroom"; own.m_uiMessageType = 1;
    own.m_nsRealChatUsr = nil; own.m_nsContent = @"reflected private body";
    own.m_n64MesSvrID = 9007199254740993ULL; own.m_uiMesLocalID = 42;
    CHECK(!SRReadString(own, @"m_nsFromUsr") && !SRReadString(own, @"m_nsContent"));
    CHECK([receiver armForAccount:@"wxid_account" sourceGroup:@"mother@chatroom" error:NULL]);
    [manager AddMsg:@"mother@chatroom" MsgWrap:own]; pump(); pump();
    CHECK(received.count == 1 && [received[0][@"sender"] isEqual:@"wxid_account"]);
    CHECK([received[0][@"messageID"] isEqual:@"svr:9007199254740993"]);
    CHECK([received[0][@"payload"][@"text"] isEqual:@"reflected private body"]);
    NSDictionary *facts = [receiver.diagnostics[@"directionSamples"] lastObject][@"after"];
    CHECK([facts[@"fromState"] isEqual:@7] && [facts[@"toState"] isEqual:@7] && [facts[@"senderState"] isEqual:@4]);
    CHECK([facts[@"fromInstanceSignatureState"] isEqual:@2] && [facts[@"toInstanceSignatureState"] isEqual:@2]);
    CHECK([facts[@"fromIsAccount"] boolValue] && [facts[@"toIsSource"] boolValue]);
    CHECK([receiver.diagnostics[@"stringReadStrategy"] isEqual:@"declared_runtime"]);
    [receiver stop];
    CHECK([receiver armForAccount:@"wxid_account" sourceGroup:@"mother@chatroom" error:NULL]);
    own.m_nsFromUsr = @"mother@chatroom"; own.m_nsToUsr = @"wxid_account"; own.m_nsRealChatUsr = @"wxid_sender";
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:own]; pump();
    CHECK(received.count == 2 && [received[1][@"sender"] isEqual:@"wxid_sender"]);
    // Runtime reads cannot turn a wrong account/group into an accepted source.
    own.m_nsToUsr = @"wxid_wrong";
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:own]; pump(); CHECK(received.count == 2);
    own.m_nsFromUsr = @"wxid_wrong"; own.m_nsToUsr = @"mother@chatroom";
    [manager AddMsg:@"mother@chatroom" MsgWrap:own]; pump(); CHECK(received.count == 2);
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:receiver.diagnostics options:0 error:NULL] encoding:NSUTF8StringEncoding];
    for (NSString *secret in @[@"wxid_account", @"mother@chatroom", @"wxid_sender", @"reflected private body", @"9007199254740993"])
        CHECK(![json containsString:secret]);
    [receiver stop]; received = nil;
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
        NSMutableArray *trace = [NSMutableArray array];
        receiver.trace = ^(NSString *event, __unused NSDictionary *facts) { [trace addObject:event]; };
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
        // Own messages use the same selected-wxid filter and freeze only with a server ID.
        NSMutableDictionary *ownDraft = draft();
        ownDraft[@"senders"] = @[@{@"id": current, @"name": @"Me"}];
        weakReceiver = receiver;
        CHECK([capture armForAccount:current configuration:ownDraft error:NULL]);
        CHECK([receiver armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        ReceiveWrap *own = wrap(); own.m_nsFromUsr = current; own.m_nsToUsr = @"mother@chatroom";
        own.m_nsRealChatUsr = nil; own.m_n64MesSvrID = 0;
        before = manager.calls;
        [manager AddMsg:@"wrong@chatroom" MsgWrap:own]; pump(); CHECK(!capture.preview);
        [manager AddMsg:@"mother@chatroom" MsgWrap:own]; pump(); CHECK(!capture.preview);
        CHECK(manager.calls == before + 2);
        own.m_n64MesSvrID = 123456789;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.2, false);
        CHECK([capture.preview[@"sender"] isEqual:current]);
        CHECK([capture.preview[@"messageID"] isEqual:@"svr:123456789"]);
        [capture cancel];
        CHECK([capture armForAccount:current configuration:ownDraft error:NULL]);
        CHECK([receiver armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        ReceiveWrap *synced = wrap(); synced.m_nsRealChatUsr = current;
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:synced]; pump();
        CHECK([capture.preview[@"sender"] isEqual:current]);
        NSDictionary *firstOwn = capture.preview;
        [manager AddMsg:@"mother@chatroom" MsgWrap:own]; pump(); CHECK([capture.preview isEqual:firstOwn]);
        [capture cancel];
        CHECK([capture armForAccount:current configuration:ownDraft error:NULL]);
        CHECK([receiver armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        own.m_n64MesSvrID = 0;
        [manager AddMsg:@"mother@chatroom" MsgWrap:own]; pump();
        [receiver stop]; [capture cancel];
        CHECK([capture armForAccount:current configuration:ownDraft error:NULL]);
        CHECK([receiver armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        own.m_n64MesSvrID = 777;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.2, false); CHECK(!capture.preview);
        own.m_n64MesSvrID = 0;
        [manager AddMsg:@"mother@chatroom" MsgWrap:own]; pump();
        current = @"wxid_switched"; own.m_n64MesSvrID = 888;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.2, false);
        CHECK(!capture.preview && ![receiver.diagnostics[@"armed"] boolValue]);
        [capture cancel]; current = @"wxid_account";
        CHECK([capture armForAccount:current configuration:ownDraft error:NULL]);
        CHECK([receiver armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        own.m_n64MesSvrID = 0;
        ReceiveWrap *stored = wrap(); stored.m_nsFromUsr = current; stored.m_nsToUsr = @"mother@chatroom";
        stored.m_nsRealChatUsr = nil; stored.m_n64MesSvrID = 9007199254740995ULL;
        manager.stored = stored;
        [manager AddMsg:@"mother@chatroom" MsgWrap:own]; pump(); pump();
        CHECK([capture.preview[@"messageID"] isEqual:@"svr:9007199254740995"]);
        CHECK([manager.lookupGroup isEqual:@"mother@chatroom"] && manager.lookupLocalID == 42);

        // Wrong local ID or changed body cannot be accepted via exact-ID readback.
        [capture cancel];
        CHECK([capture armForAccount:current configuration:ownDraft error:NULL]);
        CHECK([receiver armForAccount:current sourceGroup:@"mother@chatroom" error:NULL]);
        stored.m_uiMesLocalID = 99;
        [manager AddMsg:@"mother@chatroom" MsgWrap:own]; pump(); CHECK(!capture.preview);
        stored.m_uiMesLocalID = 42; stored.m_nsContent = @"different text";
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.2, false); CHECK(!capture.preview);
        own.m_nsContent = @"mutated before confirmation";
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.2, false);
        CHECK(!capture.preview && ![receiver.diagnostics[@"ownTextPending"] boolValue]);
        CHECK([receiver.diagnostics[@"ownTextState"] isEqual:@"conflict"]);
        CHECK([receiver.diagnostics[@"counters"][@"own_conflict"] isEqual:@1]);
        CHECK([trace containsObject:@"own_readback"] && [trace containsObject:@"own_conflict"]);
        own.m_nsContent = @"original message"; manager.stored = nil;
        // Optional observation catches arbitrary Objective-C objects, but never host exceptions.
        ThrowingReceiveWrap *throwing = [[ThrowingReceiveWrap alloc] init];
        throwing.m_nsFromUsr = current; throwing.m_nsToUsr = @"mother@chatroom"; throwing.m_uiMessageType = 1;
        [manager AddMsg:@"mother@chatroom" MsgWrap:throwing]; pump(); CHECK(!capture.preview);
        manager.raiseOriginal = YES; BOOL propagated = NO;
        @try { [manager AddMsg:@"mother@chatroom" MsgWrap:own]; }
        @catch (id exception) { propagated = [exception isEqual:@"OriginalOutgoingException"]; }
        CHECK(propagated); manager.raiseOriginal = NO; pump(); CHECK(!capture.preview);
        NSString *ownDiagnostics = receiver.diagnostics.description;
        for (NSString *secret in @[@"wxid_account", @"mother@chatroom", @"original message", @"9007199254740995"])
            CHECK(![ownDiagnostics containsString:secret]);
        [receiver stop]; [capture cancel]; receiver = nil; replacement = nil; inherited = nil; makeReceiver = nil; capture = nil; store = nil;
        checkDirectionEvidence();
        checkReflectedMessage();
        checkImageCapture();
        CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: guarded receive, original hook chain, exact IDs, wxid filters, frozen preview, bounded redacted pre/post directions and cancellation");
    }
    return 0;
}
