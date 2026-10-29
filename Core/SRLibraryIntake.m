#import "SRLibraryIntake.h"
#import "SRStore.h"
#include <math.h>

/* One completed operation: the exact request it was bound to and the entry it
 * produced. Storing the body (not a hash) keeps the comparison exact, so two
 * different messages that happen to collide in a digest are never confused. */
@interface SRLibraryIntakeRecord : NSObject
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSString *type;
@property(nonatomic, copy) NSString *body;
@property(nonatomic, copy) NSString *item;
@end
@implementation SRLibraryIntakeRecord
@end

@interface SRLibraryIntake ()
/* Weak: the intake must never be the reason a store outlives its owner. Every
 * operation takes one strong local reference for its own duration instead. */
@property(nonatomic, weak) SRStore *store;
/* operationKey -> record. Guarded by `lock`; never read outside it. */
@property(nonatomic, strong) NSMutableDictionary<NSString *, SRLibraryIntakeRecord *> *ledger;
@property(nonatomic, strong) NSObject *lock;
@end

/* Weak keys: the map never keeps a store alive, and when the store is released
 * its intake entry disappears with it. The intake itself also keeps only a weak
 * store reference; each write takes a strong local for its duration. An earlier
 * version used a plain dictionary of NSValue keys and leaked both objects, so
 * that ownership claim was wrong. */
static NSMapTable<SRStore *, SRLibraryIntake *> *SRLibraryIntakes(void) {
    static NSMapTable *intakes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ intakes = [NSMapTable weakToStrongObjectsMapTable]; });
    return intakes;
}

@implementation SRLibraryIntake

+ (instancetype)intakeForStore:(SRStore *)store {
    if (!store) return nil;
    // Pointer identity is the key: SRStore does not override isEqual:/hash.
    SRStore *key = store;
    @synchronized(SRLibraryIntakes()) {
        SRLibraryIntake *existing = [SRLibraryIntakes() objectForKey:key];
        if (existing) return existing;
        SRLibraryIntake *created = [[SRLibraryIntake alloc] initWithStore:store];
        [SRLibraryIntakes() setObject:created forKey:key];
        return created;
    }
}

- (instancetype)initWithStore:(SRStore *)store {
    self = [super init];
    if (self) { _store = store; _ledger = [NSMutableDictionary dictionary]; _lock = [NSObject new]; }
    return self;
}

static BOOL SRLibraryIntakeFail(NSError **error, NSString *reason) {
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.LibraryIntake" code:1
        userInfo:@{NSLocalizedDescriptionKey: reason}];
    return NO;
}

- (BOOL)hasSavedOperationKey:(NSString *)operationKey account:(NSString *)account {
    if (!operationKey.length || !account.length) return NO;
    @synchronized(self.lock) {
        SRLibraryIntakeRecord *record = self.ledger[operationKey];
        return record != nil && [record.account isEqual:account];
    }
}

- (NSString *)saveMessageOfType:(NSString *)type payload:(NSDictionary *)payload
                   operationKey:(NSString *)operationKey account:(NSString *)account
                     capturedAt:(NSTimeInterval)capturedAt
                         result:(SRLibraryIntakeResult *)result error:(NSError **)error {
    if (result) *result = SRLibraryIntakeWriteFailed;
    if (!account.length) {
        if (result) *result = SRLibraryIntakeAccountUnavailable;
        SRLibraryIntakeFail(error, @"当前账号无法核对，这条消息没有加入消息库");
        return nil;
    }
    if (!operationKey.length) {
        if (result) *result = SRLibraryIntakeInvalidInput;
        SRLibraryIntakeFail(error, @"缺少本次操作标识，不能确认这条消息只保存一次");
        return nil;
    }
    // Only ordinary text. Anything else is refused rather than degraded.
    if (![type isKindOfClass:NSString.class] || ![type isEqual:@"text"]) {
        if (result) *result = SRLibraryIntakeUnsupportedType;
        SRLibraryIntakeFail(error, @"本版只支持普通文字加入消息库；其他类型不会降级保存");
        return nil;
    }
    id body = [payload isKindOfClass:NSDictionary.class] ? payload[@"text"] : nil;
    if (![body isKindOfClass:NSString.class] || ![body length]) {
        if (result) *result = SRLibraryIntakeInvalidInput;
        SRLibraryIntakeFail(error, @"这条消息没有可保存的文字内容");
        return nil;
    }
    NSString *text = body;
    // The stored payload is the complete body and nothing else: no group, sender,
    // account or server message ID may travel with it.
    NSDictionary *stored = @{@"text": text};
    if (!(capturedAt > 0) || !isfinite(capturedAt)) capturedAt = NSDate.date.timeIntervalSince1970;

    // Check, write and publish are one critical section. Two callers for the same
    // key can therefore never both write and then agree on a winner, and nothing
    // has to be deleted afterwards to hide a second row.
    @synchronized(self.lock) {
        // Hold the store for this operation only. A released store is refused
        // before the ledger is consulted, so a dead store can never be answered
        // with a remembered entry as if the write had happened.
        SRStore *store = self.store;
        if (!store) {
            if (result) *result = SRLibraryIntakeStoreUnavailable;
            SRLibraryIntakeFail(error, @"消息库存储已不可用，这条消息没有保存");
            return nil;
        }
        SRLibraryIntakeRecord *record = self.ledger[operationKey];
        if (record) {
            BOOL sameRequest = [record.account isEqual:account] && [record.type isEqual:type] &&
                [record.body isEqual:text];
            if (sameRequest) {
                if (result) *result = SRLibraryIntakeDuplicate;
                return record.item;
            }
            // A reused key with a different request is a caller defect, not a
            // retry: refuse it instead of handing back the earlier entry.
            if (result) *result = SRLibraryIntakeConflictingRequest;
            SRLibraryIntakeFail(error, @"这次操作标识已经用于另一条消息，本条没有保存");
            return nil;
        }
        NSError *failure = nil;
        NSString *item = [store createLibraryItemForAccount:account kind:@"text" payload:stored
            capturedAt:capturedAt error:&failure];
        if (!item.length) {
            // Nothing is published, so a retry of the same operation can succeed.
            if (result) *result = SRLibraryIntakeWriteFailed;
            if (error) *error = failure ?: [NSError errorWithDomain:@"SyncRelay.LibraryIntake" code:2
                userInfo:@{NSLocalizedDescriptionKey: @"写入消息库失败，未保存任何内容"}];
            return nil;
        }
        SRLibraryIntakeRecord *created = [SRLibraryIntakeRecord new];
        created.account = account; created.type = type; created.body = text; created.item = item;
        self.ledger[operationKey] = created;
        if (result) *result = SRLibraryIntakeSaved;
        return item;
    }
}

- (NSString *)saveText:(NSString *)text operationKey:(NSString *)operationKey account:(NSString *)account
            capturedAt:(NSTimeInterval)capturedAt
                result:(SRLibraryIntakeResult *)result error:(NSError **)error {
    NSDictionary *payload = [text isKindOfClass:NSString.class] ? @{@"text": text} : @{};
    return [self saveMessageOfType:@"text" payload:payload operationKey:operationKey account:account
        capturedAt:capturedAt result:result error:error];
}

@end
