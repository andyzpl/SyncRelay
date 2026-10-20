#import <Foundation/Foundation.h>
#import "Adapter/SRRuntime.h"
#import "Adapter/SRWeChatSendProbe.h"
#include <assert.h>
#include <limits.h>
#include <math.h>
#define CHECK(...) assert((__VA_ARGS__))

@interface ProbeWrap : NSObject
@property(nonatomic, copy) NSString *m_nsFromUsr;
@property(nonatomic, copy) NSString *m_nsToUsr;
@property(nonatomic) unsigned int m_uiMessageType;
@property(nonatomic) unsigned long long m_uiMesLocalID;
@property(nonatomic) unsigned long long m_n64MesSvrID;
@property(nonatomic) unsigned int m_uiStatus;
- (NSString *)m_nsContent;
@end
@implementation ProbeWrap
- (NSString *)m_nsContent { abort(); } // No diagnostic path may read the source body.
@end
@interface ProbeManager : NSObject
@property(nonatomic) NSUInteger calls;
@property(nonatomic) NSUInteger lookups;
@property(nonatomic) BOOL raises;
@property(nonatomic, strong) id readback;
- (void)AddMsg:(id)session MsgWrap:(id)wrap;
- (id)GetMsg:(id)session LocalID:(unsigned long long)localID;
@end
@implementation ProbeManager
- (void)AddMsg:(__unused id)session MsgWrap:(__unused id)wrap {
    self.calls++;
    if (self.raises) @throw [NSException exceptionWithName:@"OriginalSend" reason:@"private original exception" userInfo:nil];
}
- (id)GetMsg:(id)session LocalID:(unsigned long long)localID {
    CHECK(NSThread.isMainThread); CHECK([session isEqual:@"target@chatroom"]); CHECK(localID > 0);
    self.lookups++; return self.readback;
}
@end
@interface ProbeInheritedManager : ProbeManager
@end
@implementation ProbeInheritedManager
@end
@interface ProbeWrongManager : NSObject
- (id)AddMsg:(id)session MsgWrap:(id)wrap;
@end
@implementation ProbeWrongManager
- (id)AddMsg:(__unused id)session MsgWrap:(__unused id)wrap { abort(); }
@end
@interface ProbeWrongWrap : NSObject
- (double)m_uiMessageType;
@end
@implementation ProbeWrongWrap
- (double)m_uiMessageType { abort(); }
@end
@interface LookupTraps : NSObject
@property(nonatomic) NSUInteger calls;
- (id)lookup:(id)object ID32:(unsigned int)value;
- (id)lookup:(id)object ID64:(unsigned long long)value;
- (id)lookup:(id)object signed32:(int)value;
- (id)badFloat:(id)object value:(double)value;
- (id)badObject:(id)object value:(id)value;
- (unsigned int)badResult:(id)object value:(unsigned int)value;
@end
@implementation LookupTraps
- (id)lookup:(id)object ID32:(unsigned int)value { self.calls++; return @[object, @(value)]; }
- (id)lookup:(id)object ID64:(unsigned long long)value { self.calls++; return @[object, @(value)]; }
- (id)lookup:(id)object signed32:(int)value { self.calls++; return @[object, @(value)]; }
- (id)badFloat:(__unused id)object value:(__unused double)value { abort(); }
- (id)badObject:(__unused id)object value:(__unused id)value { abort(); }
- (unsigned int)badResult:(__unused id)object value:(__unused unsigned int)value { abort(); }
@end
static ProbeWrap *wrap(void) {
    ProbeWrap *value = [[ProbeWrap alloc] init]; value.m_nsFromUsr = @"wxid_probe_account";
    value.m_nsToUsr = @"target@chatroom"; value.m_uiMessageType = 1;
    value.m_uiMesLocalID = 9007199254740993ULL; value.m_n64MesSvrID = 0; value.m_uiStatus = 1;
    return value;
}
static void pump(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false); }
static void onBackground(void (^block)(void)) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    // dispatch_sync may run a global-queue block inline on the calling main thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        CHECK(!NSThread.isMainThread); block(); dispatch_semaphore_signal(done);
    });
    CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
}
static NSDictionary *last(SRWeChatSendProbe *probe) { return [probe.diagnostics[@"samples"] lastObject]; }

int main(void) {
    @autoreleasepool {
        LookupTraps *traps = [[LookupTraps alloc] init];
        CHECK([SRReadObjectWithObjectAndUnsignedInteger(traps, @"lookup:ID32:", @"group", @(UINT_MAX), NULL)[1] isEqual:@(UINT_MAX)]);
        CHECK([SRReadObjectWithObjectAndUnsignedInteger(traps, @"lookup:ID64:", @"group", @(ULLONG_MAX), NULL)[1] isEqual:@(ULLONG_MAX)]);
        CHECK([SRReadObjectWithObjectAndUnsignedInteger(traps, @"lookup:signed32:", @"group", @(INT_MAX), NULL)[1] isEqual:@(INT_MAX)]);
        NSUInteger calls = traps.calls;
        CHECK(!SRReadObjectWithObjectAndUnsignedInteger(traps, @"lookup:ID32:", @"group", @(1ULL + UINT_MAX), NULL));
        CHECK(!SRReadObjectWithObjectAndUnsignedInteger(traps, @"lookup:signed32:", @"group", @(1ULL + INT_MAX), NULL));
        for (NSNumber *number in @[@(-1), @1.5, @(NAN)]) CHECK(!SRReadObjectWithObjectAndUnsignedInteger(traps, @"lookup:ID64:", @"group", number, NULL));
        for (NSString *selector in @[@"badFloat:value:", @"badObject:value:", @"badResult:value:", @"absent:ID:"])
            CHECK(!SRReadObjectWithObjectAndUnsignedInteger(traps, selector, @"group", @1, NULL));
        CHECK(traps.calls == calls);

        __block NSString *current = @"wxid_probe_account"; __block double now = 0; __block NSUInteger changes = 0;
        SRWeChatSendProbe *(^make)(NSString *, Class, Class) = ^(NSString *version, Class manager, Class message) {
            return [[SRWeChatSendProbe alloc] initWithVersion:version classResolver:^Class(NSString *name) {
                return [name isEqual:@"CMessageMgr"] ? manager : ([name isEqual:@"CMessageWrap"] ? message : Nil);
            } currentAccount:^NSString * { CHECK(NSThread.isMainThread); return current; }
                clock:^double { CHECK(NSThread.isMainThread); return now; } changed:^{ CHECK(NSThread.isMainThread); changes++; }];
        };
        SRWeChatSendProbe *probe = make(@"8.0.79", ProbeManager.class, ProbeWrap.class);
        ProbeManager *manager = [[ProbeManager alloc] init];
        [manager AddMsg:@"target@chatroom" MsgWrap:wrap()]; pump();
        CHECK(manager.calls == 1 && ![probe.diagnostics[@"installed"] boolValue]);
        CHECK(![make(@"8.0.80", ProbeManager.class, ProbeWrap.class) armForAccount:current targetGroup:@"target@chatroom" error:NULL]);
        CHECK(![make(@"8.0.79", ProbeWrongManager.class, ProbeWrap.class) armForAccount:current targetGroup:@"target@chatroom" error:NULL]);
        CHECK(![make(@"8.0.79", ProbeManager.class, ProbeWrongWrap.class) armForAccount:current targetGroup:@"target@chatroom" error:NULL]);
        CHECK(![make(@"8.0.79", ProbeManager.class, Nil) armForAccount:current targetGroup:@"target@chatroom" error:NULL]);
        CHECK(![probe armForAccount:current targetGroup:@"not-a-group" error:NULL]);
        CHECK(![probe armForAccount:@"another-account" targetGroup:@"target@chatroom" error:NULL]);
        __block BOOL backgroundArm = YES;
        onBackground(^{ backgroundArm = [probe armForAccount:current targetGroup:@"target@chatroom" error:NULL]; });
        CHECK(!backgroundArm);
        CHECK([probe armForAccount:current targetGroup:@"target@chatroom" error:NULL]);
        CHECK(![probe armForAccount:current targetGroup:@"target@chatroom" error:NULL]);
        CHECK(![make(@"8.0.76", ProbeManager.class, ProbeWrap.class) armForAccount:current targetGroup:@"target@chatroom" error:NULL]);
        ProbeWrap *wrongFrom = wrap(); wrongFrom.m_nsFromUsr = @"other-account";
        ProbeWrap *wrongTo = wrap(); wrongTo.m_nsToUsr = @"other@chatroom";
        ProbeWrap *image = wrap(); image.m_uiMessageType = 3;
        for (ProbeWrap *bad in @[wrongFrom, wrongTo, image]) [manager AddMsg:@"target@chatroom" MsgWrap:bad];
        [manager AddMsg:@"other@chatroom" MsgWrap:wrap()]; pump(); CHECK([probe.diagnostics[@"observedOutgoing"] isEqual:@0]);
        manager.raises = YES; BOOL threw = NO;
        @try { [manager AddMsg:@"target@chatroom" MsgWrap:wrap()]; } @catch (NSException *exception) { threw = [exception.name isEqual:@"OriginalSend"]; }
        CHECK(threw); manager.raises = NO; pump(); CHECK([probe.diagnostics[@"observedOutgoing"] isEqual:@0]);

        ProbeWrap *original = wrap(); manager.readback = original; calls = manager.calls;
        onBackground(^{ [manager AddMsg:@"target@chatroom" MsgWrap:original]; });
        pump(); CHECK(manager.calls == calls + 1 && [probe.diagnostics[@"observedOutgoing"] isEqual:@1]);
        CHECK([probe.diagnostics[@"samples"][0][@"source"] isEqual:@"after_add"] && [last(probe)[@"localIDPresent"] boolValue]);
        original.m_n64MesSvrID = 9007199254740999ULL; original.m_uiStatus = 2;
        calls = manager.lookups; [probe poll]; CHECK(manager.lookups == calls + 1 && [last(probe)[@"serverIDPresent"] boolValue]);
        CHECK([last(probe)[@"source"] isEqual:@"local_readback"] && [last(probe)[@"statusCode"] isEqual:@2]);
        CHECK([probe.diagnostics[@"deliveryOutcome"] isEqual:@"not_determined"]);
        ProbeWrap *wrongID = wrap(); wrongID.m_uiMesLocalID = 9007199254740992ULL; manager.readback = wrongID;
        NSUInteger samples = [probe.diagnostics[@"samples"] count]; [probe poll];
        CHECK([probe.diagnostics[@"samples"] count] == samples && [probe.diagnostics[@"lookupMisses"] isEqual:@1]);
        manager.readback = original; original.m_n64MesSvrID++; [probe poll]; CHECK([last(probe)[@"serverIDConflict"] boolValue]);
        original.m_n64MesSvrID--; original.m_nsToUsr = @"other@chatroom"; [probe poll]; CHECK([probe.diagnostics[@"lookupMisses"] isEqual:@2]);
        original.m_nsToUsr = @"target@chatroom";
        for (NSUInteger i = 3; i < 65; i++) { original.m_uiStatus = (unsigned int)i; [probe poll]; }
        CHECK([probe.diagnostics[@"samples"] count] == 32 && [probe.diagnostics[@"droppedSamplesOrCallbacks"] unsignedIntegerValue] > 0);
        NSString *report = probe.diagnostics.description;
        for (NSString *secret in @[@"wxid_probe_account", @"target@chatroom", @"9007199254740993", @"9007199254740999", @"private original exception", @"m_nsContent"])
            CHECK(![report containsString:secret]);
        calls = manager.calls; [probe poll]; CHECK(manager.calls == calls); // Polling never initiates a send.
        [probe stop]; CHECK(![probe.diagnostics[@"armed"] boolValue] && [probe.diagnostics[@"samples"] count] == 32);
        calls = manager.lookups; [probe poll]; CHECK(manager.lookups == calls);

        CHECK([probe armForAccount:current targetGroup:@"target@chatroom" error:NULL]);
        ProbeWrap *unassigned = wrap(); unassigned.m_uiMesLocalID = 0; manager.readback = unassigned;
        [manager AddMsg:@"target@chatroom" MsgWrap:unassigned]; pump();
        calls = manager.lookups; [probe poll]; CHECK(manager.lookups == calls && ![last(probe)[@"localIDPresent"] boolValue]);
        unassigned.m_uiMesLocalID = ULLONG_MAX; [probe poll];
        CHECK(manager.lookups == calls && [last(probe)[@"localIDPresent"] boolValue]);
        [probe poll]; CHECK(manager.lookups == calls + 1 && [last(probe)[@"source"] isEqual:@"local_readback"]);
        ProbeWrap *another = wrap(); [manager AddMsg:@"target@chatroom" MsgWrap:another]; pump();
        CHECK([probe.diagnostics[@"observedOutgoing"] isEqual:@2]);
        // A second outgoing message cannot replace the first message's frozen local lookup key.
        manager.readback = another; samples = [probe.diagnostics[@"samples"] count]; [probe poll];
        CHECK([probe.diagnostics[@"samples"] count] == samples); [probe stop];

        // A queued snapshot from a previous generation cannot become the new observation.
        CHECK([probe armForAccount:current targetGroup:@"target@chatroom" error:NULL]);
        [manager AddMsg:@"target@chatroom" MsgWrap:wrap()]; [probe stop];
        CHECK([probe armForAccount:current targetGroup:@"target@chatroom" error:NULL]); pump();
        CHECK([probe.diagnostics[@"observedOutgoing"] isEqual:@0]);
        [manager AddMsg:@"target@chatroom" MsgWrap:wrap()]; current = @"switched-account"; pump();
        CHECK([probe.diagnostics[@"state"] isEqual:@"account_changed"] && ![probe.diagnostics[@"samples"] count]);
        current = @"wxid_probe_account"; CHECK([probe armForAccount:current targetGroup:@"target@chatroom" error:NULL]);
        [probe cancelForInactivity]; CHECK([probe.diagnostics[@"state"] isEqual:@"inactive"]); [probe poll]; CHECK(![probe.diagnostics[@"armed"] boolValue]);
        CHECK([probe armForAccount:current targetGroup:@"target@chatroom" error:NULL]); now = 120; [probe poll];
        CHECK([probe.diagnostics[@"state"] isEqual:@"expired"]);
        CHECK([probe armForAccount:current targetGroup:@"target@chatroom" error:NULL]); now = NAN; [probe poll];
        CHECK([probe.diagnostics[@"state"] isEqual:@"invalid_clock"]); now = 0;
        CHECK([probe armForAccount:current targetGroup:@"target@chatroom" error:NULL]);
        for (NSUInteger i = 0; i < 100; i++) [manager AddMsg:@"target@chatroom" MsgWrap:wrap()];
        pump(); CHECK([probe.diagnostics[@"observedOutgoing"] unsignedIntegerValue] <= 16);
        CHECK([probe.diagnostics[@"droppedSamplesOrCallbacks"] unsignedIntegerValue] >= 84); [probe stop];

        SRWeChatSendProbe *replacement = make(@"8.0.76", ProbeManager.class, ProbeWrap.class);
        CHECK([replacement armForAccount:current targetGroup:@"target@chatroom" error:NULL]);
        calls = manager.calls; [manager AddMsg:@"target@chatroom" MsgWrap:wrap()]; pump();
        CHECK(manager.calls == calls + 1 && [replacement.diagnostics[@"observedOutgoing"] isEqual:@1]); [replacement stop];
        SRWeChatSendProbe *inherited = make(@"8.0.79", ProbeInheritedManager.class, ProbeWrap.class);
        CHECK([inherited armForAccount:current targetGroup:@"target@chatroom" error:NULL]);
        ProbeInheritedManager *sub = [[ProbeInheritedManager alloc] init]; [sub AddMsg:@"target@chatroom" MsgWrap:wrap()]; pump();
        CHECK(sub.calls == 1 && [inherited.diagnostics[@"observedOutgoing"] isEqual:@1]); [inherited stop];
        CHECK(changes > 0);
        puts("PASS: read-only manual-send probe, preserved original chain, exact lookup IDs, no body/sending/success inference, bounded samples and cancellation");
    }
    return 0;
}
