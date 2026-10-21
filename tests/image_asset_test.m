#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import "Core/SRImageAssetStore.h"
#import "Core/SRStore.h"
#import "Core/SRSourceCapture.h"
#import "Core/SRConfiguration.h"
#include <assert.h>
#include <fcntl.h>
#include <unistd.h>
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
static NSMutableDictionary *source(void) {
    return [@{@"account": @"account", @"group": @"mother@chatroom", @"sender": @"sender", @"messageID": @"svr:11",
        @"type": @"image", @"generatedByRelay": @NO} mutableCopy];
}
static NSMutableDictionary *configuration(void) {
    NSMutableDictionary *draft = [SRConfiguration emptyDraft];
    draft[@"sourceGroup"] = @{@"id": @"mother@chatroom", @"name": @"Mother"};
    draft[@"senders"] = @[@{@"id": @"sender", @"name": @"Sender"}]; draft[@"types"] = @[@"image"];
    draft[@"rules"] = @[@{@"id": @"rule", @"name": @"First", @"targets": @[@{@"id": @"target@chatroom", @"name": @"Target"}]}];
    return draft;
}
int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *directory = [root stringByAppendingPathComponent:@"images"];
        SRImageAssetStore *assets = [[SRImageAssetStore alloc] initWithDirectory:directory];
        NSData *data = png(); NSMutableDictionary *message = source(); NSError *error = nil;
        NSDictionary *payload = [assets saveData:data source:message error:&error]; CHECK(payload && !error);
        CHECK([payload[@"pixelWidth"] isEqual:@2] && [payload[@"pixelHeight"] isEqual:@3]);
        CHECK([SRImageAssetStore validPayload:payload] && [[assets dataForPayload:payload source:message error:NULL] isEqual:data]);
        for (NSString *key in @[@"account", @"group", @"sender", @"messageID"]) {
            NSMutableDictionary *wrong = [message mutableCopy]; wrong[key] = @"different";
            CHECK(![assets dataForPayload:payload source:wrong error:NULL]);
        }
        for (NSString *key in @[@"sha256", @"byteCount", @"pixelWidth", @"format", @"mediaReference", @"scopeSHA256"]) {
            NSMutableDictionary *wrong = [payload mutableCopy];
            wrong[key] = [payload[key] isKindOfClass:NSNumber.class] ? @999 : @"../../outside";
            CHECK(![assets dataForPayload:wrong source:message error:NULL]);
        }
        CHECK(![assets saveData:[@"not an image" dataUsingEncoding:NSUTF8StringEncoding] source:message error:NULL]);
        CHECK(![assets saveData:[NSMutableData dataWithLength:20 * 1024 * 1024 + 1] source:message error:NULL]);
        CHECK(![assets saveData:data source:@{} error:NULL]);
        CHECK(![assets saveData:[data subdataWithRange:NSMakeRange(0, data.length / 2)] source:message error:NULL]);
        NSMutableDictionary *booleanWidth = [payload mutableCopy]; booleanWidth[@"pixelWidth"] = @YES;
        CHECK(![SRImageAssetStore validPayload:booleanWidth]);
        NSString *file = [directory stringByAppendingPathComponent:[payload[@"mediaReference"] stringByAppendingString:@".srimage"]];
        NSMutableData *corrupt = [data mutableCopy]; ((unsigned char *)corrupt.mutableBytes)[data.length / 2] ^= 1;
        CHECK([corrupt writeToFile:file atomically:YES]); CHECK(![assets dataForPayload:payload source:message error:NULL]);
        CHECK([data writeToFile:file atomically:YES]);
        NSString *outside = [root stringByAppendingPathComponent:@"outside.png"]; CHECK([data writeToFile:outside atomically:YES]);
        CHECK([NSFileManager.defaultManager removeItemAtPath:file error:NULL]);
        CHECK([NSFileManager.defaultManager createSymbolicLinkAtPath:file withDestinationPath:outside error:NULL]);
        CHECK(![assets dataForPayload:payload source:message error:NULL]);
        [assets discardPayload:payload]; CHECK([NSFileManager.defaultManager fileExistsAtPath:outside]);
        // A sparse unrelated file exercises the quota without allocating 256 MiB.
        NSString *full = [directory stringByAppendingPathComponent:@"quota"];
        int fd = open(full.fileSystemRepresentation, O_CREAT | O_WRONLY, 0600); CHECK(fd >= 0);
        CHECK(!ftruncate(fd, 256 * 1024 * 1024)); close(fd);
        CHECK(![assets saveData:data source:message error:NULL]); CHECK([NSFileManager.defaultManager removeItemAtPath:full error:NULL]);
        NSString *link = [root stringByAppendingPathComponent:@"linked-images"];
        CHECK([NSFileManager.defaultManager createSymbolicLinkAtPath:link withDestinationPath:directory error:NULL]);
        CHECK(![[[SRImageAssetStore alloc] initWithDirectory:link] saveData:data source:message error:NULL]);
        NSString *path = [root stringByAppendingPathComponent:@"store.sqlite3"];
        SRStore *store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        SRSourceCapture *capture = [[SRSourceCapture alloc] initWithStore:store];
        payload = [store.imageAssets saveData:data source:message error:NULL]; message[@"payload"] = payload;
        CHECK(![store claimImageExperiment:message configuration:configuration() account:@"other" target:@"target@chatroom" error:NULL]);
        CHECK(![store claimImageExperiment:message configuration:configuration() account:@"account" target:@"mother@chatroom" error:NULL]);
        CHECK(![store claimImageExperiment:message configuration:configuration() account:@"account" target:@"unallocated@chatroom" error:NULL]);
        CHECK([store claimImageExperiment:message configuration:configuration() account:@"account" target:@"target@chatroom" error:NULL]);
        CHECK(![store claimImageExperiment:message configuration:configuration() account:@"account" target:@"target@chatroom" error:NULL]);
        CHECK([[store imageExperimentSummaryForAccount:@"account" error:NULL][@"claimed"] boolValue]);
        CHECK(![[store imageExperimentSummaryForAccount:@"other" error:NULL][@"claimed"] boolValue]);
        NSMutableDictionary *asText = [message mutableCopy];
        asText[@"type"] = @"text"; asText[@"payload"] = @{@"text": @"synthetic"};
        NSMutableDictionary *both = configuration(); both[@"types"] = @[@"text", @"image"];
        CHECK(![store claimTextExperiment:asText configuration:both account:@"account" target:@"target@chatroom" error:NULL]);
        CHECK([capture armForAccount:@"account" configuration:configuration() error:NULL] && [capture offerEnvelope:message]);
        [capture cancel]; CHECK(![store.imageAssets dataForPayload:payload source:message error:NULL]);
        payload = [store.imageAssets saveData:data source:message error:NULL]; message[@"payload"] = payload;
        CHECK([capture armForAccount:@"account" configuration:configuration() error:NULL] && [capture offerEnvelope:message]);
        NSString *plan = [capture confirmForCurrentAccount:@"account" error:NULL]; CHECK(plan);
        CHECK([store.imageAssets dataForPayload:payload source:message error:NULL]);
        capture = nil; store = nil; store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        NSDictionary *restored = [store plan:plan account:@"account" error:NULL][@"snapshot"];
        CHECK(![store claimImageExperiment:message configuration:configuration() account:@"account" target:@"target@chatroom" error:NULL]);
        CHECK([[store imageExperimentSummaryForAccount:@"account" error:NULL][@"claimed"] boolValue]);
        CHECK([[store.imageAssets dataForPayload:restored[@"payload"] source:restored error:NULL] isEqual:data]);
        CHECK(![store plan:plan account:@"other" error:NULL]);
        NSMutableDictionary *orphanSource = source(); orphanSource[@"messageID"] = @"svr:99";
        NSDictionary *orphan = [store.imageAssets saveData:data source:orphanSource error:NULL]; CHECK(orphan);
        store = nil; store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        CHECK(![store.imageAssets dataForPayload:orphan source:orphanSource error:NULL]);
        CHECK([store.imageAssets dataForPayload:restored[@"payload"] source:restored error:NULL]);
        NSDictionary *recoverable = [store.imageAssets saveData:data source:orphanSource error:NULL]; CHECK(recoverable);
        NSMutableDictionary *damaged = [orphanSource mutableCopy], *damagedPayload = [recoverable mutableCopy];
        damagedPayload[@"pixelWidth"] = NSNull.null; damaged[@"payload"] = damagedPayload;
        CHECK([store createPlanForAccount:@"account" sourceGroup:@"mother@chatroom" senders:@[@"sender"]
            types:@[@"image"] sourceSnapshot:damaged error:NULL]);
        store = nil; store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        CHECK([store.imageAssets dataForPayload:recoverable source:orphanSource error:NULL]);
        message[@"messageID"] = @"svr:12";
        CHECK(![store createPlanFromConfiguration:configuration() envelope:message account:@"account" error:NULL]);
        store = nil; CHECK([NSFileManager.defaultManager removeItemAtPath:root error:NULL]);
        puts("PASS: scoped immutable image snapshots, raster validation, integrity, quota, path guards, cancellation and plan restart retention");
    }
    return 0;
}
