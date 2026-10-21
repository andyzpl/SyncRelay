#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Adapter/SRWeChatImageSendProbe.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

static NSUInteger Constructs, ExtensionReads;
static BOOL Throw, SwitchAccount, WrongIdentity;
static id Extension;
static NSString *Account = @"synthetic-account";

@interface ProbeLongImage : NSObject
- (void)setImage:(id)image withData:(id)data isLongOriginImage:(BOOL)flag;
@end
@implementation ProbeLongImage
- (void)setImage:(__unused id)image withData:(__unused id)data isLongOriginImage:(__unused BOOL)flag { abort(); }
@end
@interface ProbeOriginImage : NSObject
- (void)setImage:(id)image withData:(id)data isOriginImage:(signed char)flag;
@end
@implementation ProbeOriginImage
- (void)setImage:(__unused id)image withData:(__unused id)data isOriginImage:(__unused signed char)flag { abort(); }
@end
@interface ProbeBadImage : NSObject
- (void)setImage:(id)image withData:(id)data isLongOriginImage:(double)flag;
@end
@implementation ProbeBadImage
- (void)setImage:(__unused id)image withData:(__unused id)data isLongOriginImage:(__unused double)flag { abort(); }
@end
@interface ProbeImageBase : NSObject
@property(nonatomic) unsigned int m_uiMessageType;
@property(nonatomic) unsigned int m_uiMesLocalID;
@property(nonatomic) unsigned long long m_n64MesSvrID;
@property(nonatomic) unsigned int m_uiCreateTime;
@property(nonatomic) unsigned int m_uiStatus;
@property(nonatomic, copy) NSString *m_nsFromUsr;
@property(nonatomic, copy) NSString *m_nsToUsr;
- (instancetype)initWithMsgType:(long long)type;
@end
@implementation ProbeImageBase
- (instancetype)initWithMsgType:(long long)type {
    self = [super init];
    if (self) { Constructs++; _m_uiMessageType = WrongIdentity ? 1 : (unsigned int)type; }
    return self;
}
@end
@interface ProbeImageWrap : ProbeImageBase
- (id)m_extendInfoWithMsgType;
@end
@implementation ProbeImageWrap
- (id)m_extendInfoWithMsgType {
    ExtensionReads++; if (SwitchAccount) Account = @"changed-account";
    if (Throw) @throw @"private wxid path and image key";
    return Extension;
}
// Deliberately misleading instance metadata must never control a native ABI call.
- (NSMethodSignature *)methodSignatureForSelector:(__unused SEL)selector { return [NSMethodSignature signatureWithObjCTypes:"d@:"]; }
@end
@interface ProbeBadInitializer : NSObject
- (id)initWithMsgType:(double)type;
@end
@implementation ProbeBadInitializer
- (id)initWithMsgType:(__unused double)type { abort(); }
@end
static SRWeChatImageSendProbe *probe(Class type, BOOL allowed, NSString *version) {
    return [[SRWeChatImageSendProbe alloc] initWithVersion:version classResolver:^Class(NSString *name) {
        CHECK([name isEqual:@"CMessageWrap"]); return type;
    } currentAccount:^NSString * { return Account; } environmentAllowed:^BOOL { return allowed; }];
}
static BOOL run(SRWeChatImageSendProbe *p, NSString *expected) {
    NSError *error = nil; BOOL result = [p inspectForAccount:@"synthetic-account" error:&error];
    CHECK([p.diagnostics[@"state"] isEqual:expected]);
    CHECK(result ? !error : error != nil);
    CHECK(![p.diagnostics.description containsString:@"synthetic-account"]);
    CHECK(![p.diagnostics.description containsString:@"private"]);
    CHECK(![p.diagnostics[@"submissionAttempted"] boolValue]);
    CHECK(![p.diagnostics[@"imageSetterInvoked"] boolValue]);
    CHECK(![p.diagnostics[@"serviceResolved"] boolValue]);
    CHECK(![p.diagnostics[@"sendingEnabled"] boolValue]);
    return result;
}
int main(void) {
    @autoreleasepool {
        SRWeChatImageSendProbe *p = probe(ProbeImageWrap.class, YES, @"8.0.79");
        CHECK([p.diagnostics[@"state"] isEqual:@"not_checked"] && Constructs == 0);
        Extension = ProbeLongImage.new;
        CHECK(run(p, @"contract_compatible_not_sent"));
        CHECK(Constructs == 1 && ExtensionReads == 1 && [p.diagnostics[@"selectedSelector"] isEqual:@"long"]);
        CHECK([p.diagnostics[@"methods"][@"initWithMsgType:"][@"arguments"] isEqual:@[@"q"]]);
        Extension = ProbeOriginImage.new;
        CHECK(run(p, @"contract_compatible_not_sent"));
        CHECK([p.diagnostics[@"selectedSelector"] isEqual:@"origin"] && ![p.diagnostics[@"longSelectorCompatible"] boolValue]);
        Extension = ProbeBadImage.new; CHECK(!run(p, @"image_setter_abi_incompatible"));
        CHECK([p.diagnostics[@"methods"][@"setImage:withData:isLongOriginImage:"][@"arguments"] isEqual:(@[@"@", @"@", @"d"])]);
        Extension = nil; CHECK(!run(p, @"extension_not_ready"));
        Extension = ProbeLongImage.class; CHECK(!run(p, @"extension_identity_rejected"));
        Extension = ProbeLongImage.new; Throw = YES;
        CHECK(!run(p, @"inspection_exception")); Throw = NO;
        SwitchAccount = YES; CHECK(!run(p, @"account_or_environment_changed")); SwitchAccount = NO; Account = @"synthetic-account";
        WrongIdentity = YES; NSUInteger reads = ExtensionReads;
        CHECK(!run(p, @"constructed_identity_rejected") && reads == ExtensionReads); WrongIdentity = NO;
        NSUInteger count = Constructs;
        CHECK(!run(probe(ProbeImageBase.class, YES, @"8.0.79"), @"extension_getter_unavailable") && Constructs == count);
        CHECK(!run(probe(ProbeBadInitializer.class, YES, @"8.0.79"), @"initializer_abi_incompatible"));
        CHECK(!run(probe(Nil, YES, @"8.0.79"), @"wrap_class_unavailable"));
        CHECK(!run(probe(ProbeImageWrap.class, NO, @"8.0.79"), @"account_or_environment_changed"));
        CHECK(!run(probe(ProbeImageWrap.class, YES, @"8.0.80"), @"unsupported_version"));
        CHECK(Constructs == count);
        Extension = ProbeLongImage.new; __weak id weakExtension = Extension;
        @autoreleasepool { CHECK(run(p, @"contract_compatible_not_sent")); }
        Extension = nil; CHECK(weakExtension == nil);
        CHECK(run(probe(ProbeImageWrap.class, YES, @"8.0.76"), @"extension_not_ready") == NO);
        puts("PASS: image contract inspection, type-3 q initializer, extension receiver, BOOL ABIs, missing getter, identity/account gates, privacy and no image write/service/send");
    }
    return 0;
}
