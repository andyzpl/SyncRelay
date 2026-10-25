#import "SRMediaAlertState.h"
#import "SRImageAssetStore.h"
#include <math.h>

NSString *const SRMediaAlertFileName = @".srquota-alert.json";

static const NSInteger SRMediaAlertSchema = 1;

/* One process-wide lock: callers build a fresh instance per query, so an
 * instance lock would not serialise the read-modify-write of the same file. */
static NSRecursiveLock *SRMediaAlertLock(void) {
    static NSRecursiveLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSRecursiveLock new]; });
    return lock;
}

static NSError *SRMediaAlertError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"SyncRelay.MediaAlert" code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface SRMediaAlertState ()
@property(nonatomic, copy) NSString *path;
- (BOOL)readRaisedForAccount:(NSString *)account raised:(BOOL *)raised error:(NSError **)error;
@end

@implementation SRMediaAlertState

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) _path = [path copy];
    return self;
}

- (NSString *)keyForAccount:(NSString *)account {
    NSData *data = [account dataUsingEncoding:NSUTF8StringEncoding];
    return data.length ? [SRImageAssetStore sha256ForData:data] : nil;
}

/* Returns nil with an error for an unreadable or malformed file. A missing file
 * is a valid empty state. */
- (NSMutableDictionary *)loadWithError:(NSError **)error {
    if (![NSFileManager.defaultManager fileExistsAtPath:self.path]) {
        return [@{@"version": @(SRMediaAlertSchema), @"accounts": [NSMutableDictionary dictionary]} mutableCopy];
    }
    NSData *data = [NSData dataWithContentsOfFile:self.path options:0 error:NULL];
    NSDictionary *stored = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![stored isKindOfClass:NSDictionary.class] || ![stored[@"accounts"] isKindOfClass:NSDictionary.class] ||
        ![stored[@"version"] isEqual:@(SRMediaAlertSchema)]) {
        if (error) *error = SRMediaAlertError(1, @"Media reminder state is unreadable");
        return nil;
    }
    return [@{@"version": @(SRMediaAlertSchema), @"accounts": [stored[@"accounts"] mutableCopy]} mutableCopy];
}

- (BOOL)readRaisedForAccount:(NSString *)account raised:(BOOL *)raised error:(NSError **)error {
    NSString *key = [self keyForAccount:account];
    if (!key) {
        if (error) *error = SRMediaAlertError(1, @"Verified account is required");
        return NO;
    }
    @synchronized (SRMediaAlertLock()) {
        NSMutableDictionary *state = [self loadWithError:error];
        if (!state) return NO;
        id stored = state[@"accounts"][key];
        if (stored && ![stored isKindOfClass:NSDictionary.class]) {
            if (error) *error = SRMediaAlertError(1, @"Media reminder state is unreadable");
            return NO;
        }
        if (stored) {
            id flag = stored[@"raised"], updated = stored[@"updatedAt"];
            double flagValue = [flag isKindOfClass:NSNumber.class] ? [flag doubleValue] : -1;
            double updatedValue = [updated isKindOfClass:NSNumber.class] ? [updated doubleValue] : -1;
            /* A missing or malformed entry must not look like "not raised":
             * otherwise a damaged sidecar would silently re-arm reminders. */
            if (![flag isKindOfClass:NSNumber.class] || (flagValue != 0 && flagValue != 1) ||
                ![updated isKindOfClass:NSNumber.class] || !isfinite(updatedValue) || updatedValue < 0) {
                if (error) *error = SRMediaAlertError(1, @"Media reminder state is unreadable");
                return NO;
            }
        }
        if (raised) *raised = [stored[@"raised"] boolValue];
        return YES;
    }
}

- (BOOL)raisedForAccount:(NSString *)account raised:(BOOL *)raised error:(NSError **)error {
    return [self readRaisedForAccount:account raised:raised error:error];
}

- (NSNumber *)claimWarningForAccount:(NSString *)account snapshot:(SRMediaSnapshot)snapshot
                             policy:(SRMediaPolicy)policy error:(NSError **)error {
    if (!SRMediaPolicyIsValid(policy)) {
        if (error) *error = SRMediaAlertError(1, @"A valid media threshold policy is required");
        return nil;
    }
    @synchronized (SRMediaAlertLock()) {
        BOOL raised = NO;
        if (![self readRaisedForAccount:account raised:&raised error:error]) return nil;
        SRMediaAlertAction action = SRMediaAlertStep(raised, snapshot, policy);
        if (action == SRMediaAlertRaise)
            return [self setRaised:YES forAccount:account error:error] ? @YES : nil;
        if (action == SRMediaAlertClear && ![self setRaised:NO forAccount:account error:error]) return nil;
        return @NO;
    }
}

- (BOOL)setRaised:(BOOL)raised forAccount:(NSString *)account error:(NSError **)error {
    NSString *key = [self keyForAccount:account];
    if (!key) {
        if (error) *error = SRMediaAlertError(1, @"Verified account is required");
        return NO;
    }
    @synchronized (SRMediaAlertLock()) {
        NSMutableDictionary *state = [self loadWithError:error];
        if (!state) return NO;
        state[@"accounts"][key] = @{@"raised": @(raised ? 1 : 0),
            @"updatedAt": @(NSDate.date.timeIntervalSince1970)};
        NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:NULL];
        if (!data) {
            if (error) *error = SRMediaAlertError(2, @"Media reminder state could not be encoded");
            return NO;
        }
        NSString *directory = self.path.stringByDeletingLastPathComponent;
        if (directory.length && ![NSFileManager.defaultManager createDirectoryAtPath:directory
                withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:NULL]) {
            if (error) *error = SRMediaAlertError(2, @"Media reminder state directory is unavailable");
            return NO;
        }
        if (![data writeToFile:self.path options:NSDataWritingAtomic error:NULL]) {
            if (error) *error = SRMediaAlertError(2, @"Media reminder state could not be written");
            return NO;
        }
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600}
            ofItemAtPath:self.path error:NULL];
        return YES;
    }
}

@end
