#import <UIKit/UIKit.h>
@class SRStore, SRSourceCapture;
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const SRRelayStateChangedNotification;
FOUNDATION_EXPORT UIViewController *SRCreateCapturePreview(SRStore *store, SRSourceCapture *capture,
                                                          NSString *account, BOOL (^verifyAccount)(void));
FOUNDATION_EXPORT UIViewController *SRCreatePlanList(SRStore *store, NSString *account, BOOL (^verifyAccount)(void));
NS_ASSUME_NONNULL_END
