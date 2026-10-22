#import "SRWeChatFileSource.h"
#import "SRRuntime.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>

@implementation SRWeChatFileSource
+ (NSDictionary *)snapshotForWrap:(id)wrap expectedSize:(unsigned long long)size home:(NSString *)home allowed:(BOOL (^)(void))allowed state:(NSString **)state {
    *state = @"file_size_rejected";
    if (!NSThread.isMainThread || !size || size > 8ULL * 1024 * 1024) return nil;
    *state = @"file_context_changed"; if (!allowed || !allowed()) return nil;
    if (![SRReadDeclaredUnsignedInteger(wrap, @"m_uiMessageType") isEqual:@49]) { *state = @"file_identity_rejected"; return nil; }
    SRStringReadState getter;
    NSString *path = SRReadDeclaredString(wrap, @"GetAppAttachmentPath", &getter);
    *state = @"file_context_changed"; if (!allowed()) return nil;
    *state = getter == SRStringReadMissing || getter == SRStringReadIncompatible ? @"file_getter_unavailable" : @"file_path_unavailable";
    if (!path.length || path.length > 4096 || [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    NSString *root = [home stringByResolvingSymlinksInPath];
    // Normalize only the known container alias (/var versus /private/var), not host components.
    if ([path hasPrefix:[home stringByAppendingString:@"/"]]) path = [root stringByAppendingString:[path substringFromIndex:home.length]];
    *state = @"file_path_rejected";
    if (![path hasPrefix:[root stringByAppendingString:@"/"]]) return nil;
    NSArray<NSString *> *parts = [[path substringFromIndex:root.length + 1] componentsSeparatedByString:@"/"];
    for (NSString *part in parts) if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return nil;
    BOOL pathAllowed = parts.count >= 2 && ([@[@"Documents", @"tmp"] containsObject:parts[0]] ||
        (parts.count >= 3 && [parts[0] isEqual:@"Library"] && [parts[1] isEqual:@"Caches"]));
    if (!pathAllowed) return nil;
    int directory = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return nil;
    for (NSUInteger index = 0; index + 1 < parts.count; index++) {
        int next = openat(directory, parts[index].fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(directory); directory = next;
        if (directory < 0) return nil;
    }
    int file = openat(directory, parts.lastObject.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    close(directory); *state = @"file_not_ready";
    if (file < 0) return nil;
    NSDictionary *result = nil;
    @try {
        struct stat before, after;
        if (fstat(file, &before) || !S_ISREG(before.st_mode) || before.st_nlink != 1 || before.st_size < 0 ||
            (unsigned long long)before.st_size != size) { *state = @"file_size_or_type_rejected"; return nil; }
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
        NSUInteger offset = 0;
        while (offset < data.length) {
            if (!allowed()) { *state = @"file_context_changed"; return nil; }
            ssize_t count = read(file, (unsigned char *)data.mutableBytes + offset, MIN((NSUInteger)65536, data.length - offset));
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break;
            offset += (NSUInteger)count;
        }
        unsigned char extra;
        ssize_t end = read(file, &extra, 1);
        *state = @"file_changed";
        if (offset != data.length || end != 0 || fstat(file, &after) || before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
            before.st_size != after.st_size || before.st_nlink != after.st_nlink ||
            before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
            before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec) return nil;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
        NSMutableString *hash = [NSMutableString string];
        for (NSUInteger i = 0; i < sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]];
        result = @{@"data": [data copy], @"sha256": [hash copy], @"byteCount": @(size)};
        if (!allowed()) { *state = @"file_context_changed"; return nil; }
        *state = @"file_snapshot_ready";
    } @finally { close(file); }
    return result;
}
@end
