#import <UIKit/UIKit.h>
@class SRStore, SRSourceCapture, SRSmallGroupSession;
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const SRRelayStateChangedNotification;
FOUNDATION_EXPORT UIViewController *SRCreateCapturePreview(SRStore *store, SRSourceCapture *capture,
                                                          NSString *account, BOOL (^verifyAccount)(void), SRSmallGroupSession * _Nullable execution);
FOUNDATION_EXPORT UIViewController *SRCreatePlanList(SRStore *store, NSString *account, BOOL (^verifyAccount)(void), SRSmallGroupSession * _Nullable execution);
NS_ASSUME_NONNULL_END
