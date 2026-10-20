#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface SRSourceMessage : NSObject
/* Envelope is supplied by a future verified receive adapter, not by nickname parsing. */
+ (BOOL)matchesEnvelope:(NSDictionary *)envelope configuration:(NSDictionary *)configuration account:(NSString *)account;
+ (nullable NSDictionary *)frozenJSON:(id)object;
@end
NS_ASSUME_NONNULL_END
