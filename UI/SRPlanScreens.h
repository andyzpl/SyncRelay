#import <UIKit/UIKit.h>
@class SRStore, SRSourceCapture, SRSmallGroupSession;
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const SRRelayStateChangedNotification;
FOUNDATION_EXPORT UIViewController *SRCreateCapturePreview(SRStore *store, SRSourceCapture *capture,
                                                          NSString *account, BOOL (^verifyAccount)(void), SRSmallGroupSession * _Nullable execution);
FOUNDATION_EXPORT UIViewController *SRCreatePlanList(SRStore *store, NSString *account, BOOL (^verifyAccount)(void), SRSmallGroupSession * _Nullable execution);
/* Phase B operations home. This is a read/projection shell; it does not arm
 * capture or start a run just by opening the page. The optional openSettings
 * route is an explicit callback bound to the account captured when the home
 * was opened; the caller re-verifies that account before routing. */
FOUNDATION_EXPORT UIViewController *SRCreateOperationsHome(SRStore *store, SRSourceCapture *capture,
                                                           SRSmallGroupSession * _Nullable execution,
                                                           NSString *account, BOOL (^verifyAccount)(void),
                                                           void (^ _Nullable openSettings)(void));
/* B-2 group list. planID is the frozen plan of the content the user is acting
 * on; nil means "no confirmed content" and the page becomes read-only.
 * `configuration` is the configuration frozen with that content (the preview's
 * capture-time configuration, or the configuration persisted with the prepared
 * content). It is projected when planID is nil, so settings edited after the
 * capture cannot rewrite the groups this content shows. Both pages re-verify
 * the account and re-read the durable rows before any command. */
FOUNDATION_EXPORT UIViewController *SRCreateGroupList(SRStore *store, SRSmallGroupSession * _Nullable execution,
                                                      NSString *account, BOOL (^verifyAccount)(void),
                                                      NSString * _Nullable planID,
                                                      NSDictionary * _Nullable configuration);
FOUNDATION_EXPORT UIViewController *SRCreateRunDetail(SRStore *store, SRSmallGroupSession * _Nullable execution,
                                                      NSString *account, BOOL (^verifyAccount)(void),
                                                      NSString * _Nullable planID, NSString * _Nullable ruleID,
                                                      NSString * _Nullable runID);
/* Reuses the existing paged exception/unsent screen for one exact run. */
FOUNDATION_EXPORT UIViewController *SRCreateRunExceptions(SRStore *store, NSString *account,
                                                          BOOL (^verifyAccount)(void), NSString *run);
/* One read-only text page for stored text. It re-verifies the account before
 * showing its body and hides it again when the app leaves the foreground, so a
 * page that only displays stored text never needs a second implementation. */
FOUNDATION_EXPORT UIViewController *SRCreateReadOnlyText(NSString *title, NSString * _Nullable body,
                                                         BOOL (^verifyAccount)(void));
NS_ASSUME_NONNULL_END
