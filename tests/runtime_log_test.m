#import <Foundation/Foundation.h>
#import "Core/SRRuntimeLog.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

int main(void) {
    @autoreleasepool {
        SRRuntimeLog *log = [[SRRuntimeLog alloc] init];
        [log record:@"untrusted_wxid_secret" facts:@{}]; CHECK([log.snapshot[@"events"] count] == 0);
        NSMutableDictionary *facts = [@{@"senderCount": @1, @"sourceSelected": @YES, @"messageID": @123456,
            @"wxid": @"wxid_secret", @"group": @"secret@chatroom", @"body": @"private message",
            @"ruleCount": @"private message", @"errorCode": @14} mutableCopy];
        [log record:@"capture_arm_failed" facts:facts]; facts[@"senderCount"] = @99;
        NSDictionary *event = [log.snapshot[@"events"] lastObject];
        CHECK([event[@"facts"] count] == 3 && [event[@"facts"][@"senderCount"] isEqual:@1]);
        NSString *serialized = log.snapshot.description;
        for (NSString *secret in @[@"wxid_secret", @"secret@chatroom", @"private message", @"123456"])
            CHECK(![serialized containsString:secret]);
        for (NSUInteger i = 0; i < 1000; i++) [log record:@"capture_attempt" facts:@{@"ruleCount": @(i)}];
        CHECK([log.snapshot[@"events"] count] == 300);
        CHECK([log.snapshot[@"events"][0][@"facts"][@"ruleCount"] isEqual:@700]);
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *path = [directory stringByAppendingPathComponent:@"runtime.json"];
        [log enablePersistenceAtPath:path]; [log record:@"draft_saved" facts:@{@"ruleCount": @2}];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (![NSFileManager.defaultManager fileExistsAtPath:path] && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.02];
        CHECK([NSFileManager.defaultManager fileExistsAtPath:path]);
        SRRuntimeLog *reopened = [[SRRuntimeLog alloc] init]; [reopened enablePersistenceAtPath:path];
        CHECK([reopened.snapshot[@"events"] count] == 300);
        CHECK([[reopened.snapshot[@"events"] lastObject][@"event"] isEqual:@"draft_saved"]);
        CHECK([[reopened.snapshot[@"events"] lastObject][@"previousLaunch"] boolValue]);
        CHECK(![[[reopened.snapshot[@"events"] lastObject] allKeys] containsObject:@"session"]);
        CHECK([NSJSONSerialization isValidJSONObject:reopened.snapshot]);
        log = nil; reopened = nil;
        CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: bounded redacted runtime log, fixed event allowlist, numeric facts, immutable snapshot, coalesced persistence and reopen");
    }
    return 0;
}
