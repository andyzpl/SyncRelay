#import "SRSourceCapture.h"
#import "SRSourceMessage.h"
#import "SRConfiguration.h"
#import "SRStore.h"
@interface SRSourceCapture ()
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSDictionary *configuration;
@property(nonatomic, copy, nullable) NSDictionary *captured;
@property(nonatomic) BOOL waiting;
@property(nonatomic) NSUInteger offered;
@property(nonatomic) NSUInteger rejected;
@property(nonatomic) NSInteger lastReason;
@end
@implementation SRSourceCapture
- (instancetype)initWithStore:(SRStore *)store {
    self = [super init]; if (self) _store = store; return self;
}
- (NSDictionary *)preview { @synchronized(self) { return self.captured; } }
- (BOOL)armForAccount:(NSString *)account configuration:(NSDictionary *)configuration error:(NSError **)error {
    @synchronized(self) {
        NSDictionary *frozen = [SRSourceMessage frozenJSON:configuration];
        NSString *problem = nil; NSInteger code = 0;
        if (!account.length) { code = 11; problem = @"无法核对当前账号，请先重新读取配置。"; }
        else if (![SRConfiguration validateDraft:frozen error:NULL]) { code = 12; problem = @"当前设置无效，请检查来源、间隔和目标群后重新保存。"; }
        else if (![frozen[@"sourceGroup"] count]) { code = 13; problem = @"尚未选择母群，请先选择消息来源群。"; }
        else if (![frozen[@"senders"] count]) { code = 14; problem = @"尚未选择来源成员。更换母群后需重新勾选“我”或指定成员，再保存。"; }
        else if (![frozen[@"rules"] count]) { code = 15; problem = @"尚无目标规则，请先自动分组或手动选择目标群，再保存。"; }
        if (problem) {
            self.lastReason = code;
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.Capture" code:code userInfo:@{NSLocalizedDescriptionKey: problem}];
            return NO;
        }
        if (self.waiting || self.captured) {
            self.lastReason = 2;
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.Capture" code:2 userInfo:@{NSLocalizedDescriptionKey: @"已有等待或未确认预览，请先取消等待、确认或放弃预览。"}];
            return NO;
        }
        self.account = account; self.configuration = frozen; self.waiting = YES;
        self.offered = 0; self.rejected = 0; self.lastReason = 0;
        return YES;
    }
}
- (BOOL)offerEnvelope:(NSDictionary *)envelope {
    @synchronized(self) {
        NSDictionary *snapshot = [SRSourceMessage frozenJSON:envelope];
        self.offered++;
        if (!self.waiting || ![SRSourceMessage matchesEnvelope:snapshot configuration:self.configuration account:self.account]) {
            NSInteger reason = 24;
            if (!self.waiting) reason = 10;
            else if (![snapshot[@"sender"] isKindOfClass:NSString.class] || ![snapshot[@"type"] isKindOfClass:NSString.class]) reason = 24;
            else if (![snapshot[@"account"] isEqual:self.account]) reason = 20;
            else if (![snapshot[@"group"] isEqual:self.configuration[@"sourceGroup"][@"id"]]) reason = 21;
            else if (![[self.configuration[@"senders"] valueForKey:@"id"] containsObject:snapshot[@"sender"]]) reason = 22;
            else if (![self.configuration[@"types"] containsObject:snapshot[@"type"]]) reason = 23;
            self.rejected++; self.lastReason = reason; return NO;
        }
        self.lastReason = 0;
        self.captured = snapshot; self.waiting = NO;
        return YES;
    }
}
- (NSString *)confirmForCurrentAccount:(NSString *)account error:(NSError **)error {
    @synchronized(self) {
        if (!self.captured || ![account isEqual:self.account]) {
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.Capture" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No captured message or account changed"}];
            return nil;
        }
        NSString *plan = [self.store createPlanFromConfiguration:self.configuration envelope:self.captured account:account error:error];
        if (plan) [self cancel];
        return plan;
    }
}
- (void)cancel { @synchronized(self) { self.waiting = NO; self.captured = nil; self.configuration = nil; self.account = nil; } }
- (NSDictionary *)status {
    @synchronized(self) {
        return @{@"state": self.captured ? @"preview" : (self.waiting ? @"waiting" : @"idle"),
            @"account": self.account ?: (id)NSNull.null, @"configuration": self.configuration ?: @{}};
    }
}
- (NSDictionary *)diagnostics {
    @synchronized(self) {
        return @{@"state": self.captured ? @"preview" : (self.waiting ? @"waiting" : @"idle"),
            @"offered": @(self.offered), @"rejected": @(self.rejected), @"lastReasonCode": @(self.lastReason)};
    }
}
@end
