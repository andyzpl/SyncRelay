#import <Foundation/Foundation.h>
@class SRWeChatReceiver;
NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, SRSourceTimeProbeStopReason) {
    SRSourceTimeProbeUserStopped,
    SRSourceTimeProbeInactive,
    SRSourceTimeProbeConfigurationChanged,
    SRSourceTimeProbeAccountInvalidated
};

/* Main-thread, opt-in text-only observer. It shares the existing receiver and
 * never prepares images, offers a capture, writes a plan, or authorizes sends. */
@interface SRSourceTimeProbe : NSObject
@property(nonatomic, readonly) BOOL active;
- (instancetype)initWithReceiver:(SRWeChatReceiver *)receiver
                  classResolver:(Class _Nullable (^)(NSString *))resolver
                 currentAccount:(NSString * _Nullable (^)(void))currentAccount
        configurationForAccount:(NSDictionary * _Nullable (^)(NSString *))configuration
             environmentAllowed:(BOOL (^)(void))environmentAllowed
                 monotonicClock:(double (^)(void))monotonicClock
                      wallClock:(NSTimeInterval (^)(void))wallClock
                 legacyReceived:(void (^)(NSDictionary *))legacyReceived
                        changed:(void (^)(void))changed;
- (BOOL)startForAccount:(NSString *)account configuration:(NSDictionary *)configuration error:(NSError **)error;
- (void)stopForReason:(SRSourceTimeProbeStopReason)reason;
/* Call from the entry's existing timer, not a settings-page timer. */
- (void)tick;
/* Numeric/allowlisted evidence only. Semantics remain unverified. */
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
