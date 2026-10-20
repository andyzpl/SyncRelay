#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const SREntryPreferencesChangedNotification;

@interface SREntryPreferences : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
@property(nonatomic) BOOL floatingEntryEnabled;
@end
NS_ASSUME_NONNULL_END
