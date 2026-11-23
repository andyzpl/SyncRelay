#import <UIKit/UIKit.h>
@class SRStore;

NS_ASSUME_NONNULL_BEGIN
/* Page-local, memory-only previews. Implemented with the library screens. */
@interface SRLocalImagePreviews : NSObject
@property(nonatomic) NSUInteger maximumPixels;
- (void)invalidate;
- (BOOL)unavailableForItem:(NSString *)item version:(NSString *)version account:(NSString *)account;
- (BOOL)unavailableForRun:(NSString *)run account:(NSString *)account;
- (nullable UIImage *)imageForItem:(NSString *)item version:(NSString *)version account:(NSString *)account
                             store:(SRStore *)store completion:(void (^)(void))completion;
- (nullable UIImage *)imageForRun:(NSString *)run account:(NSString *)account
                            store:(SRStore *)store completion:(void (^)(void))completion;
@end
NS_ASSUME_NONNULL_END
