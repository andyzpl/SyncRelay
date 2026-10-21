#import "SRImageAssetStore.h"
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <math.h>

static const NSUInteger SRImageByteLimit = 20 * 1024 * 1024;
static const unsigned long long SRImageDiskLimit = 256ULL * 1024 * 1024;
static NSString *SRImageHash(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [text appendFormat:@"%02x", digest[i]];
    return text;
}
static BOOL SRHex(NSString *text) {
    return [text isKindOfClass:NSString.class] && text.length == 64 &&
        [text rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}
static NSString *SRImageScope(NSDictionary *source) {
    if (![source isKindOfClass:NSDictionary.class]) return nil;
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *key in @[@"account", @"group", @"sender", @"messageID"]) {
        id value = source[key]; if (![value isKindOfClass:NSString.class] || ![value length]) return nil;
        [fields addObject:value];
    }
    return SRImageHash([NSJSONSerialization dataWithJSONObject:fields options:0 error:NULL]);
}
static BOOL SRImageFail(NSError **error, NSInteger code) {
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.ImageAsset" code:code
        userInfo:@{NSLocalizedDescriptionKey: @"Image snapshot is unavailable, invalid, oversized or outside its source scope"}];
    return NO;
}
static BOOL SRImageNumber(id number, NSUInteger maximum) {
    if (![number isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) return NO;
    double value = [number doubleValue]; return isfinite(value) && value >= 1 && value <= maximum && floor(value) == value;
}
static NSDictionary *SRRasterInfo(NSData *data) {
    if (![data isKindOfClass:NSData.class] || !data.length || data.length > SRImageByteLimit) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data,
        (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache: @NO});
    if (!source) return nil;
    NSDictionary *result = nil;
    @try {
        NSString *type = (__bridge NSString *)CGImageSourceGetType(source);
        if (CGImageSourceGetCount(source) != 1 || CGImageSourceGetStatus(source) != kCGImageStatusComplete ||
            CGImageSourceGetStatusAtIndex(source, 0) != kCGImageStatusComplete ||
            ![@[@"public.png", @"public.jpeg"] containsObject:type ?: @""]) return nil;
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        NSNumber *width = properties[(id)kCGImagePropertyPixelWidth], *height = properties[(id)kCGImagePropertyPixelHeight];
        if (!SRImageNumber(width, 12000) || !SRImageNumber(height, 12000) ||
            width.unsignedLongLongValue * height.unsignedLongLongValue > 32000000ULL) return nil;
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0,
            (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCacheImmediately: @YES});
        if (!image) return nil;
        BOOL valid = CGImageGetWidth(image) == width.unsignedIntegerValue && CGImageGetHeight(image) == height.unsignedIntegerValue;
        CGImageRelease(image);
        if (valid) result = @{@"pixelWidth": width, @"pixelHeight": height, @"format": [type isEqual:@"public.png"] ? @"png" : @"jpeg"};
    } @finally { CFRelease(source); }
    return result;
}
@interface SRImageAssetStore ()
@property(nonatomic, copy) NSString *directory;
@end
@implementation SRImageAssetStore
- (instancetype)initWithDirectory:(NSString *)directory {
    self = [super init]; if (self) _directory = [directory copy]; return self;
}
+ (BOOL)validPayload:(id)payload {
    if (![payload isKindOfClass:NSDictionary.class]) return NO;
    NSString *token = payload[@"mediaReference"];
    NSUUID *uuid = [token isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:token] : nil;
    return uuid && [uuid.UUIDString isEqual:token] && SRImageNumber(payload[@"snapshotSchema"], 1) &&
        SRHex(payload[@"sha256"]) && SRHex(payload[@"scopeSHA256"]) &&
        SRImageNumber(payload[@"byteCount"], SRImageByteLimit) && SRImageNumber(payload[@"pixelWidth"], 12000) &&
        SRImageNumber(payload[@"pixelHeight"], 12000) &&
        [payload[@"pixelWidth"] unsignedLongLongValue] * [payload[@"pixelHeight"] unsignedLongLongValue] <= 32000000ULL &&
        [@[@"png", @"jpeg"] containsObject:payload[@"format"] ?: @""];
}
- (int)openDirectoryCreating:(BOOL)create {
    if (create && ![NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:NULL]) return -1;
    return open(self.directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
}
- (NSDictionary *)saveData:(NSData *)data source:(NSDictionary *)source error:(NSError **)error {
    @synchronized(self) {
        NSString *scope = SRImageScope(source); NSDictionary *info = scope ? SRRasterInfo(data) : nil;
        if (!info) { SRImageFail(error, 1); return nil; }
        int directory = [self openDirectoryCreating:YES];
        if (directory < 0) { SRImageFail(error, 2); return nil; }
        // Bound accumulation; never evict an asset referenced by a confirmed plan.
        unsigned long long used = 0;
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.directory error:NULL]) {
            struct stat status;
            if (!fstatat(directory, name.fileSystemRepresentation, &status, AT_SYMLINK_NOFOLLOW) && S_ISREG(status.st_mode))
                used += (unsigned long long)status.st_size;
            if (used >= SRImageDiskLimit) break;
        }
        if (used > SRImageDiskLimit || data.length > SRImageDiskLimit - used) { close(directory); SRImageFail(error, 3); return nil; }
        NSString *token = NSUUID.UUID.UUIDString, *name = [token stringByAppendingString:@".srimage"];
        int file = openat(directory, name.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        BOOL valid = file >= 0; NSUInteger offset = 0;
        while (valid && offset < data.length) {
            ssize_t count = write(file, (const unsigned char *)data.bytes + offset, data.length - offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) valid = NO; else offset += (NSUInteger)count;
        }
        if (valid) valid = fsync(file) == 0;
        if (file >= 0) close(file);
        if (!valid) unlinkat(directory, name.fileSystemRepresentation, 0);
        close(directory);
        if (!valid) { SRImageFail(error, 4); return nil; }
        NSMutableDictionary *payload = [info mutableCopy];
        [payload addEntriesFromDictionary:@{@"mediaReference": token, @"snapshotSchema": @1,
            @"scopeSHA256": scope, @"sha256": SRImageHash(data), @"byteCount": @(data.length)}];
        return [payload copy];
    }
}
- (NSData *)dataForPayload:(NSDictionary *)payload source:(NSDictionary *)source error:(NSError **)error {
    @synchronized(self) {
        if (![SRImageAssetStore validPayload:payload] || ![SRImageScope(source) isEqual:payload[@"scopeSHA256"]]) {
            SRImageFail(error, 5); return nil;
        }
        int directory = [self openDirectoryCreating:NO];
        NSString *name = [payload[@"mediaReference"] stringByAppendingString:@".srimage"];
        int file = directory >= 0 ? openat(directory, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW) : -1;
        if (directory >= 0) close(directory);
        struct stat status;
        if (file < 0 || fstat(file, &status) || !S_ISREG(status.st_mode) || status.st_size != [payload[@"byteCount"] longLongValue]) {
            if (file >= 0) close(file); SRImageFail(error, 6); return nil;
        }
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)status.st_size]; NSUInteger offset = 0;
        while (offset < data.length) {
            ssize_t count = read(file, (unsigned char *)data.mutableBytes + offset, data.length - offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break; offset += (NSUInteger)count;
        }
        close(file);
        NSDictionary *info = offset == data.length && [SRImageHash(data) isEqual:payload[@"sha256"]] ? SRRasterInfo(data) : nil;
        if (!info || ![info[@"pixelWidth"] isEqual:payload[@"pixelWidth"]] || ![info[@"pixelHeight"] isEqual:payload[@"pixelHeight"]] ||
            ![info[@"format"] isEqual:payload[@"format"]]) { SRImageFail(error, 7); return nil; }
        return [data copy];
    }
}
- (void)discardPayload:(NSDictionary *)payload {
    @synchronized(self) {
        if (![SRImageAssetStore validPayload:payload]) return;
        int directory = [self openDirectoryCreating:NO];
        if (directory >= 0) {
            unlinkat(directory, [[payload[@"mediaReference"] stringByAppendingString:@".srimage"] fileSystemRepresentation], 0);
            close(directory);
        }
    }
}
- (void)pruneUnreferenced:(NSSet<NSString *> *)references {
    @synchronized(self) {
        int directory = [self openDirectoryCreating:NO]; if (directory < 0) return;
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.directory error:NULL]) {
            if (![name.pathExtension isEqual:@"srimage"]) continue;
            NSString *token = name.stringByDeletingPathExtension;
            NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:token];
            if ([uuid.UUIDString isEqual:token] && ![references containsObject:token]) unlinkat(directory, name.fileSystemRepresentation, 0);
        }
        close(directory);
    }
}
@end
