#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <sqlite3.h>
#import "Core/SRStore.h"
#import "Core/SRImageAssetStore.h"
#import "Core/SRMediaAlertState.h"
#import "Core/SRMediaQuota.h"
#include <assert.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#define CHECK(...) assert((__VA_ARGS__))

static const unsigned long long SRLimit = 268435456ULL;

static NSData *pngWithPixel(unsigned char red) {
    unsigned char pixels[24] = {red, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
        255, 255, 0, 255, 0, 255, 255, 255, 255, 0, 255, 255};
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, 2, 3, 8, 8, color, kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef output = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(output, image, NULL); CHECK(CGImageDestinationFinalize(output));
    CFRelease(output); CGImageRelease(image); CGContextRelease(context); CGColorSpaceRelease(color); return data;
}
static NSData *png(void) { return pngWithPixel(255); }
static NSDictionary *source(void) {
    return @{@"account": @"account", @"group": @"mother@chatroom", @"sender": @"sender",
        @"messageID": @"svr:11", @"type": @"image", @"generatedByRelay": @NO};
}
/* A sparse file occupies the budget without allocating real disk blocks. */
static NSString *sparseFile(NSString *directory, NSString *name, unsigned long long size) {
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSString *path = [directory stringByAppendingPathComponent:name];
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY, 0600); CHECK(fd >= 0);
    CHECK(ftruncate(fd, (off_t)size) == 0); close(fd);
    return path;
}
static unsigned long long usedBytes(SRImageAssetStore *assets, NSError **error) {
    NSDictionary *usage = [assets usageSnapshotProtectingTokens:nil error:error];
    CHECK(usage != nil);
    return [usage[@"usedBytes"] unsignedLongLongValue];
}
int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSData *data = png();
        NSError *error = nil;

        // 1. Empty directory reports a real zero, the shared limit and the level.
        NSString *budgetPath = [root stringByAppendingPathComponent:@"budget"];
        SRImageAssetStore *budget = [[SRImageAssetStore alloc] initWithDirectory:budgetPath];
        NSDictionary *usage = [budget usageSnapshotProtectingTokens:nil error:&error];
        CHECK(usage && !error);
        CHECK([usage[@"usedBytes"] unsignedLongLongValue] == 0);
        CHECK([usage[@"limitBytes"] unsignedLongLongValue] == SRLimit);
        CHECK([usage[@"remainingBytes"] unsignedLongLongValue] == SRLimit);
        CHECK([usage[@"level"] isEqual:@"normal"]);
        CHECK([usage[@"scanValid"] boolValue]);
        CHECK([usage[@"singleFileLimitBytes"] unsignedLongLongValue] == 20ULL * 1024 * 1024);
        CHECK(![usage[@"reclaimableComplete"] boolValue]);

        // 2. 80% is judged on bytes: 214748364 is below, 214748365 is not.
        NSString *below = sparseFile(budgetPath, @"below.srimage", 214748364ULL);
        usage = [budget usageSnapshotProtectingTokens:nil error:NULL];
        CHECK([usage[@"usedBytes"] unsignedLongLongValue] == 214748364ULL);
        CHECK([usage[@"level"] isEqual:@"normal"]);
        NSString *above = sparseFile(budgetPath, @"above.srimage", 1ULL);
        usage = [budget usageSnapshotProtectingTokens:nil error:NULL];
        CHECK([usage[@"usedBytes"] unsignedLongLongValue] == 214748365ULL);
        CHECK([usage[@"level"] isEqual:@"warning"]);
        CHECK([usage[@"remainingBytes"] unsignedLongLongValue] == SRLimit - 214748365ULL);
        CHECK([NSFileManager.defaultManager removeItemAtPath:below error:NULL]);
        CHECK([NSFileManager.defaultManager removeItemAtPath:above error:NULL]);

        // 3. Not full, but the new file does not fit: refused before any write.
        NSString *tightPath = [root stringByAppendingPathComponent:@"tight"];
        SRImageAssetStore *tight = [[SRImageAssetStore alloc] initWithDirectory:tightPath];
        sparseFile(tightPath, @"almost.srimage", SRLimit - 1);
        error = nil;
        CHECK(![tight saveData:data source:source() error:&error]);
        CHECK(error.code == SRImageAssetErrorQuotaExceeded);
        CHECK([error.userInfo[SRImageAssetShortfallBytesKey] unsignedLongLongValue] == data.length - 1);
        CHECK([error.userInfo[SRImageAssetLimitBytesKey] unsignedLongLongValue] == SRLimit);
        usage = [tight usageSnapshotProtectingTokens:nil error:NULL];
        CHECK([usage[@"fileCount"] unsignedLongLongValue] == 1);
        CHECK([usage[@"reservedBytes"] unsignedLongLongValue] == 0);
        CHECK(usedBytes(tight, NULL) == SRLimit - 1);

        // 4. Full quota still refuses a new object and reports the whole cost.
        sparseFile(budgetPath, @"full.srimage", SRLimit);
        usage = [budget usageSnapshotProtectingTokens:nil error:NULL];
        CHECK([usage[@"level"] isEqual:@"full"]);
        error = nil;
        CHECK(![budget saveData:data source:source() error:&error]);
        CHECK(error.code == SRImageAssetErrorQuotaExceeded);
        CHECK([NSFileManager.defaultManager removeItemAtPath:[budgetPath stringByAppendingPathComponent:@"full.srimage"]
            error:NULL]);

        // 5. Reservations are atomic: 64 concurrent 8 MiB requests cannot all win.
        NSString *concurrentPath = [root stringByAppendingPathComponent:@"concurrent"];
        SRImageAssetStore *concurrent = [[SRImageAssetStore alloc] initWithDirectory:concurrentPath];
        NSMutableArray<NSNumber *> *granted = [NSMutableArray array];
        NSLock *lock = [NSLock new];
        dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            (void)index;
            NSNumber *reservation = [concurrent reserveBytes:8ULL * 1024 * 1024 token:nil reuseOnly:NO error:NULL];
            if (!reservation) return;
            [lock lock]; [granted addObject:reservation]; [lock unlock];
        });
        CHECK(granted.count == 32);
        usage = [concurrent usageSnapshotProtectingTokens:nil error:NULL];
        CHECK([usage[@"reservedBytes"] unsignedLongLongValue] == SRLimit);
        CHECK([usage[@"remainingBytes"] unsignedLongLongValue] == 0);
        for (NSNumber *reservation in granted) CHECK([concurrent releaseReservation:reservation]);
        usage = [concurrent usageSnapshotProtectingTokens:nil error:NULL];
        CHECK([usage[@"reservedBytes"] unsignedLongLongValue] == 0);

        // 6. A failed write releases its reservation and leaves no partial file.
        NSString *lockedPath = [root stringByAppendingPathComponent:@"locked"];
        SRImageAssetStore *locked = [[SRImageAssetStore alloc] initWithDirectory:lockedPath];
        CHECK([locked saveData:data source:source() error:NULL]);
        NSUInteger expectedFiles = 1;
        if (geteuid() != 0) {
            CHECK(chmod(lockedPath.fileSystemRepresentation, 0500) == 0);
            error = nil;
            CHECK(![locked saveData:data source:source() error:&error]);
            CHECK(error.code == SRImageAssetErrorWriteFailed);
            CHECK(chmod(lockedPath.fileSystemRepresentation, 0700) == 0);
        } else {
            // A root shell can write into a 0500 directory; count what is there.
            expectedFiles = 2;
        }
        usage = [locked usageSnapshotProtectingTokens:nil error:NULL];
        CHECK([usage[@"reservedBytes"] unsignedLongLongValue] == 0);
        CHECK([usage[@"fileCount"] unsignedLongLongValue] == expectedFiles);

        // 7. Interrupted temporary files are reclaimed; live or new ones are not.
        NSString *tempPath = [root stringByAppendingPathComponent:@"temps"];
        SRImageAssetStore *tempStore = [[SRImageAssetStore alloc] initWithDirectory:tempPath];
        CHECK([tempStore saveData:data source:source() error:NULL]);
        NSString *stale = [tempPath stringByAppendingPathComponent:@"abandoned.srtmp"];
        CHECK([[NSData data] writeToFile:stale atomically:NO]);
        CHECK([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:
            [NSDate dateWithTimeIntervalSince1970:1000]} ofItemAtPath:stale error:NULL]);
        NSString *fresh = [tempPath stringByAppendingPathComponent:@"inflight.srtmp"];
        CHECK([[NSData data] writeToFile:fresh atomically:NO]);
        CHECK([tempStore pruneTemporaryFilesOlderThan:60] == 1);
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:stale]);
        CHECK([NSFileManager.defaultManager fileExistsAtPath:fresh]);
        CHECK([tempStore pruneTemporaryFilesOlderThan:0] == 1);
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:fresh]);
        usage = [tempStore usageSnapshotProtectingTokens:nil error:NULL];
        CHECK([usage[@"fileCount"] unsignedLongLongValue] == 1); /* the snapshot survives */

        // 8. A token with a live reservation is never pruned, even when unlisted.
        NSString *holdPath = [root stringByAppendingPathComponent:@"hold"];
        SRImageAssetStore *hold = [[SRImageAssetStore alloc] initWithDirectory:holdPath];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:holdPath withIntermediateDirectories:YES
            attributes:nil error:NULL]);
        NSString *heldToken = NSUUID.UUID.UUIDString;
        NSString *heldFile = [holdPath stringByAppendingPathComponent:[heldToken stringByAppendingString:@".srimage"]];
        CHECK([data writeToFile:heldFile atomically:NO]);
        NSNumber *reservation = [hold reserveBytes:0 token:heldToken reuseOnly:YES error:NULL];
        CHECK(reservation);
        [hold pruneUnreferenced:[NSSet set]];
        CHECK([NSFileManager.defaultManager fileExistsAtPath:heldFile]);
        CHECK([hold releaseReservation:reservation]);
        [hold pruneUnreferenced:[NSSet set]];
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:heldFile]);

        // 9. Legacy random-UUID snapshots stay while referenced, and non-UUID
        //    files are never treated as relay snapshots.
        NSString *legacyToken = NSUUID.UUID.UUIDString;
        NSString *legacyFile = [holdPath stringByAppendingPathComponent:[legacyToken stringByAppendingString:@".srimage"]];
        CHECK([data writeToFile:legacyFile atomically:NO]);
        NSString *foreignFile = [holdPath stringByAppendingPathComponent:@"wechat-cache.srimage"];
        CHECK([data writeToFile:foreignFile atomically:NO]);
        [hold pruneUnreferenced:[NSSet setWithObject:legacyToken]];
        CHECK([NSFileManager.defaultManager fileExistsAtPath:legacyFile]);
        CHECK([NSFileManager.defaultManager fileExistsAtPath:foreignFile]);

        // 10. An unreadable directory is an error, never a zero reading.
        NSString *outside = [root stringByAppendingPathComponent:@"outside"];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:outside withIntermediateDirectories:YES
            attributes:nil error:NULL]);
        NSString *link = [root stringByAppendingPathComponent:@"linked"];
        CHECK([NSFileManager.defaultManager createSymbolicLinkAtPath:link withDestinationPath:outside error:NULL]);
        SRImageAssetStore *linked = [[SRImageAssetStore alloc] initWithDirectory:link];
        error = nil;
        CHECK([linked usageSnapshotProtectingTokens:nil error:&error] == nil);
        CHECK(error.code == SRImageAssetErrorUsageUnavailable);
        error = nil;
        CHECK([linked reserveBytes:1024 token:nil reuseOnly:NO error:&error] == nil);
        CHECK(error.code == SRImageAssetErrorUsageUnavailable);

        // 11. Budget, reuse at full quota and the persisted reminder, via SRStore.
        NSString *path = [root stringByAppendingPathComponent:@"budget.sqlite3"];
        error = nil;
        SRStore *store = [[SRStore alloc] initWithPath:path error:&error]; CHECK(store);
        NSDictionary *library = [store saveLibraryImageData:data account:@"account" error:NULL];
        CHECK(library);
        NSDictionary *empty = [store mediaUsageForAccount:@"account" error:&error];
        CHECK(empty && !error);
        CHECK([empty[@"limitBytes"] unsignedLongLongValue] == SRLimit);
        CHECK(![empty[@"warningRaised"] boolValue]);
        CHECK(![[store claimMediaWarningForAccount:@"account" error:NULL] boolValue]);

        // A failed reference insert must not leave an orphaned snapshot behind.
        sqlite3 *db = NULL;
        CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
        CHECK(sqlite3_exec(db, "CREATE TRIGGER reject_media_asset BEFORE INSERT ON media_assets"
            " BEGIN SELECT RAISE(ABORT,'fault'); END", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(db) == SQLITE_OK);
        NSUInteger filesBefore = [[store mediaUsageForAccount:@"account" error:NULL][@"fileCount"] unsignedIntegerValue];
        error = nil;
        CHECK([store saveLibraryImageData:pngWithPixel(2) account:@"account" error:&error] == nil);
        NSUInteger filesAfter = [[store mediaUsageForAccount:@"account" error:NULL][@"fileCount"] unsignedIntegerValue];
        CHECK(filesBefore == filesAfter);
        CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
        CHECK(sqlite3_exec(db, "DROP TRIGGER reject_media_asset", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(db) == SQLITE_OK);

        NSString *directory = store.imageAssets.directory;
        unsigned long long committed = [empty[@"committedBytes"] unsignedLongLongValue];
        CHECK(committed == data.length);

        // Cross-account isolation: another account's media shares the same budget,
        // must be counted, and must survive this account's startup prune.
        NSData *otherBytes = pngWithPixel(4);
        NSDictionary *otherLibrary = [store saveLibraryImageData:otherBytes account:@"other" error:NULL];
        CHECK(otherLibrary && ![otherLibrary[@"mediaReference"] isEqual:library[@"mediaReference"]]);
        committed = [[store mediaUsageForAccount:@"account" error:NULL][@"committedBytes"] unsignedLongLongValue];
        CHECK(committed == data.length + otherBytes.length);

        sparseFile(directory, @"pressure.srimage", 214748365ULL - committed);
        NSNumber *warning = [store claimMediaWarningForAccount:@"account" error:NULL];
        CHECK([warning boolValue]);
        // A reminder never pauses, starts or rewrites a task.
        CHECK([store plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 0);
        CHECK(![[store claimMediaWarningForAccount:@"account" error:NULL] boolValue]);
        // Reopening replays neither the warning nor a revision of the stored flag.
        store = nil;
        store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        CHECK(![[store claimMediaWarningForAccount:@"account" error:NULL] boolValue]);
        CHECK([[store mediaUsageForAccount:@"account" error:NULL][@"warningRaised"] boolValue]);
        CHECK([[store.imageAssets dataForPayload:otherLibrary
            scopeSHA256:[SRImageAssetStore libraryScopeForAccount:@"other"] error:NULL] isEqual:otherBytes]);
        // Dropping below the 75% reset band clears, and the next crossing raises again.
        CHECK([NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:@"pressure.srimage"]
            error:NULL]);
        CHECK(![[store claimMediaWarningForAccount:@"account" error:NULL] boolValue]);
        CHECK(![[store mediaUsageForAccount:@"account" error:NULL][@"warningRaised"] boolValue]);

        // Exact byte reuse needs no new space, so it still works at full quota.
        sparseFile(directory, @"full.srimage", SRLimit - committed);
        error = nil;
        NSDictionary *reused = [store saveLibraryImageData:data account:@"account" error:&error];
        CHECK(reused && !error);
        CHECK([reused[@"mediaReference"] isEqual:library[@"mediaReference"]]);
        error = nil;
        CHECK(![store saveLibraryImageData:pngWithPixel(1) account:@"account" error:&error]);
        CHECK(error.code == SRImageAssetErrorQuotaExceeded);

        // The persisted state names no account, token or file.
        NSString *alertPath = [directory stringByAppendingPathComponent:SRMediaAlertFileName];
        NSString *state = [NSString stringWithContentsOfFile:alertPath encoding:NSUTF8StringEncoding error:NULL];
        CHECK(state.length > 0);
        CHECK([state rangeOfString:@"\"account\""].location == NSNotFound);
        CHECK([state rangeOfString:@".srimage"].location == NSNotFound);
        NSData *serialized = [NSJSONSerialization dataWithJSONObject:
            [store mediaUsageForAccount:@"account" error:NULL] options:0 error:NULL];
        NSString *projection = [[NSString alloc] initWithData:serialized encoding:NSUTF8StringEncoding];
        CHECK([projection rangeOfString:@"account"].location == NSNotFound);
        CHECK([projection rangeOfString:@".srimage"].location == NSNotFound);

        store = nil;
        CHECK([NSFileManager.defaultManager removeItemAtPath:root error:NULL]);
        puts("PASS: shared media budget, atomic reservations, write rollback, safe temp reclaim, reference protection and persisted warning");
    }
    return 0;
}
