#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <sqlite3.h>
#import "Core/SRStore.h"
#import "Core/SRConfiguration.h"
#import "Core/SRImageAssetStore.h"
#include <assert.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#define CHECK(...) assert((__VA_ARGS__))

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
/* A sparse file occupies the shared budget without allocating real blocks. */
static void fillBudget(NSString *directory, unsigned long long size) {
    NSString *path = [directory stringByAppendingPathComponent:@"library-pressure.srimage"];
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY, 0600); CHECK(fd >= 0);
    CHECK(ftruncate(fd, (off_t)size) == 0); close(fd);
}
static void clearBudget(NSString *directory) {
    NSString *path = [directory stringByAppendingPathComponent:@"library-pressure.srimage"];
    CHECK([NSFileManager.defaultManager removeItemAtPath:path error:NULL]);
}
/* Row count read from a second connection: the store keeps no transaction open
 * between calls, so this is the durable state after a failed save. */
static NSUInteger mediaRow(NSString *path, NSString *account, NSString *digest) {
    sqlite3 *db = NULL; sqlite3_stmt *statement = NULL; NSUInteger count = 0;
    CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
    CHECK(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM media_assets WHERE account=? AND scope_kind='message_library' AND sha256=?", -1, &statement, NULL) == SQLITE_OK);
    sqlite3_bind_text(statement, 1, account.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 2, digest.UTF8String, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(statement) == SQLITE_ROW) count = (NSUInteger)sqlite3_column_int64(statement, 0);
    sqlite3_finalize(statement); sqlite3_close(db);
    return count;
}
static NSDictionary *usageOf(SRStore *store) {
    NSDictionary *usage = [store mediaUsageForAccount:@"account" error:NULL];
    CHECK(usage);
    return usage;
}
static NSString *mediaToken(NSString *path, NSString *account, NSString *digest) {
    sqlite3 *db = NULL; sqlite3_stmt *statement = NULL; NSString *token = nil;
    CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
    CHECK(sqlite3_prepare_v2(db, "SELECT token FROM media_assets WHERE account=? AND scope_kind='message_library' AND sha256=?", -1, &statement, NULL) == SQLITE_OK);
    sqlite3_bind_text(statement, 1, account.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 2, digest.UTF8String, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(statement) == SQLITE_ROW) {
        const unsigned char *text = sqlite3_column_text(statement, 0);
        if (text) token = @((const char *)text);
    }
    sqlite3_finalize(statement); sqlite3_close(db);
    return token;
}
/* COMMIT is the only failure a statement-level trigger cannot produce. A deferred
 * foreign key defers its check to COMMIT, so the insert succeeds and the commit
 * fails. The probe lives in the test database only, never in product code. */
static void installCommitFault(NSString *path) {
    sqlite3 *db = NULL;
    CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
    CHECK(sqlite3_exec(db, "DROP TABLE IF EXISTS commit_probe", NULL, NULL, NULL) == SQLITE_OK);
    CHECK(sqlite3_exec(db, "CREATE TABLE commit_probe(id INTEGER PRIMARY KEY, token TEXT"
        " REFERENCES media_assets(token) DEFERRABLE INITIALLY DEFERRED)", NULL, NULL, NULL) == SQLITE_OK);
    CHECK(sqlite3_exec(db, "CREATE TRIGGER fail_commit AFTER INSERT ON media_assets"
        " BEGIN INSERT INTO commit_probe(token) VALUES('missing-token'); END", NULL, NULL, NULL) == SQLITE_OK);
    CHECK(sqlite3_close(db) == SQLITE_OK);
}
static void removeCommitFault(NSString *path) {
    sqlite3 *db = NULL;
    CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
    CHECK(sqlite3_exec(db, "DROP TRIGGER IF EXISTS fail_commit", NULL, NULL, NULL) == SQLITE_OK);
    CHECK(sqlite3_exec(db, "DROP TABLE IF EXISTS commit_probe", NULL, NULL, NULL) == SQLITE_OK);
    CHECK(sqlite3_close(db) == SQLITE_OK);
}
static NSDictionary *configuration(void) {
    NSMutableDictionary *draft = [SRConfiguration emptyDraft];
    draft[@"sourceGroup"] = @{@"id": @"mother@chatroom", @"name": @"Mother"};
    draft[@"senders"] = @[@{@"id": @"wxid_sender", @"name": @"Sender"}];
    draft[@"types"] = @[@"text"];
    draft[@"rules"] = @[@{@"id": @"rule", @"name": @"First", @"targets": @[@{@"id": @"target@chatroom", @"name": @"Target"}]}];
    return draft;
}
static NSDictionary *envelope(void) {
    return @{@"account": @"account", @"group": @"mother@chatroom", @"sender": @"wxid_sender",
        @"messageID": @"svr:library-test", @"type": @"text", @"generatedByRelay": @NO,
        @"payload": @{@"text": @"group body"}};
}
static NSUInteger versionCount(SRStore *store, NSString *item) {
    return [[store libraryItem:item account:@"account" error:NULL][@"versions"] count];
}
static NSUInteger itemCount(SRStore *store, NSString *account) {
    return [store libraryItemsForAccount:account limit:100 offset:0 error:NULL].count;
}
int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *path = [root stringByAppendingPathComponent:@"library.sqlite3"];
        NSError *error = nil;
        SRStore *store = [[SRStore alloc] initWithPath:path error:&error]; CHECK(store);

        // Text entries: stable ID, immutable versions, explicit edit.
        NSString *text = [store createLibraryItemForAccount:@"account" kind:@"text"
            payload:@{@"text": @"first body"} capturedAt:100 error:&error];
        CHECK(text && !error);
        NSDictionary *card = [store libraryItem:text account:@"account" error:NULL];
        CHECK([card[@"kind"] isEqual:@"text"] && [card[@"versions"] count] == 1);
        NSString *first = card[@"current_version_id"];
        CHECK([card[@"versions"][0][@"payload"][@"text"] isEqual:@"first body"]);
        CHECK([card[@"versions"][0][@"ordinal"] isEqual:@1]);
        CHECK(![store libraryItem:text account:@"other" error:NULL]);
        CHECK(itemCount(store, @"other") == 0);
        CHECK(![store appendLibraryVersion:text account:@"other" payload:@{@"text": @"hijack"}
            expectedVersion:nil capturedAt:101 error:NULL]);
        NSString *second = [store appendLibraryVersion:text account:@"account" payload:@{@"text": @"edited body"}
            expectedVersion:first capturedAt:101 error:NULL];
        CHECK(second && ![second isEqual:first]);
        card = [store libraryItem:text account:@"account" error:NULL];
        CHECK([card[@"versions"] count] == 2 && [card[@"current_version_id"] isEqual:second]);
        CHECK([card[@"versions"][0][@"payload"][@"text"] isEqual:@"first body"]);
        CHECK([card[@"versions"][1][@"payload"][@"text"] isEqual:@"edited body"]);
        CHECK([card[@"versions"][1][@"ordinal"] isEqual:@2]);
        // A stale editor must not silently overwrite the newer version.
        CHECK(![store appendLibraryVersion:text account:@"account" payload:@{@"text": @"stale edit"}
            expectedVersion:first capturedAt:102 error:NULL]);
        CHECK(versionCount(store, text) == 2);
        // A library body may not carry a group, account or server message identity.
        CHECK(![store createLibraryItemForAccount:@"account" kind:@"text"
            payload:@{@"text": @"x", @"group": @"mother@chatroom"} capturedAt:100 error:NULL]);
        CHECK(![store createLibraryItemForAccount:@"account" kind:@"text"
            payload:@{@"text": @""} capturedAt:100 error:NULL]);
        CHECK(![store createLibraryItemForAccount:@"account" kind:@"text"
            payload:@{@"text": @"x"} capturedAt:0 error:NULL]);
        CHECK(![store createLibraryItemForAccount:@"" kind:@"text"
            payload:@{@"text": @"x"} capturedAt:100 error:NULL]);
        CHECK(![store createLibraryItemForAccount:@"account" kind:@"video"
            payload:@{@"text": @"x"} capturedAt:100 error:NULL]);

        // Saving into the library stays possible while a capture slot is occupied,
        // and it must not create a plan, run, delivery or source claim.
        NSString *content = [store saveOperationsContent:envelope() configuration:configuration()
            account:@"account" capturedAt:200 error:NULL];
        CHECK(content);
        NSString *occupied = [store createLibraryItemForAccount:@"account" kind:@"text"
            payload:@{@"text": @"while capture is occupied"} capturedAt:201 error:NULL];
        CHECK(occupied);
        CHECK([store plansForAccount:@"account" limit:10 offset:0 error:NULL].count == 0);
        // A library entry is not an operations content and cannot be resolved as one.
        CHECK(![store sourceForOperationsContent:text account:@"account" error:NULL]);

        // Image entries: one token per identical byte set inside one account.
        NSData *bytes = png();
        NSString *scope = [SRImageAssetStore libraryScopeForAccount:@"account"];
        NSDictionary *asset = [store saveLibraryImageData:bytes account:@"account" error:NULL];
        CHECK(asset && [SRImageAssetStore validPayload:asset]);
        NSDictionary *again = [store saveLibraryImageData:bytes account:@"account" error:NULL];
        CHECK([again[@"mediaReference"] isEqual:asset[@"mediaReference"]]);
        CHECK([[store.imageAssets dataForPayload:asset scopeSHA256:scope error:NULL] isEqual:bytes]);
        NSDictionary *otherAsset = [store saveLibraryImageData:bytes account:@"other" error:NULL];
        CHECK(otherAsset && ![otherAsset[@"mediaReference"] isEqual:asset[@"mediaReference"]]);
        NSString *imageOne = [store createLibraryItemForAccount:@"account" kind:@"image" payload:asset capturedAt:110 error:NULL];
        NSString *imageTwo = [store createLibraryItemForAccount:@"account" kind:@"image" payload:again capturedAt:111 error:NULL];
        CHECK(imageOne && imageTwo && ![imageOne isEqual:imageTwo]);
        CHECK([store libraryItem:imageOne account:@"account" error:NULL][@"versions"][0][@"media_token"] != nil);
        CHECK(![store createLibraryItemForAccount:@"account" kind:@"image" payload:otherAsset capturedAt:112 error:NULL]);
        NSDictionary *groupAsset = [store.imageAssets saveData:bytes source:@{@"account": @"account",
            @"group": @"mother@chatroom", @"sender": @"wxid_sender", @"messageID": @"svr:group"} error:NULL];
        CHECK(groupAsset && ![store createLibraryItemForAccount:@"account" kind:@"image"
            payload:groupAsset capturedAt:113 error:NULL]);
        // The same entry can take a new image version without merging entries.
        CHECK([store appendLibraryVersion:imageOne account:@"account" payload:asset
            expectedVersion:nil capturedAt:114 error:NULL]);
        CHECK(versionCount(store, imageOne) == 2);
        CHECK(itemCount(store, @"account") == 4);

        // Group sync origin is recorded without rewriting the capture path.
        NSDictionary *current = [store operationsContentForAccount:@"account" error:NULL][@"current"];
        CHECK([current isKindOfClass:NSDictionary.class]);
        NSDictionary *origin = [store sourceForOperationsContent:current[@"id"] account:@"account" error:NULL];
        CHECK([origin[@"source_kind"] isEqual:@"group_sync"] && [origin[@"library_item_id"] isEqual:NSNull.null]);
        CHECK(![store sourceForOperationsContent:current[@"id"] account:@"other" error:NULL]);

        // Reopening prunes unreferenced media; library bytes must survive it.
        store = nil;
        store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        CHECK([[store.imageAssets dataForPayload:asset scopeSHA256:scope error:NULL] isEqual:bytes]);
        CHECK([store libraryItem:imageOne account:@"account" error:NULL][@"versions"][0][@"media_token"] != nil);
        CHECK([[store sourceForOperationsContent:current[@"id"] account:@"account" error:NULL][@"source_kind"]
            isEqual:@"group_sync"]);

        // A failed version insert must roll the entry insert back.
        NSUInteger before = itemCount(store, @"account");
        sqlite3 *db = NULL;
        CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
        CHECK(sqlite3_exec(db, "CREATE TRIGGER reject_library_version BEFORE INSERT ON library_versions"
            " BEGIN SELECT RAISE(ABORT,'fault'); END", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(db) == SQLITE_OK);
        CHECK(![store createLibraryItemForAccount:@"account" kind:@"text"
            payload:@{@"text": @"rolled back"} capturedAt:300 error:NULL]);
        CHECK(itemCount(store, @"account") == before);
        CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
        CHECK(sqlite3_exec(db, "DROP TRIGGER reject_library_version", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(db) == SQLITE_OK);
        CHECK([store createLibraryItemForAccount:@"account" kind:@"text"
            payload:@{@"text": @"after rollback"} capturedAt:301 error:NULL]);
        CHECK(itemCount(store, @"account") == before + 1);

        // Image save failures: the material error keeps its domain, code and
        // quota detail, a NULL out-parameter is safe, and a database failure
        // leaves neither a row, a file nor a reservation behind.
        NSString *directory = store.imageAssets.directory;
        NSString *accountScope = [SRImageAssetStore libraryScopeForAccount:@"account"];
        NSData *distinct = pngWithPixel(2);
        NSString *digest = [SRImageAssetStore sha256ForData:distinct];
        CHECK(digest.length > 0);

        // Not a raster snapshot: a material error, not a store error.
        NSError *assetError = nil;
        CHECK(![store saveLibraryImageData:[NSData dataWithBytes:"not an image" length:12]
            account:@"account" error:&assetError]);
        CHECK([assetError.domain isEqual:@"SyncRelay.ImageAsset"]);
        CHECK(assetError.code == SRImageAssetErrorInvalidSnapshot);
        CHECK([assetError.userInfo[NSLocalizedDescriptionKey] length] > 0);

        // Over the single-file limit, classified before any raster or quota work.
        NSDictionary *usage = usageOf(store);
        unsigned long long singleLimit = [usage[@"singleFileLimitBytes"] unsignedLongLongValue];
        CHECK(singleLimit > 0);
        NSMutableData *oversized = [NSMutableData dataWithLength:(NSUInteger)singleLimit + 1];
        assetError = nil;
        CHECK(![store saveLibraryImageData:oversized account:@"account" error:&assetError]);
        CHECK([assetError.domain isEqual:@"SyncRelay.ImageAsset"]);
        CHECK(assetError.code == SRImageAssetErrorSingleFileExceeded);
        CHECK([assetError.userInfo[SRImageAssetLimitBytesKey] unsignedLongLongValue] == singleLimit);

        // A directory that cannot be written reports a write failure, not a
        // quota or a store error, and leaves no row or file behind.
        if (geteuid() != 0) {
            usage = usageOf(store);
            NSUInteger filesBeforeWrite = [usage[@"fileCount"] unsignedIntegerValue];
            CHECK(chmod(directory.fileSystemRepresentation, 0500) == 0);
            assetError = nil;
            CHECK(![store saveLibraryImageData:distinct account:@"account" error:&assetError]);
            CHECK([assetError.domain isEqual:@"SyncRelay.ImageAsset"]);
            CHECK(assetError.code == SRImageAssetErrorWriteFailed);
            CHECK(chmod(directory.fileSystemRepresentation, 0700) == 0);
            CHECK(mediaRow(path, @"account", digest) == 0);
            usage = usageOf(store);
            CHECK([usage[@"fileCount"] unsignedIntegerValue] == filesBeforeWrite);
        }

        // A full budget refuses the write and keeps the tuple a caller needs.
        usage = usageOf(store);
        NSUInteger filesBefore = [usage[@"fileCount"] unsignedIntegerValue];
        fillBudget(directory, 268435456ULL);
        assetError = nil;
        CHECK(![store saveLibraryImageData:distinct account:@"account" error:&assetError]);
        CHECK([assetError.domain isEqual:@"SyncRelay.ImageAsset"]);
        CHECK(assetError.code == SRImageAssetErrorQuotaExceeded);
        CHECK([assetError.userInfo[SRImageAssetShortfallBytesKey] unsignedLongLongValue] > 0);
        CHECK([assetError.userInfo[SRImageAssetUsedBytesKey] unsignedLongLongValue] > 0);
        CHECK([assetError.userInfo[SRImageAssetLimitBytesKey] unsignedLongLongValue] == 268435456ULL);
        CHECK(mediaRow(path, @"account", digest) == 0);
        // Only the sparse file was added: the refused bytes left no snapshot.
        usage = usageOf(store);
        CHECK([usage[@"fileCount"] unsignedIntegerValue] == filesBefore + 1);
        CHECK([usage[@"reservedBytes"] unsignedLongLongValue] == 0);
        // The same failure with a NULL out-parameter must not crash or write.
        CHECK(![store saveLibraryImageData:distinct account:@"account" error:NULL]);
        CHECK(mediaRow(path, @"account", digest) == 0);

        // The bytes can be written but not referenced: report the store error,
        // roll back, and discard the orphan instead of keeping it for a restart.
        clearBudget(directory);
        usage = usageOf(store);
        NSUInteger filesAtRest = [usage[@"fileCount"] unsignedIntegerValue];
        CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
        CHECK(sqlite3_exec(db, "CREATE TRIGGER reject_library_media BEFORE INSERT ON media_assets"
            " BEGIN SELECT RAISE(ABORT,'fault'); END", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(db) == SQLITE_OK);
        NSError *storeError = nil;
        CHECK(![store saveLibraryImageData:distinct account:@"account" error:&storeError]);
        CHECK([storeError.domain isEqual:@"SyncRelay.Store"] && storeError.code == 1);
        CHECK(mediaRow(path, @"account", digest) == 0);
        usage = usageOf(store);
        CHECK([usage[@"fileCount"] unsignedIntegerValue] == filesAtRest);
        CHECK([usage[@"reservedBytes"] unsignedLongLongValue] == 0);
        CHECK(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK);
        CHECK(sqlite3_exec(db, "DROP TRIGGER reject_library_media", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(sqlite3_close(db) == SQLITE_OK);

        // A row whose bytes vanished is only removed once its replacement lands:
        // a refused write must commit nothing, not even that cleanup.
        NSDictionary *freshAsset = [store saveLibraryImageData:distinct account:@"account" error:NULL];
        CHECK(freshAsset && mediaRow(path, @"account", digest) == 1);
        NSString *freshPath = [directory stringByAppendingPathComponent:
            [freshAsset[@"mediaReference"] stringByAppendingString:@".srimage"]];
        CHECK([NSFileManager.defaultManager removeItemAtPath:freshPath error:NULL]);
        fillBudget(directory, 268435456ULL);
        assetError = nil;
        CHECK(![store saveLibraryImageData:distinct account:@"account" error:&assetError]);
        CHECK(assetError.code == SRImageAssetErrorQuotaExceeded);
        CHECK(mediaRow(path, @"account", digest) == 1);
        clearBudget(directory);
        NSDictionary *replaced = [store saveLibraryImageData:distinct account:@"account" error:NULL];
        CHECK(replaced && ![replaced[@"mediaReference"] isEqual:freshAsset[@"mediaReference"]]);
        CHECK(mediaRow(path, @"account", digest) == 1);
        CHECK([[store.imageAssets dataForPayload:replaced scopeSHA256:accountScope error:NULL] isEqual:distinct]);

        // A failed COMMIT: the INSERT was accepted, the transaction never became
        // durable, and the bytes written by this call must not survive rollback.
        NSData *commitBytes = pngWithPixel(3);
        NSString *commitDigest = [SRImageAssetStore sha256ForData:commitBytes];
        CHECK(commitDigest.length > 0);
        usage = usageOf(store);
        NSUInteger filesBeforeCommit = [usage[@"fileCount"] unsignedIntegerValue];
        installCommitFault(path);
        NSError *commitError = nil;
        CHECK(![store saveLibraryImageData:commitBytes account:@"account" error:&commitError]);
        removeCommitFault(path);
        CHECK([commitError.domain isEqual:@"SyncRelay.Store"] && commitError.code == 1);
        CHECK(mediaRow(path, @"account", commitDigest) == 0);
        usage = usageOf(store);
        CHECK([usage[@"fileCount"] unsignedIntegerValue] == filesBeforeCommit);
        CHECK([usage[@"reservedBytes"] unsignedLongLongValue] == 0);
        // Nothing about the failed call is remembered: a clean retry stores it.
        CHECK([store saveLibraryImageData:commitBytes account:@"account" error:NULL]);
        CHECK(mediaRow(path, @"account", commitDigest) == 1);

        // With an unusable row present, the rollback restores that row and only
        // the replacement bytes are discarded.
        NSString *keptToken = mediaToken(path, @"account", commitDigest);
        CHECK(keptToken.length > 0);
        NSString *keptPath = [directory stringByAppendingPathComponent:
            [keptToken stringByAppendingString:@".srimage"]];
        CHECK([NSFileManager.defaultManager removeItemAtPath:keptPath error:NULL]);
        usage = usageOf(store);
        NSUInteger filesBeforeStaleCommit = [usage[@"fileCount"] unsignedIntegerValue];
        installCommitFault(path);
        commitError = nil;
        CHECK(![store saveLibraryImageData:commitBytes account:@"account" error:&commitError]);
        removeCommitFault(path);
        CHECK([commitError.domain isEqual:@"SyncRelay.Store"]);
        CHECK(mediaRow(path, @"account", commitDigest) == 1);
        CHECK([mediaToken(path, @"account", commitDigest) isEqual:keptToken]);
        usage = usageOf(store);
        CHECK([usage[@"fileCount"] unsignedIntegerValue] == filesBeforeStaleCommit);
        CHECK([usage[@"reservedBytes"] unsignedLongLongValue] == 0);
        // A retry replaces the unusable row, and a later identical save reuses it
        // instead of deleting the file it just returned.
        NSDictionary *retried = [store saveLibraryImageData:commitBytes account:@"account" error:NULL];
        CHECK(retried && ![retried[@"mediaReference"] isEqual:keptToken]);
        NSDictionary *reusedAgain = [store saveLibraryImageData:commitBytes account:@"account" error:NULL];
        CHECK([reusedAgain[@"mediaReference"] isEqual:retried[@"mediaReference"]]);
        NSString *reusedPath = [directory stringByAppendingPathComponent:
            [retried[@"mediaReference"] stringByAppendingString:@".srimage"]];
        CHECK([NSFileManager.defaultManager fileExistsAtPath:reusedPath]);

        store = nil;
        CHECK([NSFileManager.defaultManager removeItemAtPath:root error:NULL]);
        puts("PASS: message library entries, immutable versions, account isolation, byte reuse, rollback, media retention and image error paths");
    }
    return 0;
}
