#import "SREntryPreferences.h"
#include <math.h>

NSNotificationName const SREntryPreferencesChangedNotification = @"andyz.syncrelay.entryPreferencesChanged";
static NSString *const SRFloatingEntryKey = @"andyz.syncrelay.floatingEntryEnabled";
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
- (BOOL)floatingEntryLeftEdge {
    return [[self.defaults objectForKey:SRFloatingEntryLeftEdgeKey] boolValue];
}
- (BOOL)floatingEntryPlacementSet {
    return [[self.defaults objectForKey:SRFloatingEntryPlacementSetKey] boolValue];
}
- (void)setFloatingEntryPlacementUnitY:(CGFloat)unitY leftEdge:(BOOL)leftEdge {
    CGFloat clamped = isfinite(unitY) ? MAX(0, MIN(1, unitY)) : 0.35;
    BOOL changed = !self.floatingEntryPlacementSet || fabs(self.floatingEntryUnitY - clamped) > 0.0001 || self.floatingEntryLeftEdge != leftEdge;
    [self.defaults setDouble:clamped forKey:SRFloatingEntryUnitYKey];
    [self.defaults setBool:leftEdge forKey:SRFloatingEntryLeftEdgeKey];
    [self.defaults setBool:YES forKey:SRFloatingEntryPlacementSetKey];
    if (changed) [NSNotificationCenter.defaultCenter postNotificationName:SREntryPreferencesChangedNotification object:self];
}
@end
