#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
/* A bounded subview, not an overlay window: touches outside it remain with
 * WeChat. The host owns foreground/account visibility and pause decisions. */
@interface SRFloatingProgress : UIView
@property(nonatomic, copy, nullable) void (^action)(void);
@property(nonatomic, copy, nullable) void (^openAction)(void);
@property(nonatomic, copy, nullable) void (^menuAction)(void);
@property(nonatomic, copy, nullable) void (^positionChanged)(CGFloat unitX, CGFloat unitY);
- (void)setInitialPositionUnitX:(CGFloat)unitX unitY:(CGFloat)unitY;
- (void)showModel:(NSDictionary *)model inWindow:(UIWindow *)window;
- (void)hide;
@end
NS_ASSUME_NONNULL_END
