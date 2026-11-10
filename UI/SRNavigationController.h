#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@protocol SRNavigationBackGuard <NSObject>
- (BOOL)sr_hasUnsavedChanges;
- (void)sr_requestClose;
@end

/* Return only the page that issued the intent, preserving the original root. */
FOUNDATION_EXPORT BOOL SRPopPluginPage(UIViewController *controller, BOOL animated);
@interface SRNavigationController : UINavigationController <UINavigationControllerDelegate, UIGestureRecognizerDelegate>
- (void)requestBack;
@end
NS_ASSUME_NONNULL_END
