#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <sqlite3.h>
#import "Core/SRStore.h"
#import "Core/SRConfiguration.h"
#import "Core/SRImageAssetStore.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

static NSData *png(void) {
    unsigned char pixels[24] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
        255, 255, 0, 255, 0, 255, 255, 255, 255, 0, 255, 255};
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, 2, 3, 8, 8, color, kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef output = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(output, image, NULL); CHECK(CGImageDestinationFinalize(output));
    CFRelease(output); CGImageRelease(image); CGContextRelease(context); CGColorSpaceRelease(color); return data;
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

        store = nil;
        CHECK([NSFileManager.defaultManager removeItemAtPath:root error:NULL]);
        puts("PASS: message library entries, immutable versions, account isolation, byte reuse, rollback and media retention");
    }
    return 0;
}
