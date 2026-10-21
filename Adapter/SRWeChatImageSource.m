#import "SRWeChatImageSource.h"
#import "SRRuntime.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
static const char *SRImageType(const char *type) { while (*type && strchr("rnNoORV", *type)) type++; return type; }
static BOOL SRImageObjectType(const char *raw) { const char *type = SRImageType(raw); return type[0] == '@' && type[1] != '?'; }
@interface SRWeChatImageSource ()
@property(nonatomic, copy) Class (^resolver)(NSString *);
@property(nonatomic, copy) NSString *state;
@property(nonatomic) NSUInteger reads;
@end
@implementation SRWeChatImageSource
- (instancetype)initWithClassResolver:(Class (^)(NSString *))resolver {
    self = [super init]; if (self) { _resolver = [resolver copy]; _state = @"idle"; } return self;
}
- (BOOL)compatible {
    Class wrap = self.resolver(@"CMessageWrap");
    Method method = wrap ? class_getClassMethod(wrap, NSSelectorFromString(@"getMsgHdOrMiddleImg:")) : NULL;
    if (!method) return NO;
    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        return signature.numberOfArguments == 3 && SRImageObjectType(signature.methodReturnType) &&
            SRImageObjectType([signature getArgumentTypeAtIndex:0]) &&
            !strcmp(SRImageType([signature getArgumentTypeAtIndex:1]), ":") && SRImageObjectType([signature getArgumentTypeAtIndex:2]);
    } @catch (__unused id exception) { return NO; }
}
- (id)imageForWrap:(id)wrap error:(NSError **)error {
    @try {
        if (!NSThread.isMainThread || ![self compatible]) { self.state = @"abi_unavailable"; @throw @"gate"; }
        Class expected = self.resolver(@"CMessageWrap"), imageClass = self.resolver(@"UIImage");
        if (!wrap || ![wrap isKindOfClass:expected] || ![SRReadUnsignedInteger(wrap, @"m_uiMessageType", NULL) isEqual:@3] || !imageClass) {
            self.state = @"identity_rejected"; @throw @"gate";
        }
        self.reads++; self.state = @"reading";
        id image = ((id (*)(id, SEL, id))objc_msgSend)(expected, NSSelectorFromString(@"getMsgHdOrMiddleImg:"), wrap);
        self.state = image ? @"ready" : @"awaiting_native_image";
        if (image && ![image isKindOfClass:imageClass]) { self.state = @"result_not_image"; @throw @"gate"; }
        return image;
    } @catch (__unused id exception) {
        if ([self.state isEqual:@"reading"]) self.state = @"read_failed";
        if (error) *error = [NSError errorWithDomain:@"SyncRelay.ImageSource" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Native image getter is missing, incompatible or failed; export diagnostics"}];
        return nil;
    }
}
- (NSDictionary *)diagnostics {
    return @{@"schema": @1, @"state": self.state ?: @"idle", @"reads": @(self.reads),
        @"getterABICompatible": @([self compatible]), @"nativeDownloadEnabled": @NO, @"sendingEnabled": @NO,
        @"method": SRDescribeMethod(self.resolver(@"CMessageWrap"), @"getMsgHdOrMiddleImg:")};
}
@end
