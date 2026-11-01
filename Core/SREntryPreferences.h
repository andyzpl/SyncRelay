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
/* Upper bound for one frozen task. Defaults to 200; the admin setting may
 * raise it to 600. The store keeps 600 as its absolute ceiling. */
@property(nonatomic) NSInteger maxTargetsPerTask;
/* The same bound for callers that only have defaults (screens). */
FOUNDATION_EXPORT NSInteger SREntryMaxTargetsPerTask(void);
@property(nonatomic, readonly) CGFloat floatingEntryUnitX;
@property(nonatomic, readonly) CGFloat floatingEntryUnitY;
@property(nonatomic, readonly) BOOL floatingEntryLeftEdge;
@property(nonatomic, readonly) BOOL floatingEntryPlacementSet;
- (void)setFloatingEntryPlacementUnitX:(CGFloat)unitX unitY:(CGFloat)unitY;
- (void)setFloatingEntryPlacementUnitY:(CGFloat)unitY leftEdge:(BOOL)leftEdge;
@end
NS_ASSUME_NONNULL_END
