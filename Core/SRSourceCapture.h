#import <Foundation/Foundation.h>
@class SRStore;
NS_ASSUME_NONNULL_BEGIN
@interface SRSourceCapture : NSObject
@property(nonatomic, readonly, copy, nullable) NSDictionary *preview;
- (instancetype)initWithStore:(SRStore *)store;
/* Injected clock: the preview-freeze time is read once, at acceptance, so a
 * native test can prove the two time stages differ without sleeping. */
- (instancetype)initWithStore:(SRStore *)store clock:(NSTimeInterval (^)(void))clock;
- (BOOL)armForAccount:(NSString *)account configuration:(NSDictionary *)configuration error:(NSError **)error;
/* Binds the receiver round allowed to deliver into this capture round. The
 * receiver and capture counters are independent and are never compared to each
 * other; an evidence generation is only ever checked against this binding. */
- (void)bindReceiverGeneration:(nullable NSNumber *)generation;
/* A match stops listening and waits for explicit confirmation. Never creates a run. */
- (BOOL)offerEnvelope:(NSDictionary *)envelope;
/* Same gate, plus the allowlisted time evidence produced by the receive hook. */
- (BOOL)offerEnvelope:(NSDictionary *)envelope evidence:(nullable NSDictionary *)evidence;
- (nullable NSString *)confirmForCurrentAccount:(NSString *)account error:(NSError **)error;
/* Includes the frozen configuration so preview never describes a newer edited draft. */
- (NSDictionary *)status;
/* Redacted state and numeric rejection codes; no source/account/body data. */
- (NSDictionary *)diagnostics;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
