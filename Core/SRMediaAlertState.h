#import <Foundation/Foundation.h>
#import "SRMediaQuota.h"

NS_ASSUME_NONNULL_BEGIN

/* File name of the reminder sidecar kept inside the media directory. It is
 * SyncRelay metadata, not media, so the budget scan ignores it. */
extern NSString *const SRMediaAlertFileName;

/* Durable per-account "80% reminder already shown" flag. Keys are account
 * digests, never account IDs, file names or message bodies. A corrupt or
 * unreadable state is reported as an error instead of being silently treated as
 * "never shown", so a damaged file cannot cause reminder spam. */
@interface SRMediaAlertState : NSObject
- (instancetype)initWithPath:(NSString *)path;
- (BOOL)raisedForAccount:(NSString *)account raised:(BOOL *)raised error:(NSError **)error;
- (BOOL)setRaised:(BOOL)raised forAccount:(NSString *)account error:(NSError **)error;
/* Read, apply hysteresis and persist under one process-wide monitor. Exactly
 * one caller claims a crossing, even through different SRStore instances. */
- (nullable NSNumber *)claimWarningForAccount:(NSString *)account snapshot:(SRMediaSnapshot)snapshot
                                     policy:(SRMediaPolicy)policy error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
