#import <UIKit/UIKit.h>
@class SRWeChatReceiver;
FOUNDATION_EXPORT UIViewController *SRCreateAppMessagePreviewScreen(SRWeChatReceiver *receiver, NSString *account, BOOL (^verify)(void));
