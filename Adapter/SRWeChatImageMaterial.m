#import "SRWeChatImageMaterial.h"
#import "Core/SRImageAssetStore.h"

BOOL SRImageMaterialSupportsPayload(NSDictionary *payload) {
    return [SRImageAssetStore validPayload:payload] && [payload[@"pixelWidth"] unsignedLongLongValue] <= 8192 &&
        [payload[@"pixelHeight"] unsignedLongLongValue] <= 8192 &&
        [payload[@"pixelWidth"] unsignedLongLongValue] * [payload[@"pixelHeight"] unsignedLongLongValue] <= 16000000ULL;
}
NSDictionary *SRCreateImageMaterial(SRImageAssetStore *assets, NSDictionary *source, NSError **error) {
    if (!NSThread.isMainThread || !SRImageMaterialSupportsPayload(source[@"payload"])) return nil;
    NSData *snapshot = nil;
    if ([source[@"sourceKind"] isEqual:@"message_library"]) {
        if (![source[@"itemID"] isKindOfClass:NSString.class] || ![source[@"itemID"] length] ||
            ![source[@"versionID"] isKindOfClass:NSString.class] || ![source[@"versionID"] length] ||
            source[@"group"] || source[@"sender"] || source[@"messageID"]) return nil;
        NSString *scope = [SRImageAssetStore libraryScopeForAccount:source[@"account"]];
        snapshot = scope ? [assets dataForPayload:source[@"payload"] scopeSHA256:scope error:error] : nil;
    } else {
        if (source[@"sourceKind"] || ![source[@"group"] isKindOfClass:NSString.class] ||
            ![source[@"sender"] isKindOfClass:NSString.class] || ![source[@"messageID"] isKindOfClass:NSString.class]) return nil;
        snapshot = [assets dataForPayload:source[@"payload"] source:source error:error];
    }
    if (!snapshot) return nil;
    UIImage *image = [UIImage imageWithData:snapshot scale:1];
    CGImageRef raster = image.CGImage;
    if (!raster || image.images.count > 1 || image.imageOrientation != UIImageOrientationUp ||
        CGImageGetWidth(raster) != [source[@"payload"][@"pixelWidth"] unsignedIntegerValue] ||
        CGImageGetHeight(raster) != [source[@"payload"][@"pixelHeight"] unsignedIntegerValue]) return nil;
    // The observed host route passes UIImage plus JPEG data, not a file path.
    // Encode the same owned static raster; do not call it original-quality forwarding.
    NSData *jpeg = UIImageJPEGRepresentation(image, 0.95);
    if (!jpeg.length || jpeg.length > 20 * 1024 * 1024) return nil;
    return @{@"image": image, @"data": jpeg};
}
