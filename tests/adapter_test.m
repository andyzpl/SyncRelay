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
@interface FakeCenter : NSObject
+ (id)defaultCenter;
- (id)getService:(Class)type;
@end
@implementation FakeCenter
+ (id)defaultCenter { return [[self alloc] init]; }
- (id)getService:(Class)type { CHECK(type == FakeManager.class); return fixture; }
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

static FakeContact *contact(NSString *identifier, NSString *name) {
    FakeContact *value = [[FakeContact alloc] init]; value.m_nsUsrName = identifier; value.m_nsNickName = name; return value;
}
static SRWeChatReader *reader(NSString *version) {
    return [[SRWeChatReader alloc] initWithVersion:version classResolver:^Class(NSString *name) {
        if ([name isEqual:@"MMServiceCenter"]) return FakeCenter.class;
        if ([name isEqual:@"CContactMgr"]) return FakeManager.class;
        if ([name isEqual:@"CContact"]) return FakeContact.class;
        return Nil;
    }];
}

int main(void) {
    @autoreleasepool {
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
        for (int i = 0; i < 2000; i++) [contacts addObject:contact([NSString stringWithFormat:@"group-%d@chatroom", i], @"Group")];
        fixture.contacts = contacts;
        for (NSString *version in @[@"8.0.76", @"8.0.79"]) {
            SRWeChatReader *r = reader(version);
            CHECK([r connect:NULL]); CHECK([r.accountID isEqual:@"wxid_me"]);
            CHECK([r groups:NULL].count == 2001);
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

        NSArray *rows = [reader(@"8.0.79") groups:NULL];
        CHECK(!rows); // Explicit connect is required before reading.
        SRWeChatReader *r = reader(@"8.0.79"); CHECK([r connect:NULL]); rows = [r groups:NULL];
        SRSelection *selection = [[SRSelection alloc] initWithRows:rows excludedIDs:[NSSet setWithObject:@"source@chatroom"] selectedIDs:NSSet.set];
        CHECK(selection.rows.count == 2000);
        [selection selectFirst:200]; CHECK(selection.selectedRows.count == 200);
        CHECK([selection rowsMatching:@"group-1999"].count == 1);
        CHECK(selection.selectedRows.count == 200);
        [selection selectFirst:NSUIntegerMax]; CHECK(selection.selectedRows.count == 2000);
        [selection toggle:@"source@chatroom"]; CHECK(selection.selectedRows.count == 2000);
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
        puts("PASS: guarded runtime calls, mock reader contracts, account isolation, 2000-row selection and draft validation");
    }
    return 0;
}
