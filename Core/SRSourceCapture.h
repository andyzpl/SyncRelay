#import <Foundation/Foundation.h>
@class SRStore;
NS_ASSUME_NONNULL_BEGIN
@interface SRSourceCapture : NSObject
@property(nonatomic, readonly, copy, nullable) NSDictionary *preview;
- (instancetype)initWithStore:(SRStore *)store;
- (BOOL)armForAccount:(NSString *)account configuration:(NSDictionary *)configuration error:(NSError **)error;
/* A match stops listening and waits for explicit confirmation. Never creates a run. */
- (BOOL)offerEnvelope:(NSDictionary *)envelope;
- (nullable NSString *)confirmForCurrentAccount:(NSString *)account error:(NSError **)error;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
