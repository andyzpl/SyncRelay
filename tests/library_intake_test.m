#import <Foundation/Foundation.h>
#import "Core/SRStore.h"
#import "Core/SRLibraryIntake.h"
#import <sqlite3.h>
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

/* A store that fails exactly the first library write, to prove a failure is not
 * remembered as a success and that the retry can still save. */
@interface SRLibraryFailOnceStore : SRStore
@property(nonatomic) BOOL failedOnce;
@end

@implementation SRLibraryFailOnceStore
- (NSString *)createLibraryItemForAccount:(NSString *)account kind:(NSString *)kind
                                  payload:(NSDictionary *)payload capturedAt:(NSTimeInterval)capturedAt
                                    error:(NSError **)error {
    if (!self.failedOnce) {
        self.failedOnce = YES;
        if (error) *error = [NSError errorWithDomain:@"SyncRelay.Test" code:9
            userInfo:@{NSLocalizedDescriptionKey: @"simulated write failure"}];
        return nil;
    }
    return [super createLibraryItemForAccount:account kind:kind payload:payload
        capturedAt:capturedAt error:error];
}
@end

static NSUInteger scalar(sqlite3 *database, const char *sql) {
    sqlite3_stmt *statement = NULL;
    CHECK(sqlite3_prepare_v2(database, sql, -1, &statement, NULL) == SQLITE_OK);
    CHECK(sqlite3_step(statement) == SQLITE_ROW);
    NSUInteger value = (NSUInteger)sqlite3_column_int64(statement, 0);
    CHECK(sqlite3_finalize(statement) == SQLITE_OK);
    return value;
}

int main(void) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *path = [directory stringByAppendingPathComponent:@"intake.sqlite3"];
        SRStore *store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        SRLibraryIntake *intake = [[SRLibraryIntake alloc] initWithStore:store];

        // The shared accessor returns one instance per store, so a second tap
        // reaches the same ledger instead of a fresh one.
        CHECK([SRLibraryIntake intakeForStore:store] == [SRLibraryIntake intakeForStore:store]);
        CHECK([SRLibraryIntake intakeForStore:store] != intake);

        NSMutableString *longText = [NSMutableString string];
        for (NSUInteger i = 0; i < 400; i++) [longText appendFormat:@"第%lu段 synthetic body ", (unsigned long)i];
        CHECK(longText.length > 5000);
        SRLibraryIntakeResult result = SRLibraryIntakeWriteFailed;
        NSError *error = nil;
        NSTimeInterval capturedAt = 1792800000;
        NSString *first = [intake saveText:longText operationKey:@"op-1" account:@"account"
            capturedAt:capturedAt result:&result error:&error];
        CHECK(first.length && result == SRLibraryIntakeSaved && error == nil);
        NSDictionary *stored = [store libraryItem:first account:@"account" error:NULL];
        CHECK(stored && [stored[@"kind"] isEqual:@"text"]);
        CHECK([stored[@"versions"] count] == 1);
        CHECK([stored[@"versions"][0][@"payload"][@"text"] isEqual:longText]);
        CHECK([stored[@"versions"][0][@"captured_at"] isEqual:@(capturedAt)]);
        CHECK([[NSSet setWithArray:[stored[@"versions"][0][@"payload"] allKeys]] isEqualToSet:[NSSet setWithObject:@"text"]]);

        // The same request repeats as a duplicate with the same entry.
        NSString *again = [intake saveText:longText operationKey:@"op-1" account:@"account"
            capturedAt:capturedAt result:&result error:NULL];
        CHECK([again isEqual:first] && result == SRLibraryIntakeDuplicate);
        CHECK([[store libraryItem:first account:@"account" error:NULL][@"versions"] count] == 1);
        CHECK([intake hasSavedOperationKey:@"op-1" account:@"account"]);
        // The query is account-bound: the same key under another account is not "saved".
        CHECK(![intake hasSavedOperationKey:@"op-1" account:@"other"]);

        // A reused key with a different request is refused, not resolved to the
        // earlier entry, and it never writes.
        result = SRLibraryIntakeSaved;
        CHECK(![intake saveText:longText operationKey:@"op-1" account:@"other" capturedAt:capturedAt result:&result error:NULL]);
        CHECK(result == SRLibraryIntakeConflictingRequest);
        CHECK(![intake saveText:@"a different body" operationKey:@"op-1" account:@"account"
            capturedAt:capturedAt result:&result error:NULL]);
        CHECK(result == SRLibraryIntakeConflictingRequest);
        CHECK(![intake saveMessageOfType:@"image" payload:@{@"text": longText} operationKey:@"op-1"
            account:@"account" capturedAt:capturedAt result:&result error:NULL]);
        CHECK(result == SRLibraryIntakeUnsupportedType);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == 1);
        CHECK(![store libraryItem:first account:@"other" error:NULL]);

        // The same text from a different message is a different entry.
        NSString *second = [intake saveText:longText operationKey:@"op-2" account:@"account"
            capturedAt:capturedAt result:&result error:NULL];
        CHECK(second.length && ![second isEqual:first] && result == SRLibraryIntakeSaved);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == 2);

        // Every other type is refused and leaves no row.
        for (NSString *type in @[@"image", @"video", @"voice", @"link", @"file", @""]) {
            result = SRLibraryIntakeSaved;
            CHECK(![intake saveMessageOfType:type payload:@{@"text": @"ignored"} operationKey:@"op-3"
                account:@"account" capturedAt:capturedAt result:&result error:NULL]);
            CHECK(result == SRLibraryIntakeUnsupportedType);
        }
        CHECK(![intake saveText:@"" operationKey:@"op-4" account:@"account" capturedAt:capturedAt result:&result error:NULL]);
        CHECK(result == SRLibraryIntakeInvalidInput);
        CHECK(![intake saveText:@"body" operationKey:@"" account:@"account" capturedAt:capturedAt result:&result error:NULL]);
        CHECK(result == SRLibraryIntakeInvalidInput);
        CHECK(![intake saveText:@"body" operationKey:@"op-5" account:@"" capturedAt:capturedAt result:&result error:NULL]);
        CHECK(result == SRLibraryIntakeAccountUnavailable);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == 2);

        // Concurrent calls for one operation: all agree on one entry and exactly
        // one version is written.
        NSString *concurrentKey = @"op-concurrent";
        NSString *concurrentBody = @"并行 synthetic body";
        dispatch_queue_t queue = dispatch_queue_create("intake.concurrent", DISPATCH_QUEUE_CONCURRENT);
        dispatch_group_t group = dispatch_group_create();
        NSMutableArray *returned = [NSMutableArray array];
        NSLock *appendLock = [NSLock new];
        for (NSUInteger i = 0; i < 8; i++) {
            dispatch_group_async(group, queue, ^{
                SRLibraryIntakeResult local = SRLibraryIntakeWriteFailed;
                NSString *item = [intake saveText:concurrentBody operationKey:concurrentKey
                    account:@"account" capturedAt:capturedAt result:&local error:NULL];
                CHECK(item.length);
                [appendLock lock]; [returned addObject:item]; [appendLock unlock];
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        CHECK(returned.count == 8);
        CHECK([[NSSet setWithArray:returned] count] == 1);
        NSString *winner = returned.firstObject;
        CHECK([[store libraryItem:winner account:@"account" error:NULL][@"versions"] count] == 1);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == 3);

        // A failed write is not remembered: the same operation can still save once.
        NSString *failPath = [directory stringByAppendingPathComponent:@"fail.sqlite3"];
        SRLibraryFailOnceStore *failing = [[SRLibraryFailOnceStore alloc] initWithPath:failPath error:NULL];
        CHECK(failing);
        SRLibraryIntake *failingIntake = [[SRLibraryIntake alloc] initWithStore:failing];
        result = SRLibraryIntakeSaved;
        CHECK(![failingIntake saveText:@"retry me" operationKey:@"op-retry" account:@"account"
            capturedAt:capturedAt result:&result error:NULL]);
        CHECK(result == SRLibraryIntakeWriteFailed);
        CHECK(![failingIntake hasSavedOperationKey:@"op-retry" account:@"account"]);
        CHECK([[failing libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == 0);
        NSString *retried = [failingIntake saveText:@"retry me" operationKey:@"op-retry" account:@"account"
            capturedAt:capturedAt result:&result error:NULL];
        CHECK(retried.length && result == SRLibraryIntakeSaved);
        CHECK([[failing libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == 1);

        // Intake creates no task, run, claim or delivery and sends nothing.
        sqlite3 *database = NULL;
        CHECK(sqlite3_open(path.fileSystemRepresentation, &database) == SQLITE_OK);
        CHECK(scalar(database, "SELECT COUNT(*) FROM library_tasks") == 0);
        CHECK(scalar(database, "SELECT COUNT(*) FROM runs") == 0);
        CHECK(scalar(database, "SELECT COUNT(*) FROM deliveries") == 0);
        CHECK(scalar(database, "SELECT COUNT(*) FROM source_claims") == 0);
        CHECK(sqlite3_close(database) == SQLITE_OK);

        // The body is durable, not a page cache.
        store = nil; intake = nil; failing = nil;
        store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        CHECK([[store libraryItem:first account:@"account" error:NULL][@"versions"][0][@"payload"][@"text"] isEqual:longText]);
        store = nil;
        CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: text intake binds one operation key to one request, refuses a reused key, writes once "
             "under one serialization, keeps failures retryable and creates no task, run or delivery");
    }
    return 0;
}
