#import <Foundation/Foundation.h>
#import "Adapter/SRRuntime.h"
#import "Adapter/SRWeChatReader.h"
#import "Core/SRSelection.h"
#import "Core/SRConfiguration.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

@interface FakeContact : NSObject
@property(nonatomic, copy) NSString *m_nsUsrName;
@property(nonatomic, copy) NSString *m_nsNickName;
@property(nonatomic, copy) NSString *m_nsChatRoomMemList;
@end
@implementation FakeContact
@end

@interface FakeManager : NSObject
@property(nonatomic, strong) FakeContact *myself;
@property(nonatomic, strong) NSArray *contacts;
@property(nonatomic, strong) NSDictionary *byName;
@property(nonatomic) BOOL invalidResult;
- (id)getSelfContact;
- (id)getContactList:(unsigned int)scene contactType:(unsigned int)type;
- (id)getContactByName:(NSString *)name;
@end
@implementation FakeManager
- (id)getSelfContact { return self.myself; }
- (id)getContactList:(unsigned int)scene contactType:(unsigned int)type {
    CHECK(scene == 1 && type == 0);
    return self.invalidResult ? (id)@{@"unexpected": @1} : self.contacts;
}
- (id)getContactByName:(NSString *)name { return self.byName[name]; }
@end

static FakeManager *fixture;
static Class sessionType;
static id sessionFixture;
@interface FakeSessions : NSObject
@property(nonatomic, strong) id usernames;
@property(nonatomic, copy) void (^onRead)(void);
- (id)GetUserNamesOnSessionList;
@end
@implementation FakeSessions
- (id)GetUserNamesOnSessionList { if (self.onRead) self.onRead(); return self.usernames; }
@end
@interface WrongSessions : NSObject
- (double)GetUserNamesOnSessionList;
@end
@implementation WrongSessions
- (double)GetUserNamesOnSessionList { abort(); }
@end
@interface FakeCenter : NSObject
+ (id)defaultCenter;
- (id)getService:(Class)type;
@end
@implementation FakeCenter
+ (id)defaultCenter { return [[self alloc] init]; }
- (id)getService:(Class)type {
    if (type == FakeManager.class) return fixture;
    CHECK(type == sessionType); return sessionFixture;
}
@end

@interface WrongABI : NSObject
- (int)scalarReturn;
- (id)pointer:(void *)value;
- (id)floating:(double)value;
- (id)throwsException;
- (id)objectArgument:(id)value;
@end
@implementation WrongABI
- (int)scalarReturn { abort(); }
- (id)pointer:(__unused void *)value { abort(); }
- (id)floating:(__unused double)value { abort(); }
- (id)throwsException { @throw [NSException exceptionWithName:@"Fixture" reason:@"private member content" userInfo:nil]; }
- (id)objectArgument:(id)value { return value; }
@end

@interface ReflectedStrings : NSObject
@property(nonatomic) NSUInteger mode;
@property(nonatomic, strong) NSMutableString *value;
- (NSString *)text;
- (NSString *)empty;
- (NSString *)absentValue;
- (id)number;
- (id (^)(void))blockResult;
- (void *)rawPointer;
- (NSString *)throwString;
@end
@implementation ReflectedStrings
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (selector == NSSelectorFromString(@"forwardOnly")) return [NSMethodSignature signatureWithObjCTypes:"@@:"];
    if (selector == @selector(text)) {
        if (self.mode == 1) return nil;
        if (self.mode == 2) return [NSMethodSignature signatureWithObjCTypes:"v@:"];
        if (self.mode == 3) return [NSMethodSignature signatureWithObjCTypes:"@@:@"];
        if (self.mode == 4) @throw @"private reflection exception";
    }
    return [super methodSignatureForSelector:selector];
}
- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == NSSelectorFromString(@"forwardOnly")) return YES;
    return [super respondsToSelector:selector];
}
- (void)forwardInvocation:(__unused NSInvocation *)invocation { abort(); }
- (NSString *)text { return self.value; }
- (NSString *)empty { return @""; }
- (NSString *)absentValue { return nil; }
- (id)number { return @1; }
- (id (^)(void))blockResult { abort(); }
- (void *)rawPointer { abort(); }
- (NSString *)throwString { @throw @"private getter exception"; }
@end

static void testDeclaredStrings(void) {
    ReflectedStrings *value = [[ReflectedStrings alloc] init];
    value.value = [@"stable string" mutableCopy];
    SRStringReadState state = SRStringReadNoObject;
    for (NSUInteger mode = 0; mode <= 4; mode++) {
        value.mode = mode;
        CHECK([SRReadDeclaredString(value, @"text", &state) isEqual:@"stable string"] && state == SRStringReadValue);
        if (mode == 1 || mode == 2 || mode == 3) CHECK(!SRReadString(value, @"text"));
    }
    NSString *frozen = SRReadDeclaredString(value, @"text", NULL);
    [value.value appendString:@" changed"]; CHECK([frozen isEqual:@"stable string"]);
    CHECK(!SRReadDeclaredString(nil, @"text", &state) && state == SRStringReadNoObject);
    CHECK(!SRReadDeclaredString(value, @"missing", &state) && state == SRStringReadMissing);
    CHECK(!SRReadDeclaredString(value, @"number", &state) && state == SRStringReadNotString);
    CHECK(!SRReadDeclaredString(value, @"absentValue", &state) && state == SRStringReadNil);
    CHECK([SRReadDeclaredString(value, @"empty", &state) isEqual:@""] && state == SRStringReadEmpty);
    CHECK(!SRReadDeclaredString(value, @"throwString", &state) && state == SRStringReadFailed);
    CHECK(!SRReadDeclaredString(value, @"blockResult", &state) && state == SRStringReadIncompatible);
    CHECK(!SRReadDeclaredString(value, @"rawPointer", &state) && state == SRStringReadIncompatible);
    CHECK(!SRReadDeclaredString(value, @"forwardOnly", &state) && state == SRStringReadMissing);
    WrongABI *wrong = [[WrongABI alloc] init];
    for (NSString *name in @[@"scalarReturn", @"pointer:", @"floating:", @"objectArgument:"])
        CHECK(!SRReadDeclaredString(wrong, name, &state) && state == SRStringReadIncompatible);
    CHECK(!SRReadDeclaredString(wrong, @"throwsException", &state) && state == SRStringReadFailed);
}

static FakeContact *contact(NSString *identifier, NSString *name) {
    FakeContact *value = [[FakeContact alloc] init]; value.m_nsUsrName = identifier; value.m_nsNickName = name; return value;
}
static SRWeChatReader *reader(NSString *version) {
    return [[SRWeChatReader alloc] initWithVersion:version classResolver:^Class(NSString *name) {
        if ([name isEqual:@"MMServiceCenter"]) return FakeCenter.class;
        if ([name isEqual:@"CContactMgr"]) return FakeManager.class;
        if ([name isEqual:@"CContact"]) return FakeContact.class;
        if ([name isEqual:@"MMNewSessionMgr"]) return sessionType;
        return Nil;
    }];
}

static void testPartialGroupLists(void) {
    FakeManager *original = fixture;
    fixture = [[FakeManager alloc] init]; fixture.myself = contact(@"wxid_me", @"Me");
    NSMutableArray *contacts = [NSMutableArray array], *identifiers = [NSMutableArray array];
    NSMutableDictionary *byName = [NSMutableDictionary dictionary];
    for (int i = 0; i < 4; i++) {
        NSString *identifier = [NSString stringWithFormat:@"saved-%d@chatroom", i];
        FakeContact *value = contact(identifier, @"Saved"); [contacts addObject:value]; byName[identifier] = value;
    }
    [identifiers addObject:@"saved-0@chatroom"];
    for (int i = 0; i < 240; i++) {
        NSString *identifier = [NSString stringWithFormat:@"session-%d@chatroom", i];
        [identifiers addObject:identifier]; byName[identifier] = contact(identifier, @"Session");
    }
    [identifiers addObjectsFromArray:@[@"session-1@chatroom", @"wxid_person", @4, @" bad@chatroom", @"@chatroom", @"unresolved@chatroom", @"unresolved@chatroom", @"mismatch@chatroom"]];
    byName[@"mismatch@chatroom"] = contact(@"other@chatroom", @"Wrong");
    fixture.contacts = contacts; fixture.byName = byName;
    FakeSessions *sessions = [[FakeSessions alloc] init]; sessions.usernames = identifiers;
    sessionType = FakeSessions.class; sessionFixture = sessions;
    for (NSString *version in @[@"8.0.76", @"8.0.79"]) {
        SRWeChatReader *r = reader(version); CHECK([r connect:NULL]);
        NSArray *rows = [r groups:NULL]; CHECK(rows.count == 244);
        NSSet *ids = [NSSet setWithArray:[rows valueForKey:@"id"]]; CHECK(ids.count == rows.count);
        CHECK([ids containsObject:@"session-239@chatroom"] && ![ids containsObject:@"unresolved@chatroom"] && ![ids containsObject:@"other@chatroom"]);
        NSDictionary *report = r.diagnostics[@"groupRead"];
        CHECK([report[@"contacts"][@"ordinaryGroupCount"] isEqual:@4]);
        CHECK([report[@"sessions"][@"ordinaryGroupCount"] isEqual:@243]);
        CHECK([report[@"sessions"][@"unresolvedGroupCount"] isEqual:@2]);
        CHECK([report[@"sessions"][@"invalidItemCount"] isEqual:@1]);
        CHECK([report[@"mergedGroupCount"] isEqual:@244] && ![report[@"completeJoinedGroupListConfirmed"] boolValue]);
        NSString *diagnostics = r.diagnostics.description;
        for (NSString *secret in @[@"wxid_me", @"saved-0", @"session-239", @"unresolved@", @"Wrong"])
            CHECK(![diagnostics containsString:secret]);
        sessions.usernames = [NSSet setWithArray:identifiers]; CHECK([r groups:NULL].count == 244);
        fixture.invalidResult = YES; CHECK([r groups:NULL].count == 241);
        sessions.usernames = @{}; CHECK(![r groups:NULL]); fixture.invalidResult = NO;
        CHECK([r groups:NULL].count == 4);
        sessions.usernames = identifiers;
        sessions.onRead = ^{ fixture.myself = contact(@"wxid_new", @"Changed"); };
        CHECK(![r groups:NULL]); CHECK([r.diagnostics[@"groupRead"][@"state"] isEqual:@"not_read"]);
        sessions.onRead = nil; fixture.myself = contact(@"wxid_me", @"Me");
    }
    sessionType = WrongSessions.class; sessionFixture = [[WrongSessions alloc] init];
    SRWeChatReader *r = reader(@"8.0.79"); CHECK([r connect:NULL]); CHECK([r groups:NULL].count == 4);
    sessionType = FakeSessions.class; sessionFixture = nil;
    CHECK([r groups:NULL].count == 4 && [r.diagnostics[@"groupRead"][@"sessions"][@"state"] isEqual:@"service_unavailable"]);
    sessionType = Nil; sessionFixture = nil; fixture = original;
}

int main(void) {
    @autoreleasepool {
        testDeclaredStrings();
        WrongABI *wrong = [[WrongABI alloc] init];
        CHECK(!SRReadObject(wrong, @"scalarReturn", @[], NULL));
        CHECK(!SRReadObject(wrong, @"pointer:", @[@1], NULL));
        CHECK(!SRReadObjectWithIntegers(wrong, @"floating:", @[@1], NULL));
        CHECK(!SRReadObject(wrong, @"objectArgument:", @[], NULL));
        NSError *error = nil;
        CHECK(!SRReadObject(wrong, @"throwsException", @[], &error));
        CHECK(![error.localizedDescription containsString:@"private member content"]);
        CHECK([SRReadObject(wrong, @"objectArgument:", @[@"valid"], NULL) isEqual:@"valid"]);

        fixture = [[FakeManager alloc] init]; fixture.myself = contact(@"wxid_me", @"Me");
        FakeContact *group = contact(@"source@chatroom", @"Source");
        group.m_nsChatRoomMemList = @"wxid_a;wxid_b;wxid_a;";
        fixture.byName = @{@"source@chatroom": group, @"wxid_a": contact(@"wxid_a", @"Same nickname"),
                           @"wxid_b": contact(@"wxid_b", @"Same nickname")};
        NSMutableArray *contacts = [NSMutableArray arrayWithObject:fixture.myself];
        [contacts addObject:group]; [contacts addObject:group];
        for (int i = 0; i < 12345; i++) [contacts addObject:contact([NSString stringWithFormat:@"group-%d@chatroom", i], @"Group")];
        fixture.contacts = contacts;
        for (NSString *version in @[@"8.0.76", @"8.0.79"]) {
            SRWeChatReader *r = reader(version);
            CHECK([r connect:NULL]); CHECK([r.accountID isEqual:@"wxid_me"]);
            CHECK([r groups:NULL].count == 12346);
            NSArray *members = [r membersOfGroup:@"source@chatroom" error:NULL];
            CHECK(members.count == 2);
            CHECK([members[0][@"id"] isEqual:@"wxid_a"] && [members[1][@"id"] isEqual:@"wxid_b"]);
            NSString *diagnostics = [r.diagnostics description];
            CHECK(![diagnostics containsString:@"wxid_me"] && ![diagnostics containsString:@"wxid_a"]);
            fixture.invalidResult = YES; CHECK(![r groups:NULL]); fixture.invalidResult = NO;
            group.m_nsChatRoomMemList = @"wxid_a,wxid_b"; CHECK(![r membersOfGroup:@"source@chatroom" error:NULL]);
            group.m_nsChatRoomMemList = @"wxid_a;wxid_b;";
            fixture.myself = contact(@"wxid_other", @"Other");
            CHECK(![r verifyAccount:@"wxid_me" error:NULL]);
            fixture.myself = contact(@"wxid_me", @"Me");
        }
        CHECK(![reader(@"8.0.80") connect:NULL]);
        SRWeChatReader *missing = [[SRWeChatReader alloc] initWithVersion:@"8.0.79" classResolver:^Class(__unused NSString *name) { return Nil; }];
        CHECK(![missing connect:NULL]);
        testPartialGroupLists();

        NSArray *rows = [reader(@"8.0.79") groups:NULL];
        CHECK(!rows); // Explicit connect is required before reading.
        SRWeChatReader *r = reader(@"8.0.79"); CHECK([r connect:NULL]); rows = [r groups:NULL];
        SRSelection *selection = [[SRSelection alloc] initWithRows:rows excludedIDs:[NSSet setWithObject:@"source@chatroom"] selectedIDs:NSSet.set];
        CHECK(selection.rows.count == 12345);
        [selection selectFirst:200]; CHECK(selection.selectedRows.count == 200);
        CHECK([selection rowsMatching:@"group-12344"].count == 1);
        CHECK(selection.selectedRows.count == 200);
        [selection selectFirst:NSUIntegerMax]; CHECK(selection.selectedRows.count == 12345);
        [selection toggle:@"source@chatroom"]; CHECK(selection.selectedRows.count == 12345);
        [selection selectFirst:100]; CHECK(selection.selectedRows.count == 100);

        NSMutableDictionary *draft = [SRConfiguration emptyDraft]; CHECK([SRConfiguration validateDraft:draft error:NULL]);
        draft[@"sourceGroup"] = @{@"id": @"source@chatroom", @"name": @"Source"};
        draft[@"senders"] = @[@{@"id": @"wxid_a", @"name": @"Name"}];
        NSDictionary *rule = @{@"id": @"rule1", @"name": @"Rule 1", @"targets": selection.selectedRows};
        draft[@"rules"] = @[rule]; CHECK([SRConfiguration validateDraft:draft error:NULL]);
        draft[@"rules"] = @[rule, rule]; CHECK(![SRConfiguration validateDraft:draft error:NULL]);
        draft[@"rules"] = @[rule]; draft[@"minimum"] = @9; CHECK(![SRConfiguration validateDraft:draft error:NULL]);
        draft[@"minimum"] = @10; draft[@"types"] = @[@"video"]; CHECK(![SRConfiguration validateDraft:draft error:NULL]);
        draft[@"types"] = @[@"image"]; CHECK([SRConfiguration validateDraft:draft error:NULL]);
        puts("PASS: guarded runtime, declared string ABI with misleading reflection, contact/session union, privacy and 12345-row drafts");
    }
    return 0;
}
