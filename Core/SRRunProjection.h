#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/* Display phases for the Phase B group list and run detail. They are derived
 * from a durable run row and never replace it: the original `state` string is
 * kept in the projection so the page can show the raw business status. */
FOUNDATION_EXPORT NSString *const SRRunPhaseNotStarted;
FOUNDATION_EXPORT NSString *const SRRunPhaseRunning;
FOUNDATION_EXPORT NSString *const SRRunPhasePaused;
FOUNDATION_EXPORT NSString *const SRRunPhaseSettling;
FOUNDATION_EXPORT NSString *const SRRunPhaseCompleted;
FOUNDATION_EXPORT NSString *const SRRunPhaseAbnormal;
FOUNDATION_EXPORT NSString *const SRRunPhaseEnded;
FOUNDATION_EXPORT NSString *const SRRunPhaseCancelled;
/* An unrecognised durable state must never be presented as success. */
FOUNDATION_EXPORT NSString *const SRRunPhaseUnknown;

FOUNDATION_EXPORT NSString *const SRGroupFilterAll;
FOUNDATION_EXPORT NSString *const SRGroupFilterNotStarted;
FOUNDATION_EXPORT NSString *const SRGroupFilterActive;
FOUNDATION_EXPORT NSString *const SRGroupFilterCompleted;
FOUNDATION_EXPORT NSString *const SRGroupFilterAbnormal;

/* The per-rule execution range enforced by SRStore (1...20 targets). This is
 * the same constant, not a second policy: pages only display it. */
FOUNDATION_EXPORT NSUInteger const SRRunProjectionTargetLimit;

/* Pure, Foundation-only presentation projections for the operations pages.
 *
 * Every input is a dictionary that SRStore already produced, and every output
 * is a value derived from it. Nothing here queries a database, keeps a cached
 * business state, decides that a message was delivered, or performs an action.
 * SRStore stays the only source of content/plan/rule/run rows and
 * SRSmallGroupSession stays the only command owner. */
@interface SRRunProjection : NSObject

/* `yyyy-MM-dd HH:mm` in the device's local time zone, including the date so a
 * run that crosses midnight still reads correctly. A missing, boolean or
 * non-positive value is "未记录"; the page clock is never substituted. */
+ (NSString *)localDateTimeText:(nullable id)value;
+ (NSString *)localDateText:(nullable id)value;
/* Same instant with seconds and an explicit zone, for plugin-local source
 * times. Only these plugin-measured values may be rendered as a wall clock. */
+ (NSString *)localTimeWithZoneText:(nullable id)value;

/* The host value is a raw number whose unit, epoch and meaning are unverified.
 * It is printed as-is: handing it to NSDate would present a guessed date as
 * evidence. */
+ (NSString *)unverifiedHostTimeText:(nullable id)value;

/* Source-time rows of an envelope (plan snapshot or operations content). */
+ (NSString *)observedTimeTextForEnvelope:(nullable NSDictionary *)envelope;
+ (NSString *)frozenTimeTextForEnvelope:(nullable NSDictionary *)envelope;
+ (NSString *)hostTimeTextForEnvelope:(nullable NSDictionary *)envelope;

/* Short excerpt of the frozen content. It never unlocks the host image: an
 * image is described by the metadata already stored with the snapshot. */
+ (NSString *)excerptForEnvelope:(nullable NSDictionary *)envelope limit:(NSUInteger)limit;
+ (NSString *)typeTextForEnvelope:(nullable NSDictionary *)envelope;

/* Raw run state -> display phase. `cancelled` must only be YES when the caller
 * read a cancellation row for this exact run and account; an `ended` run
 * without it stays "已结束", never "处理完成". */
+ (NSString *)phaseForState:(nullable NSString *)state cancelled:(BOOL)cancelled counts:(nullable NSDictionary *)counts;
+ (NSString *)phaseText:(nullable NSString *)phase;
+ (BOOL)phaseIsActive:(nullable NSString *)phase;

/* Normalised counts plus the phase, the raw state and the persisted times.
 * Keys: state, phase, phaseText, counts, total, processed, inflight,
 * abnormal, startedText, endedText, hasRun. */
+ (NSDictionary *)runSummary:(nullable NSDictionary *)run;

/* Whether a page that displayed `boundRunID` still looks at the same run.
 * A page bound to a run is stale when that run is gone or superseded; a page
 * that displayed "no run" (nil) is stale as soon as any run exists. A stale
 * page must close every control instead of adopting the run it never showed.
 * The only way a page may adopt a run is its own successful start. */
+ (BOOL)pageIsStaleForBoundRun:(nullable NSString *)boundRunID currentRunID:(nullable NSString *)currentRunID;
/* Explicit per-outcome lines. "处理完成" never stands in for delivery. */
+ (NSArray<NSString *> *)countLinesForSummary:(NSDictionary *)summary;
/* One line for the group list: "已处理 3/5" or "未开始 · 共 5 群". */
+ (NSString *)progressTextForSummary:(nullable NSDictionary *)summary targetCount:(NSUInteger)targetCount;

/* Group rows from the frozen plan cards of SRStore.ruleCardsForPlan:. Frozen
 * plans do not persist target names, so search matches the group name and the
 * stored target identifiers; names are only available in configuration mode. */
+ (NSArray<NSDictionary *> *)groupRowsForCards:(nullable NSArray<NSDictionary *> *)cards;
/* Read-only rows from the saved configuration: the group and member list can
 * be inspected when no content is confirmed, but nothing is executable. */
+ (NSArray<NSDictionary *> *)groupRowsForConfiguration:(nullable NSDictionary *)configuration;

/* Row keys: identifier, name, targetCount, targets, targetNames, phase,
 * statusText, progressText, blockedText (NSNull when executable),
 * executable, runID (NSNull when not started), run (summary or NSNull). */
+ (NSArray<NSDictionary *> *)rows:(nullable NSArray<NSDictionary *> *)rows
                     matchingText:(nullable NSString *)text filter:(nullable NSString *)filter;
+ (NSArray<NSString *> *)filterIdentifiers;
+ (NSString *)titleForFilter:(NSString *)filter;

/* Aggregates only over groups that already have a run, so an unstarted group
 * cannot inflate the progress of the current content. */
+ (NSDictionary *)overviewForGroupRows:(nullable NSArray<NSDictionary *> *)rows;

/* The newest terminal run of one plan, chosen by durable insertion order
 * (creationOrder), never by a possibly rolled-back wall clock. */
+ (nullable NSDictionary *)latestRunInCards:(nullable NSArray<NSDictionary *> *)cards;

@end
NS_ASSUME_NONNULL_END
