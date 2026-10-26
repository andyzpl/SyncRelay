#import <UIKit/UIKit.h>
@class SRStore, SRSourceCapture, SRSmallGroupSession;
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const SRRelayStateChangedNotification;
FOUNDATION_EXPORT UIViewController *SRCreateCapturePreview(SRStore *store, SRSourceCapture *capture,
                                                          NSString *account, BOOL (^verifyAccount)(void), SRSmallGroupSession * _Nullable execution);
FOUNDATION_EXPORT UIViewController *SRCreatePlanList(SRStore *store, NSString *account, BOOL (^verifyAccount)(void), SRSmallGroupSession * _Nullable execution);
/* Phase B operations home. This is a read/projection shell; it does not arm
 * capture or start a run just by opening the page. */
FOUNDATION_EXPORT UIViewController *SRCreateOperationsHome(SRStore *store, SRSourceCapture *capture,
                                                           SRSmallGroupSession * _Nullable execution,
                                                           NSString *account, BOOL (^verifyAccount)(void));
NS_ASSUME_NONNULL_END
