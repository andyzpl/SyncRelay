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
@end
@implementation SRSourceCapture
- (instancetype)initWithStore:(SRStore *)store {
    self = [super init]; if (self) _store = store; return self;
}
- (NSDictionary *)preview { @synchronized(self) { return self.captured; } }
- (BOOL)armForAccount:(NSString *)account configuration:(NSDictionary *)configuration error:(NSError **)error {
    @synchronized(self) {
        NSDictionary *frozen = [SRSourceMessage frozenJSON:configuration];
        if (!account.length || ![SRConfiguration validateDraft:frozen error:error] ||
            ![frozen[@"sourceGroup"] count] || ![frozen[@"senders"] count] || ![frozen[@"rules"] count]) {
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.Capture" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Choose an account, source, senders and at least one target rule"}];
            return NO;
        }
        if (self.waiting || self.captured) {
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.Capture" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Cancel or confirm the current capture first"}];
            return NO;
        }
        self.account = account; self.configuration = frozen; self.waiting = YES;
        return YES;
    }
}
- (BOOL)offerEnvelope:(NSDictionary *)envelope {
    @synchronized(self) {
        NSDictionary *snapshot = [SRSourceMessage frozenJSON:envelope];
        if (!self.waiting || ![SRSourceMessage matchesEnvelope:snapshot configuration:self.configuration account:self.account]) return NO;
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
@end
