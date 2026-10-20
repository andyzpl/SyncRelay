#import "SREntryPreferences.h"

NSNotificationName const SREntryPreferencesChangedNotification = @"andyz.syncrelay.entryPreferencesChanged";
static NSString *const SRFloatingEntryKey = @"andyz.syncrelay.floatingEntryEnabled";

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
@end
