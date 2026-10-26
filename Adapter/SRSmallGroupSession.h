#import <Foundation/Foundation.h>
#import "Core/SRRunner.h"
#import "Core/SRRelayCoordinator.h"
@class SRStore;
NS_ASSUME_NONNULL_BEGIN

@protocol SRSmallGroupHost <NSObject>
- (BOOL)readyForAccount:(NSString *)account error:(NSError **)error;
- (void)submitRequest:(NSDictionary *)request completion:(SRSendCompletion)completion;
- (void)stopObservation;
- (NSDictionary *)diagnostics;
@end
typedef id<SRSmallGroupHost> _Nullable (^SRSmallGroupHostFactory)(NSDictionary *source, BOOL (^allowed)(void));

/* Main-thread lifecycle owner for the 1..20-group device checkpoint. Native
 * work is asynchronously bridged from the runner, never dispatch_sync to UI.
 * A host is single-use; a durable delivery claim is required before creating it.
 * Constructing this owner or reopening a page never starts/resumes a rule. */
@interface SRSmallGroupSession : NSObject <SRRelayExecution>
- (instancetype)initWithStore:(SRStore *)store
                currentAccount:(NSString * _Nullable (^)(void))currentAccount
            environmentAllowed:(BOOL (^)(void))environmentAllowed
                 targetAllowed:(BOOL (^)(NSString *target))targetAllowed
                   hostFactory:(SRSmallGroupHostFactory)hostFactory
                         clock:(double (^)(void))clock random:(double (^)(void))random;
- (BOOL)startRule:(NSString *)rule account:(NSString *)account error:(NSError **)error;
- (BOOL)resumeRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
- (BOOL)pauseForAccount:(NSString *)account error:(NSError **)error;
- (BOOL)endRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
- (BOOL)cancelRun:(NSString *)run account:(NSString *)account error:(NSError **)error;
/* Main-thread timer supplied by the app. Background/lock stops observation
 * and new dispatch; returning to foreground does not resume. */
- (void)tick;
- (void)becameInactive;
- (BOOL)togglePauseForCurrentAccount:(NSError **)error;
- (BOOL)progressBelongsToCurrentAccount;
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly) BOOL needsIdleTimer;
@property(nonatomic, readonly) BOOL usedNativeHost;
/* Stable identifier for a visible cancel/resume command. A nil value means
 * there is no attached run; callers must still verify the account snapshot. */
@property(nonatomic, readonly, copy, nullable) NSString *currentRunID;
- (NSDictionary *)status;
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
