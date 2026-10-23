#import <Foundation/Foundation.h>
@class SRWeChatReceiver;
NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, SRSourceTimeProbeStopReason) {
    SRSourceTimeProbeUserStopped,
    SRSourceTimeProbeInactive,
    SRSourceTimeProbeConfigurationChanged,
    SRSourceTimeProbeAccountInvalidated
};

/* Main-thread, opt-in observer: delivered text plus supplemental text/image
 * hook metadata. Shares the receiver; never prepares media or authorizes sends. */
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
/* A foreground page transition may briefly make UIKit inactive. Mark it here;
 * the entry's existing timer stops the probe if active does not return within
 * the bounded grace period. A real background event stops immediately. */
- (void)noteApplicationInactive;
- (void)noteApplicationActive;
/* Call from the entry's existing timer, not a settings-page timer. */
- (void)tick;
/* Numeric/allowlisted evidence only. Semantics remain unverified. */
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
