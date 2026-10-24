#import "SREntryPreferences.h"
#include <math.h>

NSNotificationName const SREntryPreferencesChangedNotification = @"andyz.syncrelay.entryPreferencesChanged";
static NSString *const SRFloatingEntryKey = @"andyz.syncrelay.floatingEntryEnabled";
static NSString *const SRFloatingEntryUnitXKey = @"andyz.syncrelay.floatingEntryUnitX";
static NSString *const SRFloatingEntryUnitYKey = @"andyz.syncrelay.floatingEntryUnitY";
static NSString *const SRFloatingEntryLeftEdgeKey = @"andyz.syncrelay.floatingEntryLeftEdge";
static NSString *const SRFloatingEntryPlacementSetKey = @"andyz.syncrelay.floatingEntryPlacementSet";

@interface SREntryPreferences ()
@property(nonatomic, strong) NSUserDefaults *defaults;
@end

@implementation SREntryPreferences
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (self) _defaults = defaults;
    return self;
}
- (BOOL)floatingEntryEnabled {
    id value = [self.defaults objectForKey:SRFloatingEntryKey];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
- (void)setFloatingEntryEnabled:(BOOL)enabled {
    BOOL changed = self.floatingEntryEnabled != enabled;
    [self.defaults setBool:enabled forKey:SRFloatingEntryKey];
    if (changed) [NSNotificationCenter.defaultCenter postNotificationName:SREntryPreferencesChangedNotification object:self];
}
- (CGFloat)floatingEntryUnitY {
    NSNumber *value = [self.defaults objectForKey:SRFloatingEntryUnitYKey];
    CGFloat unit = value ? value.doubleValue : 0.35;
    return isfinite(unit) ? MAX(0, MIN(1, unit)) : 0.35;
}
- (CGFloat)floatingEntryUnitX {
    NSNumber *value = [self.defaults objectForKey:SRFloatingEntryUnitXKey];
    // Older builds persisted only the edge; map that placement to the matching
    // horizontal endpoint until the user drags the entry again.
    if (!value) return self.floatingEntryLeftEdge ? 0 : 1;
    CGFloat unit = value.doubleValue;
    return isfinite(unit) ? MAX(0, MIN(1, unit)) : 1;
}
- (BOOL)floatingEntryLeftEdge {
    return [[self.defaults objectForKey:SRFloatingEntryLeftEdgeKey] boolValue];
}
- (BOOL)floatingEntryPlacementSet {
    return [[self.defaults objectForKey:SRFloatingEntryPlacementSetKey] boolValue];
}
- (void)setFloatingEntryPlacementUnitY:(CGFloat)unitY leftEdge:(BOOL)leftEdge {
    CGFloat clamped = isfinite(unitY) ? MAX(0, MIN(1, unitY)) : 0.35;
    [self setFloatingEntryPlacementUnitX:(leftEdge ? 0 : 1) unitY:clamped];
}
- (void)setFloatingEntryPlacementUnitX:(CGFloat)unitX unitY:(CGFloat)unitY {
    CGFloat clampedX = isfinite(unitX) ? MAX(0, MIN(1, unitX)) : 1;
    CGFloat clampedY = isfinite(unitY) ? MAX(0, MIN(1, unitY)) : 0.35;
    BOOL changed = !self.floatingEntryPlacementSet || fabs(self.floatingEntryUnitX - clampedX) > 0.0001 ||
        fabs(self.floatingEntryUnitY - clampedY) > 0.0001;
    [self.defaults setDouble:clampedX forKey:SRFloatingEntryUnitXKey];
    [self.defaults setDouble:clampedY forKey:SRFloatingEntryUnitYKey];
    [self.defaults setBool:clampedX < 0.5 forKey:SRFloatingEntryLeftEdgeKey];
    [self.defaults setBool:YES forKey:SRFloatingEntryPlacementSetKey];
    if (changed) [NSNotificationCenter.defaultCenter postNotificationName:SREntryPreferencesChangedNotification object:self];
}
@end
