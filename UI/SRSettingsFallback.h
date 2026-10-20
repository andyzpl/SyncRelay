#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
/* A settings-only footer row, not a window overlay or table delegate replacement. */
FOUNDATION_EXPORT BOOL SRUpdateSettingsFallback(UIViewController *controller, BOOL nativeRowPresent,
                                               void (^open)(UIViewController *controller));
NS_ASSUME_NONNULL_END
