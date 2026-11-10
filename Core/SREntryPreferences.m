#import "SREntryPreferences.h"
#include <math.h>

NSNotificationName const SREntryPreferencesChangedNotification = @"andyz.syncrelay.entryPreferencesChanged";
static NSString *const SRFloatingEntryKey = @"andyz.syncrelay.floatingEntryEnabled";
static NSString *const SRLibraryMenuEntryKey = @"andyz.syncrelay.libraryMenuEntryEnabled";
static NSString *const SRMaxTargetsKey = @"andyz.syncrelay.maxTargetsPerTask";
static NSString *const SRFloatingEntryUnitXKey = @"andyz.syncrelay.floatingEntryUnitX";
static NSString *const SRFloatingEntryUnitYKey = @"andyz.syncrelay.floatingEntryUnitY";
static NSString *const SRFloatingEntryLeftEdgeKey = @"andyz.syncrelay.floatingEntryLeftEdge";
static NSString *const SRFloatingEntryPlacementSetKey = @"andyz.syncrelay.floatingEntryPlacementSet";

NSString *SRTargetLimitMessage(NSUInteger count, NSUInteger limit) {
    return [NSString stringWithFormat:@"\u672c\u6b21\u6709 %lu \u4e2a\u76ee\u6807\u7fa4\uff0c\u5f53\u524d\u4e0a\u9650 %lu\u3002"
                                      "\u53ef\u5230\u300c\u8bbe\u7f6e \u2192 \u9ad8\u7ea7\u8bbe\u7f6e \u2192 \u5355\u6b21\u8f6c\u53d1\u76ee\u6807\u4e0a\u9650\u300d\u66f4\u6539\u4e0a\u9650\u3002",
        (unsigned long)count, (unsigned long)limit];
}

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
- (BOOL)libraryMenuEntryEnabled {
    id value = [self.defaults objectForKey:SRLibraryMenuEntryKey];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
- (NSInteger)maxTargetsPerTask {
    id value = [self.defaults objectForKey:SRMaxTargetsKey];
    NSInteger limit = [value isKindOfClass:NSNumber.class] ? [value integerValue] : 200;
    return MIN(MAX(limit, 1), SRForwardingTargetCeiling);
}

- (void)setMaxTargetsPerTask:(NSInteger)maxTargetsPerTask {
    NSInteger clamped = MIN(MAX(maxTargetsPerTask, 1), SRForwardingTargetCeiling);
    BOOL changed = self.maxTargetsPerTask != clamped;
    [self.defaults setInteger:clamped forKey:SRMaxTargetsKey];
    if (changed) [NSNotificationCenter.defaultCenter postNotificationName:SREntryPreferencesChangedNotification object:self];
}

- (void)setLibraryMenuEntryEnabled:(BOOL)enabled {
    BOOL changed = self.libraryMenuEntryEnabled != enabled;
    [self.defaults setBool:enabled forKey:SRLibraryMenuEntryKey];
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
