#import <Foundation/Foundation.h>
@class SRStore;

NS_ASSUME_NONNULL_BEGIN

/* Explicit outcomes. A caller must not collapse them into one "failed" message. */
typedef NS_ENUM(NSUInteger, SRLibraryIntakeResult) {
    SRLibraryIntakeSaved = 0,
    /* The same operation and the same request, already saved. */
    SRLibraryIntakeDuplicate = 1,
    SRLibraryIntakeUnsupportedType = 2,
    SRLibraryIntakeInvalidInput = 3,
    SRLibraryIntakeAccountUnavailable = 4,
    SRLibraryIntakeWriteFailed = 5,
    /* The operation key is already bound to a different account or a different
     * body. It is refused instead of resolving to the earlier entry. */
    SRLibraryIntakeConflictingRequest = 6,
    /* The store this intake belongs to was released. Nothing is saved and no
     * remembered entry is returned as if it had succeeded. */
    SRLibraryIntakeStoreUnavailable = 7,
};

/* Explicit text capture into the message library.
 *
 * Owned per store for the whole process: `intakeForStore:` returns the one
 * instance the entry layer is expected to use, so a repeated tap or a
 * duplicated callback reaches the same operation ledger. Tests may build an
 * isolated instance with `initWithStore:` when they need a clean ledger.
 *
 * One user confirmation is one operation. The ledger binds a key to the exact
 * request (account, type, body) and to the entry it created:
 * - the same request repeats as a duplicate and returns the same entry;
 * - a different account, type or body under the same key is refused, never
 *   resolved to the earlier entry and never written;
 * - check, write and publish happen under one serialization, so two callers
 *   cannot both write and then pick a winner;
 * - a failed write publishes nothing, so a retry can still save once.
 *
 * Only ordinary text is accepted; every other type is refused instead of being
 * degraded. The stored payload carries the complete body only - no group,
 * sender, account or server message ID. Nothing here creates a task, run, claim
 * or delivery, sends, or touches an in-flight group-sync run. The library
 * tables remain the only durable record; this ledger is process-local and
 * never a second source of business state. */
@interface SRLibraryIntake : NSObject

/* The process-wide intake for one store. The entry layer must use this rather
 * than building a fresh instance per tap, or the ledger proves nothing. */
+ (instancetype)intakeForStore:(SRStore *)store;

/* Isolated instance with its own empty ledger. For tests and for a caller that
 * deliberately scopes intake to one operation. */
- (instancetype)initWithStore:(SRStore *)store;

/* Saves one text body for one operation key. `capturedAt` is this process's
 * intake time; a host creation timestamp is never treated as a verified time. */
- (nullable NSString *)saveText:(NSString *)text
                   operationKey:(NSString *)operationKey
                        account:(NSString *)account
                     capturedAt:(NSTimeInterval)capturedAt
                         result:(SRLibraryIntakeResult *)result
                          error:(NSError **)error;

/* Same entry point with an explicit type. Anything other than ordinary text is
 * refused before anything is written. */
- (nullable NSString *)saveMessageOfType:(NSString *)type
                                 payload:(NSDictionary *)payload
                            operationKey:(NSString *)operationKey
                                 account:(NSString *)account
                              capturedAt:(NSTimeInterval)capturedAt
                                  result:(SRLibraryIntakeResult *)result
                                   error:(NSError **)error;

/* YES only when this key completed for this account in this process. */
- (BOOL)hasSavedOperationKey:(NSString *)operationKey account:(NSString *)account;

@end
NS_ASSUME_NONNULL_END
