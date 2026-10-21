#import <UIKit/UIKit.h>
@class SRImageAssetStore;
NS_ASSUME_NONNULL_BEGIN
/* Decode only an integrity/scope-checked owned snapshot. Not an original-file forward. */
BOOL SRImageMaterialSupportsPayload(NSDictionary *payload);
NSDictionary * _Nullable SRCreateImageMaterial(SRImageAssetStore *assets, NSDictionary *source, NSError **error);
NS_ASSUME_NONNULL_END
