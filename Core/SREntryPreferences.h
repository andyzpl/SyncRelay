#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const SREntryPreferencesChangedNotification;

@interface SREntryPreferences : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
@property(nonatomic) BOOL floatingEntryEnabled;
/* Independent UI preference: whether the chat long-press menu gets the
 * SyncRelay entry. Off by default; never part of the frozen business draft. */
@property(nonatomic) BOOL libraryMenuEntryEnabled;
@property(nonatomic, readonly) CGFloat floatingEntryUnitX;
@property(nonatomic, readonly) CGFloat floatingEntryUnitY;
@property(nonatomic, readonly) BOOL floatingEntryLeftEdge;
@property(nonatomic, readonly) BOOL floatingEntryPlacementSet;
- (void)setFloatingEntryPlacementUnitX:(CGFloat)unitX unitY:(CGFloat)unitY;
- (void)setFloatingEntryPlacementUnitY:(CGFloat)unitY leftEdge:(BOOL)leftEdge;
@end
NS_ASSUME_NONNULL_END
