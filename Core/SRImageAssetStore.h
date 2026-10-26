#import <Foundation/Foundation.h>
#import "SRMediaQuota.h"

NS_ASSUME_NONNULL_BEGIN

/* Distinct outcomes. Callers must not collapse these into one "image failed"
 * message: a full quota asks the user to free space, a full device does not, and
 * an unreadable snapshot asks for a reimport. Codes 1..7 are unchanged. */
typedef NS_ENUM(NSInteger, SRImageAssetErrorCode) {
    SRImageAssetErrorInvalidSnapshot = 1,
    SRImageAssetErrorDirectoryUnavailable = 2,
    SRImageAssetErrorQuotaExceeded = 3,
    SRImageAssetErrorWriteFailed = 4,
    SRImageAssetErrorScopeMismatch = 5,
    SRImageAssetErrorUnreadable = 6,
    SRImageAssetErrorIntegrityFailed = 7,
    /* The settings UI already uses 8 for its own dimension error, so new codes
     * start at 20 and never collide with existing call sites. */
    SRImageAssetErrorSingleFileExceeded = 20,
    SRImageAssetErrorDeviceFull = 21,
    SRImageAssetErrorUsageUnavailable = 22,
    SRImageAssetErrorReservationInvalid = 23,
};

/* Present on quota failures so a caller can say exactly how much to free. */
extern NSString *const SRImageAssetShortfallBytesKey;
extern NSString *const SRImageAssetUsedBytesKey;
extern NSString *const SRImageAssetLimitBytesKey;

/* Own immutable raster snapshots, never host paths, message XML or remote URLs.
 * Every write goes through one shared byte budget (snapshots, library media,
 * derived previews and in-flight temporary files, all accounts). Instances for
 * the same directory path share the scan/write monitor and live reservations
 * within this process; another instance cannot reclaim an in-use token. */
@interface SRImageAssetStore : NSObject
@property(nonatomic, copy, readonly) NSString *directory;
- (instancetype)initWithDirectory:(NSString *)directory;
+ (BOOL)validPayload:(id)payload;
/* Lowercase SHA-256 of the exact bytes; nil for non-data or empty input. */
+ (nullable NSString *)sha256ForData:(NSData *)data;
/* Library media is scoped to the verified account, not to a group message
 * identity, so an entry never has to invent a group or server message ID. */
+ (nullable NSString *)libraryScopeForAccount:(NSString *)account;
- (nullable NSDictionary *)saveData:(NSData *)data source:(NSDictionary *)source error:(NSError **)error;
- (nullable NSData *)dataForPayload:(NSDictionary *)payload source:(NSDictionary *)source error:(NSError **)error;
/* Same size, raster and quota rules with a caller-supplied scope string. The
 * scope is still pinned into the payload and rechecked on every read. */
- (nullable NSDictionary *)saveData:(NSData *)data scopeSHA256:(NSString *)scope error:(NSError **)error;
- (nullable NSData *)dataForPayload:(NSDictionary *)payload scopeSHA256:(NSString *)scope error:(NSError **)error;
/* Only for an unconfirmed preview owned by this capture. Confirmed plans retain their files. */
- (void)discardPayload:(NSDictionary *)payload;

/* Exact usage of the shared budget. A scan that cannot complete returns nil and
 * an error, never a zero that would look like free space.
 * `tokens` is the set of tokens that must survive pruning; when it is nil the
 * reclaimable figure covers interrupted temporary files only and the result
 * says so through `reclaimableComplete`.
 * The returned dictionary never contains a token, file name or body. */
- (nullable NSDictionary *)usageSnapshotProtectingTokens:(nullable NSSet<NSString *> *)tokens
                                                   error:(NSError **)error;
- (BOOL)mediaSnapshot:(SRMediaSnapshot *)snapshot
      protectingTokens:(nullable NSSet<NSString *> *)tokens error:(NSError **)error;

/* Read-only inventory behind the resource page. One row per physical file,
 * deduplicated by device+inode like the byte scan. A row never carries a path, a
 * body or a thumbnail; `token` is the storage handle and is only used in-process
 * for reference matching. Rows are newest-first and capped by `limit`.
 * A directory that cannot be listed returns nil plus an error, never an empty
 * array that would read as "nothing stored". */
- (nullable NSArray<NSDictionary *> *)mediaObjectsProtectingTokens:(nullable NSSet<NSString *> *)tokens
                                                             limit:(NSUInteger)limit
                                                             error:(NSError **)error;

/* Explicit reservation for an import that has not written yet. Check and add
 * happen under one lock, so concurrent importers cannot both pass. Pass
 * reuseOnly:YES when identical bytes are already stored and no new byte is
 * needed; that form is allowed even at full quota. `token` names an existing
 * asset that must not be pruned while the caller registers its reference.
 * Every successful reservation must be committed or released exactly once. */
- (nullable NSNumber *)reserveBytes:(uint64_t)bytes token:(nullable NSString *)token
                          reuseOnly:(BOOL)reuse error:(NSError **)error;
- (BOOL)commitReservation:(NSNumber *)reservation writtenBytes:(uint64_t)written
                    error:(NSError **)error;
- (BOOL)releaseReservation:(NSNumber *)reservation;

/* Startup only. Removes temporary files abandoned by an interrupted write; a
 * live writer's temporary file and every non-temporary file are left alone. */
- (NSUInteger)pruneTemporaryFilesOlderThan:(NSTimeInterval)age;
/* Startup only, after loading confirmed plan references. No recursive deletion,
 * and a token with a live reservation is never removed. */
- (void)pruneUnreferenced:(NSSet<NSString *> *)references;
@end

NS_ASSUME_NONNULL_END
