#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/* Read-only presentation for the B-3 pages: message library and the shared
 * media budget. Everything here is a pure projection of a dictionary the store
 * already produced. Nothing queries SQLite, touches a file, calls a host
 * getter, prepares media or keeps a second copy of any business state. */
@interface SRMediaProjection : NSObject

/* Fixed-unit byte text ("0 B", "1.5 KB", "2.0 MB"). A missing, negative or
 * non-numeric value is "未知" rather than a fabricated zero. */
+ (NSString *)bytesText:(nullable id)value;
/* Usage level as returned by the media store: normal / warning / full. */
+ (NSString *)levelText:(nullable NSString *)level;
/* Physical resource kind: snapshot / derived / temporary. */
+ (NSString *)resourceKindText:(nullable NSString *)kind;
/* Library entry kind: text / image. An unknown kind is shown as unknown, never
 * silently treated as text. */
+ (NSString *)libraryKindText:(nullable NSString *)kind;

/* Header of the resource page.
 * Keys: available, problem (NSNull when usable), usedText, limitText,
 * remainingText, reclaimableText, percentText, level, levelText, fileCountText,
 * complete, warningRaised, scanValid (NSNumbers), note (NSNull or a warning). */
+ (NSDictionary *)usageSummary:(nullable NSDictionary *)usage;

/* One physical resource row.
 * Keys: identifier, kindText, bytesText, stateText, referenced, reclaimable,
 * inUse. The row never carries a path, a token or a body. */
+ (NSDictionary *)resourceRow:(nullable NSDictionary *)row;

/* What the resource section may show for one `mediaResourcesForAccount:` result.
 * Keys: state (unavailable / unverified / truncated_empty / empty / rows),
 * notice (NSNull when nothing needs saying), rows, listedCount,
 * otherAccountCount, truncated, verified.
 *
 * An unverified reference set withholds every detail row: the store cannot
 * prove which file belongs to this account. An empty page from a truncated read
 * is reported as incomplete, never as "nothing stored".
 * `listedCount` always equals the number of published `rows`, in every state,
 * so a withheld list can never report a non-zero count. */
+ (NSDictionary *)resourceSectionForPayload:(nullable NSDictionary *)payload;

/* Per-resource state, in priority order: in use, reclaimable, referenced. */
+ (NSString *)stateTextForRow:(nullable NSDictionary *)row;

@end
NS_ASSUME_NONNULL_END
