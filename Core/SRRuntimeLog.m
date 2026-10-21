#import "SRRuntimeLog.h"
#include <math.h>

@interface SRRuntimeLog ()
@property(nonatomic, strong) NSMutableArray *events;
@property(nonatomic, copy) NSString *session;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *persistenceState;
@property(nonatomic) NSUInteger sequence;
@property(nonatomic) BOOL scheduled;
@property(nonatomic, strong) dispatch_queue_t writer;
@end

static NSSet *SRLogEvents(void) {
    static NSSet *values; static dispatch_once_t once;
    dispatch_once(&once, ^{ values = [NSSet setWithArray:@[@"boot", @"source_changed", @"draft_saved", @"draft_save_failed",
        @"capture_attempt", @"capture_blocked", @"capture_started", @"capture_arm_failed", @"capture_cancelled",
        @"source_candidate", @"capture_accepted", @"capture_rejected", @"inactive", @"export_created",
        @"receive_callback", @"receive_wrong_session", @"receive_wrong_direction", @"receive_invalid_sender",
        @"receive_not_text", @"receive_no_server_id", @"receive_empty_text", @"outgoing_callback",
        @"outgoing_wrong_session", @"outgoing_wrong_direction", @"outgoing_not_text", @"own_pending",
        @"own_conflict", @"own_timeout", @"own_readback", @"account_changed", @"receiver_stopped", @"receiver_arm",
        @"receive_sender_filtered", @"receive_type_filtered", @"image_pending", @"image_ready", @"image_timeout", @"image_conflict", @"image_failed",
        @"source_time_rejected", @"source_time_changed",
        @"text_test_countdown", @"text_test_claimed", @"text_test_submitted", @"text_test_blocked",
        @"image_test_countdown", @"image_test_claimed", @"image_test_submitted", @"image_test_blocked",
        @"small_group_started", @"small_group_paused", @"small_group_submitted", @"small_group_unknown"]]; });
    return values;
}
static NSDictionary *SRLogFacts(NSDictionary *facts) {
    NSSet *keys = [NSSet setWithArray:@[@"sourceSelected", @"senderCount", @"ruleCount", @"targetCount", @"includesSelf",
        @"dirty", @"errorCode", @"reasonCode", @"textEnabled", @"imageEnabled", @"storageReady", @"removedTargets"]];
    NSMutableDictionary *safe = [NSMutableDictionary dictionary];
    if (![facts isKindOfClass:NSDictionary.class]) return @{};
    for (id key in facts) if ([keys containsObject:key] && [facts[key] isKindOfClass:NSNumber.class] && isfinite([facts[key] doubleValue]))
        safe[key] = facts[key];
    return [safe copy];
}
@implementation SRRuntimeLog
+ (instancetype)shared { static SRRuntimeLog *log; static dispatch_once_t once; dispatch_once(&once, ^{ log = [[self alloc] init]; }); return log; }
- (instancetype)init {
    self = [super init];
    if (self) {
        _events = [NSMutableArray array]; _session = NSUUID.UUID.UUIDString; _persistenceState = @"memory_only";
        _writer = dispatch_queue_create("andyz.syncrelay.runtime-log", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)enablePersistenceAtPath:(NSString *)path {
    @synchronized(self) {
        if (self.path || !path.length) return;
        self.path = path; self.persistenceState = @"ready";
        NSNumber *size = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL][NSFileSize];
        if (size.unsignedLongLongValue > 256 * 1024) { self.persistenceState = @"oversized_previous_log_ignored"; return; }
        NSData *data = [NSData dataWithContentsOfFile:path];
        id previous = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([previous isKindOfClass:NSArray.class]) {
            NSMutableArray *loaded = [NSMutableArray array];
            for (id row in previous) {
                if (![row isKindOfClass:NSDictionary.class] || ![SRLogEvents() containsObject:row[@"event"]] ||
                    ![row[@"time"] isKindOfClass:NSNumber.class]) continue;
                // Never trust arbitrary fields or session strings from an older file.
                [loaded addObject:@{@"event": row[@"event"], @"time": row[@"time"], @"previousLaunch": @YES,
                    @"facts": SRLogFacts(row[@"facts"])}];
            }
            [loaded addObjectsFromArray:self.events];
            while (loaded.count > 300) [loaded removeObjectAtIndex:0];
            self.events = loaded;
        }
    }
}
- (void)record:(NSString *)event facts:(NSDictionary *)facts {
    if (![SRLogEvents() containsObject:event]) return;
    @synchronized(self) {
        [self.events addObject:@{@"event": [event copy], @"time": @(NSDate.date.timeIntervalSince1970),
            @"sequence": @(++self.sequence), @"session": self.session, @"facts": SRLogFacts(facts)}];
        if (self.events.count > 300) [self.events removeObjectAtIndex:0];
        if (!self.path || self.scheduled) return;
        self.scheduled = YES;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), self.writer, ^{
            SRRuntimeLog *log = weakSelf; if (!log) return;
            NSData *data; NSString *path;
            @synchronized(log) {
                data = [NSJSONSerialization dataWithJSONObject:log.events options:0 error:NULL];
                path = log.path; log.scheduled = NO;
            }
            BOOL saved = data && [data writeToFile:path options:NSDataWritingAtomic error:NULL];
            @synchronized(log) { log.persistenceState = saved ? @"ready" : @"write_failed"; }
        });
    }
}
- (NSDictionary *)snapshot {
    @synchronized(self) { return @{@"limit": @300, @"persistence": self.persistenceState, @"events": [self.events copy]}; }
}
@end
