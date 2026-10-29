#import <Foundation/Foundation.h>
#import "Core/SRStore.h"
#import "Core/SRLibraryIntake.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

/* Store double: blocks the first library write inside the intake's critical
 * section until the test gates it, and counts how many writes it ever sees.
 * The handshake is a semaphore barrier, not a sleep, so the interleaving is
 * reproducible instead of merely probable. */
@interface SRBlockingStore : SRStore
@property(nonatomic, strong) dispatch_semaphore_t entered;
@property(nonatomic, strong) dispatch_semaphore_t gate;
@property(nonatomic) NSUInteger writes;
@property(nonatomic, strong) NSLock *counterLock;
@end

@implementation SRBlockingStore
- (NSString *)createLibraryItemForAccount:(NSString *)account kind:(NSString *)kind
                                  payload:(NSDictionary *)payload capturedAt:(NSTimeInterval)capturedAt
                                    error:(NSError **)error {
    [self.counterLock lock]; self.writes += 1; [self.counterLock unlock];
    dispatch_semaphore_signal(self.entered);
    // The caller holds the intake lock here; the second caller must wait.
    dispatch_semaphore_wait(self.gate, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return [super createLibraryItemForAccount:account kind:kind payload:payload
        capturedAt:capturedAt error:error];
}
@end

int main(void) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);

        // --- Ownership: the intake must not keep a gated store alive. ---
        NSString *path = [directory stringByAppendingPathComponent:@"life.sqlite3"];
        SRLibraryIntake *intake = nil;
        __weak SRStore *weakStore = nil;
        @autoreleasepool {
            SRStore *store = [[SRStore alloc] initWithPath:path error:NULL];
            CHECK(store);
            weakStore = store;
            intake = [SRLibraryIntake intakeForStore:store];
            CHECK(intake);
            SRLibraryIntakeResult result = SRLibraryIntakeWriteFailed;
            CHECK([[intake saveText:@"before gate" operationKey:@"life-1" account:@"account"
                capturedAt:1792800000 result:&result error:NULL] length]);
            CHECK(result == SRLibraryIntakeSaved);
            store = nil;
        }
        CHECK(weakStore == nil);
        // A dead store is refused, and the remembered entry is not replayed as
        // a success: the ledger still knows the key, but nothing is returned.
        SRLibraryIntakeResult dead = SRLibraryIntakeSaved;
        CHECK(![intake saveText:@"before gate" operationKey:@"life-1" account:@"account"
            capturedAt:1792800000 result:&dead error:NULL]);
        CHECK(dead == SRLibraryIntakeStoreUnavailable);
        CHECK([intake hasSavedOperationKey:@"life-1" account:@"account"]);

        // --- Controlled interleaving for one operation key. ---
        NSString *racePath = [directory stringByAppendingPathComponent:@"race.sqlite3"];
        SRBlockingStore *store = [[SRBlockingStore alloc] initWithPath:racePath error:NULL];
        CHECK(store);
        store.entered = dispatch_semaphore_create(0);
        store.gate = dispatch_semaphore_create(0);
        store.counterLock = [NSLock new];
        SRLibraryIntake *raceIntake = [[SRLibraryIntake alloc] initWithStore:store];

        __block NSString *firstID = nil;
        __block SRLibraryIntakeResult firstResult = SRLibraryIntakeWriteFailed;
        __block NSString *secondID = nil;
        __block SRLibraryIntakeResult secondResult = SRLibraryIntakeWriteFailed;
        dispatch_queue_t queue = dispatch_queue_create("intake.race", DISPATCH_QUEUE_CONCURRENT);

        dispatch_async(queue, ^{
            firstID = [raceIntake saveText:@"race body" operationKey:@"race-1" account:@"account"
                capturedAt:1792800000 result:&firstResult error:NULL];
        });
        // The first caller is now inside createLibraryItem… holding the lock.
        CHECK(dispatch_semaphore_wait(store.entered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
        CHECK(store.writes == 1);
        dispatch_async(queue, ^{
            secondID = [raceIntake saveText:@"race body" operationKey:@"race-1" account:@"account"
                capturedAt:1792800000 result:&secondResult error:NULL];
        });
        // Release the first write; the second can only proceed after it finished.
        dispatch_semaphore_signal(store.gate);

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        while ((!firstID || !secondID) && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        CHECK(firstID.length && secondID.length);
        CHECK([firstID isEqual:secondID]);
        CHECK(firstResult == SRLibraryIntakeSaved);
        CHECK(secondResult == SRLibraryIntakeDuplicate);
        // The decisive assertion: the store was never asked to write twice.
        CHECK(store.writes == 1);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == 1);

        CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: intake holds its store weakly, refuses a gated store instead of replaying a "
             "duplicate, and one operation key writes exactly once under a controlled interleaving");
    }
    return 0;
}
