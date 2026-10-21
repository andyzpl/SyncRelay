#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface SRExecutionProgress : NSObject
/* Aggregate-only presentation model. Processed includes submitted/unknown,
 * never a claim that the displayed number was delivered. */
+ (NSDictionary *)modelForStatus:(NSDictionary *)status;
@end
NS_ASSUME_NONNULL_END
