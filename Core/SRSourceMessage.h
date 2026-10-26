#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface SRSourceMessage : NSObject
/* Envelope is supplied by a future verified receive adapter, not by nickname parsing. */
+ (BOOL)matchesEnvelope:(NSDictionary *)envelope configuration:(NSDictionary *)configuration account:(NSString *)account;
+ (nullable NSDictionary *)frozenJSON:(id)object;
/* Numeric, allowlisted time evidence only. A missing or unusable value stays
 * absent instead of being invented, and no correlation ID, body, path or
 * internal observer field crosses this boundary. */
+ (nullable NSDictionary *)allowlistedTimeEvidence:(nullable NSDictionary *)evidence;
@end
NS_ASSUME_NONNULL_END
