#import <Foundation/Foundation.h>
#import "Adapter/SRWeChatImageSource.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))
@interface NativeImage : NSObject
@end
@implementation NativeImage
@end
static id Result;
static NSUInteger Calls;
static BOOL Throw;
@interface ImageWrap : NSObject
@property(nonatomic) unsigned int m_uiMessageType;
+ (id)getMsgHdOrMiddleImg:(id)wrap;
@end
@implementation ImageWrap
+ (id)getMsgHdOrMiddleImg:(__unused id)wrap { Calls++; if (Throw) @throw @"private path and image key"; return Result; }
@end
@interface BadABIWrap : NSObject
+ (double)getMsgHdOrMiddleImg:(id)wrap;
@end
@implementation BadABIWrap
+ (double)getMsgHdOrMiddleImg:(__unused id)wrap { abort(); }
@end
@interface ReflectionImageWrap : ImageWrap
@end
@implementation ReflectionImageWrap
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (selector == @selector(getMsgHdOrMiddleImg:)) return [NSMethodSignature signatureWithObjCTypes:"v@:"];
    return [super methodSignatureForSelector:selector];
}
@end
static SRWeChatImageSource *reader(Class wrap) {
    return [[SRWeChatImageSource alloc] initWithClassResolver:^Class(NSString *name) {
        return [name isEqual:@"CMessageWrap"] ? wrap : ([name isEqual:@"UIImage"] ? NativeImage.class : Nil);
    }];
}
int main(void) {
    @autoreleasepool {
        SRWeChatImageSource *source = reader(ImageWrap.class); ImageWrap *wrap = [[ImageWrap alloc] init]; wrap.m_uiMessageType = 3;
        NSError *error = nil;
        CHECK([source.diagnostics[@"getterABICompatible"] boolValue]);
        CHECK(![source imageForWrap:wrap error:&error] && !error && Calls == 1);
        CHECK([source.diagnostics[@"state"] isEqual:@"awaiting_native_image"]);
        Result = [[NativeImage alloc] init]; CHECK([source imageForWrap:wrap error:NULL] == Result);
        Result = @"private filesystem path"; CHECK(![source imageForWrap:wrap error:&error] && error);
        CHECK([source.diagnostics[@"state"] isEqual:@"result_not_image"]);
        CHECK(![source.diagnostics.description containsString:Result]);
        Result = [[NativeImage alloc] init]; wrap.m_uiMessageType = 1; NSUInteger count = Calls;
        CHECK(![source imageForWrap:wrap error:NULL] && Calls == count);
        CHECK(![source imageForWrap:NSObject.new error:NULL] && Calls == count);
        wrap.m_uiMessageType = 3; Throw = YES;
        CHECK(![source imageForWrap:wrap error:&error] && ![error.description containsString:@"private"]); Throw = NO;
        SRWeChatImageSource *bad = reader(BadABIWrap.class);
        CHECK(![bad.diagnostics[@"getterABICompatible"] boolValue] && ![bad imageForWrap:wrap error:NULL]);
        CHECK(![reader(Nil) imageForWrap:wrap error:NULL]);
        ReflectionImageWrap *reflected = [[ReflectionImageWrap alloc] init]; reflected.m_uiMessageType = 3;
        CHECK([reader(ReflectionImageWrap.class) imageForWrap:reflected error:NULL] == Result);
        CHECK(![source.diagnostics[@"sendingEnabled"] boolValue] && ![source.diagnostics[@"nativeDownloadEnabled"] boolValue]);
        Result = nil;
        puts("PASS: evidence-bound native image getter, declared ABI, nil readiness, result identity, exception privacy and no send/download");
    }
    return 0;
}
