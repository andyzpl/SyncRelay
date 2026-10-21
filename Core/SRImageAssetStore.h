#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/* Own immutable raster snapshots, never host paths, message XML or remote URLs. */
@interface SRImageAssetStore : NSObject
- (instancetype)initWithDirectory:(NSString *)directory;
+ (BOOL)validPayload:(id)payload;
- (nullable NSDictionary *)saveData:(NSData *)data source:(NSDictionary *)source error:(NSError **)error;
- (nullable NSData *)dataForPayload:(NSDictionary *)payload source:(NSDictionary *)source error:(NSError **)error;
/* Only for an unconfirmed preview owned by this capture. Confirmed plans retain their files. */
- (void)discardPayload:(NSDictionary *)payload;
/* Startup only, after loading confirmed plan references. No recursive deletion. */
- (void)pruneUnreferenced:(NSSet<NSString *> *)references;
@end
NS_ASSUME_NONNULL_END
