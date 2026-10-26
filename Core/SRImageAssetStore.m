#import "SRImageAssetStore.h"
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <math.h>

NSString *const SRImageAssetShortfallBytesKey = @"SRImageAssetShortfallBytes";
NSString *const SRImageAssetUsedBytesKey = @"SRImageAssetUsedBytes";
NSString *const SRImageAssetLimitBytesKey = @"SRImageAssetLimitBytes";

static NSString *const SRImageSnapshotExtension = @"srimage";
static NSString *const SRImageDerivedExtension = @"srderived";
static NSString *const SRImageTemporaryExtension = @"srtmp";

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
static BOOL SRImageNumber(id number, NSUInteger maximum) {
    if (![number isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) return NO;
    double value = [number doubleValue]; return isfinite(value) && value >= 1 && value <= maximum && floor(value) == value;
}
static NSDictionary *SRRasterInfo(NSData *data) {
    if (![data isKindOfClass:NSData.class] || !data.length ||
        data.length > (NSUInteger)SR_MEDIA_SINGLE_FILE_LIMIT_BYTES) return nil;
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
static NSError *SRImageAssetError(SRImageAssetErrorCode code, NSDictionary *extra) {
    NSString *message;
    switch (code) {
        case SRImageAssetErrorDirectoryUnavailable:
            message = @"Image storage directory is unavailable"; break;
        case SRImageAssetErrorQuotaExceeded:
            message = @"SyncRelay media storage is full"; break;
        case SRImageAssetErrorWriteFailed:
            message = @"Image snapshot could not be written"; break;
        case SRImageAssetErrorScopeMismatch:
            message = @"Image payload belongs to another source scope"; break;
        case SRImageAssetErrorUnreadable:
            message = @"Image snapshot is missing or unreadable"; break;
        case SRImageAssetErrorIntegrityFailed:
            message = @"Image snapshot failed its integrity check"; break;
        case SRImageAssetErrorSingleFileExceeded:
            message = @"Image snapshot exceeds the single-file limit"; break;
        case SRImageAssetErrorDeviceFull:
            message = @"Device storage is full"; break;
        case SRImageAssetErrorUsageUnavailable:
            message = @"Media usage statistics are unavailable"; break;
        case SRImageAssetErrorReservationInvalid:
            message = @"Image reservation is invalid"; break;
        case SRImageAssetErrorInvalidSnapshot:
        default:
            message = @"Image snapshot is unavailable or not a supported raster"; break;
    }
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
    if (extra) [info addEntriesFromDictionary:extra];
    return [NSError errorWithDomain:@"SyncRelay.ImageAsset" code:code userInfo:info];
}
static NSString *SRMediaLevelName(SRMediaLevel level) {
    switch (level) {
        case SRMediaLevelWarning: return @"warning";
        case SRMediaLevelFull: return @"full";
        case SRMediaLevelNormal: return @"normal";
    }
    return @"normal";
}

@interface SRMediaDirectoryState : NSObject
@property(nonatomic, readonly) SRMediaLedger *ledger;
@property(nonatomic, strong, readonly) NSMutableSet<NSString *> *liveTemporaryNames;
@property(nonatomic, strong, readonly) NSMutableDictionary<NSNumber *, NSString *> *reservationTokens;
@end

@implementation SRMediaDirectoryState
- (instancetype)init {
    self = [super init];
    if (self) {
        _ledger = SRMediaLedgerCreate(SRMediaDefaultPolicy());
        if (!_ledger) return nil;
        _liveTemporaryNames = [NSMutableSet set];
        _reservationTokens = [NSMutableDictionary dictionary];
    }
    return self;
}
- (void)dealloc { SRMediaLedgerDestroy(_ledger); }
@end

/* The shared state is also the recursive monitor for scan -> reserve -> write
 * -> commit. Sharing only the C ledger lets a second instance publish a stale
 * scan or prune a token whose reservation it cannot see. */
static SRMediaDirectoryState *SRMediaDirectoryStateForDirectory(NSString *directory) {
    static NSMutableDictionary<NSString *, SRMediaDirectoryState *> *registry;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ registry = [NSMutableDictionary dictionary]; lock = [NSLock new]; });
    [lock lock];
    @try {
        SRMediaDirectoryState *stored = registry[directory];
        if (stored) return stored;
        SRMediaDirectoryState *state = [SRMediaDirectoryState new];
        if (state) registry[directory] = state;
        return state;
    } @finally { [lock unlock]; }
}

typedef struct {
    uint64_t ownedBytes;
    uint64_t reclaimableBytes;
    uint64_t fileCount;
} SRMediaScanResult;

@interface SRImageAssetStore () {
    NSMutableSet<NSString *> *_liveTemporaryNames;
    NSMutableDictionary<NSNumber *, NSString *> *_reservationTokens;
}
@property(nonatomic, copy, readwrite) NSString *directory;
@property(nonatomic, strong) SRMediaDirectoryState *mediaState;
- (SRMediaLedger *)ledger;
- (BOOL)scanMediaInto:(SRMediaScanResult *)result
      protectedTokens:(nullable NSSet<NSString *> *)tokens error:(NSError **)error;
- (BOOL)refreshLedger:(SRMediaLedger *)ledger
      protectedTokens:(nullable NSSet<NSString *> *)tokens error:(NSError **)error;
- (NSInteger)writeData:(NSData *)data temporary:(NSString *)temporary final:(NSString *)final;
@end

@implementation SRImageAssetStore
- (instancetype)initWithDirectory:(NSString *)directory {
    self = [super init];
    if (self) {
        _directory = [directory copy];
        _mediaState = SRMediaDirectoryStateForDirectory(_directory);
        if (!_mediaState) return nil;
        _liveTemporaryNames = _mediaState.liveTemporaryNames;
        _reservationTokens = _mediaState.reservationTokens;
    }
    return self;
}
- (SRMediaLedger *)ledger { return self.mediaState.ledger; }

+ (NSString *)sha256ForData:(NSData *)data {
    if (![data isKindOfClass:NSData.class] || !data.length) return nil;
    return SRImageHash(data);
}
+ (NSString *)libraryScopeForAccount:(NSString *)account {
    if (![account isKindOfClass:NSString.class] || !account.length) return nil;
    NSData *fields = [NSJSONSerialization dataWithJSONObject:@[@"message_library", account] options:0 error:NULL];
    return fields ? SRImageHash(fields) : nil;
}
+ (BOOL)validPayload:(id)payload {
    if (![payload isKindOfClass:NSDictionary.class]) return NO;
    NSString *token = payload[@"mediaReference"];
    NSUUID *uuid = [token isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:token] : nil;
    return uuid && [uuid.UUIDString isEqual:token] && SRImageNumber(payload[@"snapshotSchema"], 1) &&
        SRHex(payload[@"sha256"]) && SRHex(payload[@"scopeSHA256"]) &&
        SRImageNumber(payload[@"byteCount"], (NSUInteger)SR_MEDIA_SINGLE_FILE_LIMIT_BYTES) &&
        SRImageNumber(payload[@"pixelWidth"], 12000) && SRImageNumber(payload[@"pixelHeight"], 12000) &&
        [payload[@"pixelWidth"] unsignedLongLongValue] * [payload[@"pixelHeight"] unsignedLongLongValue] <= 32000000ULL &&
        [@[@"png", @"jpeg"] containsObject:payload[@"format"] ?: @""];
}
- (int)openDirectoryCreating:(BOOL)create {
    if (create && ![NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:NULL]) return -1;
    return open(self.directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
}

/* Counts each physical file once (device+inode, so hard links do not double
 * count). Temporary files of the directory's live writes are already covered by
 * their reservation and are skipped to avoid counting the same bytes twice. */
- (BOOL)scanMediaInto:(SRMediaScanResult *)result
      protectedTokens:(NSSet<NSString *> *)tokens error:(NSError **)error {
    SRMediaScanResult scan = {0, 0, 0};
    int directory = [self openDirectoryCreating:NO];
    if (directory < 0) {
        if (errno == ENOENT) { if (result) *result = scan; return YES; }
        if (error) *error = SRImageAssetError(SRImageAssetErrorUsageUnavailable, nil);
        return NO;
    }
    DIR *stream = fdopendir(directory);
    if (!stream) {
        close(directory);
        if (error) *error = SRImageAssetError(SRImageAssetErrorUsageUnavailable, nil);
        return NO;
    }
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSSet *live = [NSSet setWithArray:_reservationTokens.allValues];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL ok = YES;
    struct dirent *entry;
    for (;;) {
        errno = 0;
        entry = readdir(stream);
        if (!entry) { if (errno != 0) ok = NO; break; }
        NSString *name = @(entry->d_name);
        NSString *extension = name.pathExtension;
        if (![extension isEqual:SRImageSnapshotExtension] && ![extension isEqual:SRImageDerivedExtension] &&
            ![extension isEqual:SRImageTemporaryExtension]) continue;
        struct stat status;
        if (fstatat(dirfd(stream), entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) { ok = NO; break; }
        if (!S_ISREG(status.st_mode)) continue;
        NSString *identity = [NSString stringWithFormat:@"%llu/%llu",
            (unsigned long long)status.st_dev, (unsigned long long)status.st_ino];
        if ([seen containsObject:identity]) continue;
        [seen addObject:identity];
        uint64_t size = (uint64_t)status.st_size;
        if ([extension isEqual:SRImageTemporaryExtension]) {
            if ([_liveTemporaryNames containsObject:name]) continue;
            scan.ownedBytes += size; scan.fileCount += 1;
            if (now - (NSTimeInterval)status.st_mtime >= SR_MEDIA_TEMPORARY_GRACE_SECONDS)
                scan.reclaimableBytes += size;
            continue;
        }
        scan.ownedBytes += size; scan.fileCount += 1;
        NSString *token = name.stringByDeletingPathExtension;
        if (tokens && ![tokens containsObject:token] && ![live containsObject:token])
            scan.reclaimableBytes += size;
    }
    closedir(stream);
    if (!ok) {
        if (error) *error = SRImageAssetError(SRImageAssetErrorUsageUnavailable, nil);
        return NO;
    }
    if (result) *result = scan;
    return YES;
}

- (BOOL)refreshLedger:(SRMediaLedger *)ledger
      protectedTokens:(NSSet<NSString *> *)tokens error:(NSError **)error {
    if (!ledger) {
        if (error) *error = SRImageAssetError(SRImageAssetErrorUsageUnavailable, nil);
        return NO;
    }
    SRMediaScanResult scan;
    /* A failed scan must never be recorded as zero usage: the ledger stays
     * invalid and every reservation is refused until a scan succeeds. */
    if (![self scanMediaInto:&scan protectedTokens:tokens error:error]) {
        SRMediaLedgerRecordScanFailure(ledger);
        return NO;
    }
    SRMediaLedgerRecordScan(ledger, scan.ownedBytes, scan.reclaimableBytes, scan.fileCount);
    return YES;
}

- (BOOL)mediaSnapshot:(SRMediaSnapshot *)snapshot
      protectingTokens:(NSSet<NSString *> *)tokens error:(NSError **)error {
    @synchronized (self.mediaState) {
        SRMediaLedger *ledger = [self ledger];
        if (![self refreshLedger:ledger protectedTokens:tokens error:error]) return NO;
        *snapshot = SRMediaLedgerSnapshot(ledger);
        return YES;
    }
}

- (NSArray *)mediaObjectsProtectingTokens:(NSSet<NSString *> *)tokens limit:(NSUInteger)limit
                                    error:(NSError **)error {
    @synchronized (self.mediaState) {
        int directory = [self openDirectoryCreating:NO];
        if (directory < 0) {
            if (errno == ENOENT) return @[];
            if (error) *error = SRImageAssetError(SRImageAssetErrorUsageUnavailable, nil);
            return nil;
        }
        DIR *stream = fdopendir(directory);
        if (!stream) {
            close(directory);
            if (error) *error = SRImageAssetError(SRImageAssetErrorUsageUnavailable, nil);
            return nil;
        }
        NSUInteger cap = MIN(MAX(limit, (NSUInteger)1), (NSUInteger)500);
        NSMutableSet *seen = [NSMutableSet set];
        NSMutableArray *rows = [NSMutableArray array];
        NSSet *live = [NSSet setWithArray:_reservationTokens.allValues];
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        BOOL ok = YES;
        struct dirent *entry;
        for (;;) {
            errno = 0;
            entry = readdir(stream);
            if (!entry) { if (errno != 0) ok = NO; break; }
            NSString *name = @(entry->d_name);
            NSString *extension = name.pathExtension;
            if (![extension isEqual:SRImageSnapshotExtension] && ![extension isEqual:SRImageDerivedExtension] &&
                ![extension isEqual:SRImageTemporaryExtension]) continue;
            struct stat status;
            if (fstatat(dirfd(stream), entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) { ok = NO; break; }
            if (!S_ISREG(status.st_mode)) continue;
            NSString *identity = [NSString stringWithFormat:@"%llu/%llu",
                (unsigned long long)status.st_dev, (unsigned long long)status.st_ino];
            if ([seen containsObject:identity]) continue;
            [seen addObject:identity];
            BOOL temporary = [extension isEqual:SRImageTemporaryExtension];
            NSString *kind = temporary ? @"temporary" : ([extension isEqual:SRImageDerivedExtension] ? @"derived" : @"snapshot");
            NSString *token = temporary ? nil : name.stringByDeletingPathExtension;
            // A temporary file this process is still writing is in use, not an
            // interrupted leftover; the age grace applies to the rest.
            BOOL aged = now - (NSTimeInterval)status.st_mtime >= SR_MEDIA_TEMPORARY_GRACE_SECONDS;
            BOOL reclaimable = temporary ? (aged && ![_liveTemporaryNames containsObject:name])
                : (tokens != nil && ![tokens containsObject:token] && ![live containsObject:token]);
            NSMutableDictionary *row = [@{@"kind": kind, @"bytes": @((unsigned long long)status.st_size),
                @"modifiedAt": @((NSTimeInterval)status.st_mtime),
                @"referenced": @(!temporary && tokens != nil && [tokens containsObject:token]),
                @"reclaimable": @(reclaimable),
                @"inUse": @(temporary ? [_liveTemporaryNames containsObject:name] : (token && [live containsObject:token]))} mutableCopy];
            if (token) row[@"token"] = token;
            [rows addObject:row];
        }
        closedir(stream);
        if (!ok) {
            if (error) *error = SRImageAssetError(SRImageAssetErrorUsageUnavailable, nil);
            return nil;
        }
        [rows sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [right[@"modifiedAt"] compare:left[@"modifiedAt"]];
        }];
        return rows.count > cap ? [rows subarrayWithRange:NSMakeRange(0, cap)] : [rows copy];
    }
}

- (NSDictionary *)usageSnapshotProtectingTokens:(NSSet<NSString *> *)tokens error:(NSError **)error {
    SRMediaSnapshot snapshot;
    if (![self mediaSnapshot:&snapshot protectingTokens:tokens error:error]) return nil;
    SRMediaPolicy policy = SRMediaDefaultPolicy();
    return @{@"usedBytes": @(SRMediaSnapshotUsedBytes(snapshot)),
        @"committedBytes": @(snapshot.committed_bytes),
        @"reservedBytes": @(snapshot.reserved_bytes),
        @"limitBytes": @(snapshot.limit_bytes),
        @"remainingBytes": @(SRMediaSnapshotRemainingBytes(snapshot)),
        @"reclaimableBytes": @(snapshot.reclaimable_bytes),
        @"reclaimableComplete": @(tokens != nil),
        @"singleFileLimitBytes": @(SR_MEDIA_SINGLE_FILE_LIMIT_BYTES),
        @"fileCount": @(snapshot.file_count),
        @"scanValid": @(snapshot.scan_valid),
        @"level": SRMediaLevelName(SRMediaSnapshotLevel(snapshot, policy))};
}

- (NSNumber *)reserveBytes:(uint64_t)bytes token:(NSString *)token
                 reuseOnly:(BOOL)reuse error:(NSError **)error {
    @synchronized (self.mediaState) {
        SRMediaLedger *ledger = [self ledger];
        if (!ledger) {
            if (error) *error = SRImageAssetError(SRImageAssetErrorUsageUnavailable, nil);
            return nil;
        }
        /* An exact reuse adds no byte, so it needs no scan and is allowed at
         * full quota; every byte-consuming reservation starts from real usage. */
        if (!reuse && ![self refreshLedger:ledger protectedTokens:nil error:error]) return nil;
        SRMediaReservation reservation = {0, 0, NO};
        uint64_t shortfall = 0;
        SRMediaStatus status = SRMediaLedgerReserve(ledger, bytes, reuse ? true : false,
            &reservation, &shortfall);
        if (status == SRMediaStatusSingleFileExceeded) {
            if (error) *error = SRImageAssetError(SRImageAssetErrorSingleFileExceeded, @{
                @"requestedBytes": @(bytes), SRImageAssetLimitBytesKey: @(SR_MEDIA_SINGLE_FILE_LIMIT_BYTES)});
            return nil;
        }
        if (status == SRMediaStatusScanUnavailable) {
            if (error) *error = SRImageAssetError(SRImageAssetErrorUsageUnavailable, nil);
            return nil;
        }
        if (status == SRMediaStatusQuotaExceeded) {
            SRMediaSnapshot snapshot = SRMediaLedgerSnapshot(ledger);
            if (error) *error = SRImageAssetError(SRImageAssetErrorQuotaExceeded, @{
                SRImageAssetShortfallBytesKey: @(shortfall),
                SRImageAssetUsedBytesKey: @(SRMediaSnapshotUsedBytes(snapshot)),
                SRImageAssetLimitBytesKey: @(snapshot.limit_bytes),
                @"requestedBytes": @(bytes)});
            return nil;
        }
        if (status != SRMediaStatusOK) {
            if (error) *error = SRImageAssetError(SRImageAssetErrorReservationInvalid, nil);
            return nil;
        }
        if ([token isKindOfClass:NSString.class] && token.length) _reservationTokens[@(reservation.id)] = token;
        return @(reservation.id);
    }
}

- (BOOL)commitReservation:(NSNumber *)reservation writtenBytes:(uint64_t)written error:(NSError **)error {
    @synchronized (self.mediaState) {
        SRMediaLedger *ledger = [self ledger];
        if (SRMediaLedgerCommit(ledger, reservation.unsignedLongLongValue, written) != SRMediaStatusOK) {
            if (error) *error = SRImageAssetError(SRImageAssetErrorReservationInvalid, nil);
            return NO;
        }
        [_reservationTokens removeObjectForKey:reservation];
        return YES;
    }
}

- (BOOL)releaseReservation:(NSNumber *)reservation {
    @synchronized (self.mediaState) {
        SRMediaLedger *ledger = [self ledger];
        if (SRMediaLedgerRelease(ledger, reservation.unsignedLongLongValue) != SRMediaStatusOK) return NO;
        [_reservationTokens removeObjectForKey:reservation];
        return YES;
    }
}

/* Writes to a temporary name, then renames into place, so an interrupted write
 * can never leave a half-written snapshot that looks committed. */
- (NSInteger)writeData:(NSData *)data temporary:(NSString *)temporary final:(NSString *)final {
    int directory = [self openDirectoryCreating:YES];
    if (directory < 0) return SRImageAssetErrorDirectoryUnavailable;
    int file = openat(directory, temporary.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (file < 0) { close(directory); return SRImageAssetErrorWriteFailed; }
    BOOL full = NO, valid = YES;
    NSUInteger offset = 0;
    while (valid && offset < data.length) {
        ssize_t count = write(file, (const unsigned char *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { full = (errno == ENOSPC || errno == EDQUOT); valid = NO; }
        else offset += (NSUInteger)count;
    }
    if (valid && fsync(file) != 0) { full = (errno == ENOSPC || errno == EDQUOT); valid = NO; }
    close(file);
    if (valid && renameat(directory, temporary.fileSystemRepresentation,
                          directory, final.fileSystemRepresentation) != 0) {
        full = (errno == ENOSPC || errno == EDQUOT); valid = NO;
    }
    if (!valid) unlinkat(directory, temporary.fileSystemRepresentation, 0);
    close(directory);
    if (valid) return 0;
    return full ? SRImageAssetErrorDeviceFull : SRImageAssetErrorWriteFailed;
}

- (NSDictionary *)saveData:(NSData *)data source:(NSDictionary *)source error:(NSError **)error {
    return [self saveData:data scopeSHA256:SRImageScope(source) error:error];
}
- (NSDictionary *)saveData:(NSData *)data scopeSHA256:(NSString *)scope error:(NSError **)error {
    @synchronized (self.mediaState) {
        if (![data isKindOfClass:NSData.class] || !data.length || !SRHex(scope)) {
            if (error) *error = SRImageAssetError(SRImageAssetErrorInvalidSnapshot, nil);
            return nil;
        }
        if (data.length > (NSUInteger)SR_MEDIA_SINGLE_FILE_LIMIT_BYTES) {
            if (error) *error = SRImageAssetError(SRImageAssetErrorSingleFileExceeded, @{
                @"requestedBytes": @(data.length), SRImageAssetLimitBytesKey: @(SR_MEDIA_SINGLE_FILE_LIMIT_BYTES)});
            return nil;
        }
        NSDictionary *info = SRRasterInfo(data);
        if (!info) {
            if (error) *error = SRImageAssetError(SRImageAssetErrorInvalidSnapshot, nil);
            return nil;
        }
        NSNumber *reservation = [self reserveBytes:data.length token:nil reuseOnly:NO error:error];
        if (!reservation) return nil;
        NSString *token = NSUUID.UUID.UUIDString;
        NSString *name = [token stringByAppendingString:@".srimage"];
        NSString *temporary = [token stringByAppendingString:@".srtmp"];
        // Keep the token protected from a concurrent prune before the bytes land.
        _reservationTokens[reservation] = token;
        [_liveTemporaryNames addObject:temporary];
        NSInteger failure = [self writeData:data temporary:temporary final:name];
        [_liveTemporaryNames removeObject:temporary];
        if (failure) {
            SRMediaLedgerRelease([self ledger], reservation.unsignedLongLongValue);
            [_reservationTokens removeObjectForKey:reservation];
            if (error) *error = SRImageAssetError((SRImageAssetErrorCode)failure, @{@"requestedBytes": @(data.length)});
            return nil;
        }
        /* A successful file write is not a committed reservation until the
         * ledger accepts it.  Treat a ledger failure as a failed import and
         * remove the bytes instead of returning a payload that overstates the
         * durable budget. */
        SRMediaStatus commitStatus = SRMediaLedgerCommit([self ledger], reservation.unsignedLongLongValue, (uint64_t)data.length);
        if (commitStatus != SRMediaStatusOK) {
            int directory = [self openDirectoryCreating:NO];
            if (directory >= 0) {
                unlinkat(directory, name.fileSystemRepresentation, 0);
                close(directory);
            }
            (void)SRMediaLedgerRelease([self ledger], reservation.unsignedLongValue);
            [_reservationTokens removeObjectForKey:reservation];
            if (error) *error = SRImageAssetError(SRImageAssetErrorReservationInvalid, nil);
            return nil;
        }
        [_reservationTokens removeObjectForKey:reservation];
        NSMutableDictionary *payload = [info mutableCopy];
        [payload addEntriesFromDictionary:@{@"mediaReference": token, @"snapshotSchema": @1,
            @"scopeSHA256": scope, @"sha256": SRImageHash(data), @"byteCount": @(data.length)}];
        return [payload copy];
    }
}
- (NSData *)dataForPayload:(NSDictionary *)payload source:(NSDictionary *)source error:(NSError **)error {
    return [self dataForPayload:payload scopeSHA256:SRImageScope(source) error:error];
}
- (NSData *)dataForPayload:(NSDictionary *)payload scopeSHA256:(NSString *)scope error:(NSError **)error {
    @synchronized (self.mediaState) {
        if (![SRImageAssetStore validPayload:payload] || !SRHex(scope) || ![scope isEqual:payload[@"scopeSHA256"]]) {
            if (error) *error = SRImageAssetError(SRImageAssetErrorScopeMismatch, nil);
            return nil;
        }
        int directory = [self openDirectoryCreating:NO];
        NSString *name = [payload[@"mediaReference"] stringByAppendingString:@".srimage"];
        int file = directory >= 0 ? openat(directory, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW) : -1;
        if (directory >= 0) close(directory);
        struct stat status;
        if (file < 0 || fstat(file, &status) || !S_ISREG(status.st_mode) || status.st_size != [payload[@"byteCount"] longLongValue]) {
            if (file >= 0) close(file);
            if (error) *error = SRImageAssetError(SRImageAssetErrorUnreadable, nil);
            return nil;
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
            ![info[@"format"] isEqual:payload[@"format"]]) {
            if (error) *error = SRImageAssetError(SRImageAssetErrorIntegrityFailed, nil);
            return nil;
        }
        return [data copy];
    }
}
- (void)discardPayload:(NSDictionary *)payload {
    @synchronized (self.mediaState) {
        if (![SRImageAssetStore validPayload:payload]) return;
        int directory = [self openDirectoryCreating:NO];
        if (directory >= 0) {
            unlinkat(directory, [[payload[@"mediaReference"] stringByAppendingString:@".srimage"] fileSystemRepresentation], 0);
            close(directory);
        }
    }
}
- (NSUInteger)pruneTemporaryFilesOlderThan:(NSTimeInterval)age {
    @synchronized (self.mediaState) {
        int directory = [self openDirectoryCreating:NO];
        if (directory < 0) return 0;
        DIR *stream = fdopendir(directory);
        if (!stream) { close(directory); return 0; }
        NSUInteger removed = 0;
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        struct dirent *entry;
        for (;;) {
            errno = 0;
            entry = readdir(stream);
            if (!entry) break;
            NSString *name = @(entry->d_name);
            if (![name.pathExtension isEqual:SRImageTemporaryExtension]) continue;
            // A temporary file this process is still writing is never reclaimed.
            if ([_liveTemporaryNames containsObject:name]) continue;
            struct stat status;
            if (fstatat(dirfd(stream), entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) continue;
            if (!S_ISREG(status.st_mode)) continue;
            if (age > 0 && now - (NSTimeInterval)status.st_mtime < age) continue;
            if (unlinkat(dirfd(stream), entry->d_name, 0) == 0) removed += 1;
        }
        closedir(stream);
        return removed;
    }
}
- (void)pruneUnreferenced:(NSSet<NSString *> *)references {
    @synchronized (self.mediaState) {
        int directory = [self openDirectoryCreating:NO]; if (directory < 0) return;
        NSSet<NSString *> *live = [NSSet setWithArray:_reservationTokens.allValues];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.directory error:NULL]) {
            if (![name.pathExtension isEqual:SRImageSnapshotExtension]) continue;
            NSString *token = name.stringByDeletingPathExtension;
            NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:token];
            if ([uuid.UUIDString isEqual:token] && ![references containsObject:token] && ![live containsObject:token])
                unlinkat(directory, name.fileSystemRepresentation, 0);
        }
        close(directory);
    }
}
@end
