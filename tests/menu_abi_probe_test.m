#import <Foundation/Foundation.h>
#import "Adapter/SRMenuABIProbe.h"
#import <objc/runtime.h>
#include <assert.h>
#include <string.h>
#define CHECK(...) assert((__VA_ARGS__))

static NSUInteger gCalls = 0;
static NSUInteger gResolveInstance = 0;
static NSUInteger gResolveClass = 0;
static NSUInteger gInitialize = 0;

/* Every stand-in counts its own invocations: the probe must never call them. */
@interface ProbeMenuController : NSObject
- (void)setMenuItems:(NSArray *)items;
- (void)onMenuItemSelected:(id)item itemView:(id)view;
@end
@implementation ProbeMenuController
- (void)setMenuItems:(NSArray *)items { gCalls++; (void)items; }
- (void)onMenuItemSelected:(id)item itemView:(id)view { gCalls++; (void)item; (void)view; }
@end

@interface ProbeMenuItem : NSObject
- (instancetype)initWithTitle:(id)title icon:(id)icon target:(id)target action:(SEL)action;
@end
@implementation ProbeMenuItem
- (instancetype)initWithTitle:(id)title icon:(id)icon target:(id)target action:(SEL)action {
    gCalls++; self = [super init]; (void)title; (void)icon; (void)target; (void)action; return self;
}
@end

@interface ProbePartialController : NSObject
- (void)setMenuItems:(NSArray *)items;
@end
@implementation ProbePartialController
- (void)setMenuItems:(NSArray *)items { gCalls++; (void)items; }
@end

@interface ProbeBaseController : NSObject
- (void)setMenuItems:(NSArray *)items;
@end
@implementation ProbeBaseController
- (void)setMenuItems:(NSArray *)items { gCalls++; (void)items; }
@end
@interface ProbeSubController : ProbeBaseController
@end
@implementation ProbeSubController
@end

@interface ProbeClassOnlyController : NSObject
+ (void)setMenuItems:(NSArray *)items;
@end
@implementation ProbeClassOnlyController
+ (void)setMenuItems:(NSArray *)items { gCalls++; (void)items; }
@end

/* A class that would answer a missing method by resolving one. Looking the
 * method up must not run any of this. */
@interface ProbeResolvingController : NSObject
@end
@implementation ProbeResolvingController
+ (BOOL)resolveInstanceMethod:(SEL)selector { gResolveInstance++; (void)selector; return NO; }
+ (BOOL)resolveClassMethod:(SEL)selector { gResolveClass++; (void)selector; return NO; }
+ (void)initialize { if (self == (id)objc_getClass("ProbeResolvingController")) gInitialize++; }
@end

@interface ProbeInt32Arg : NSObject
- (void)setMenuItems:(int)items;
@end
@implementation ProbeInt32Arg
- (void)setMenuItems:(int)items { gCalls++; (void)items; }
@end

@interface ProbeLongArg : NSObject
- (void)setMenuItems:(long)items;
@end
@implementation ProbeLongArg
- (void)setMenuItems:(long)items { gCalls++; (void)items; }
@end

@interface ProbeULongArg : NSObject
- (void)setMenuItems:(unsigned long)items;
@end
@implementation ProbeULongArg
- (void)setMenuItems:(unsigned long)items { gCalls++; (void)items; }
@end

@interface ProbeLongLongArg : NSObject
- (void)setMenuItems:(long long)items;
@end
@implementation ProbeLongLongArg
- (void)setMenuItems:(long long)items { gCalls++; (void)items; }
@end

@interface ProbeULongLongArg : NSObject
- (void)setMenuItems:(unsigned long long)items;
@end
@implementation ProbeULongLongArg
- (void)setMenuItems:(unsigned long long)items { gCalls++; (void)items; }
@end

@interface ProbeBoolArg : NSObject
- (void)setMenuItems:(bool)items;
@end
@implementation ProbeBoolArg
- (void)setMenuItems:(bool)items { gCalls++; (void)items; }
@end

@interface ProbeSCharArg : NSObject
- (void)setMenuItems:(signed char)items;
@end
@implementation ProbeSCharArg
- (void)setMenuItems:(signed char)items { gCalls++; (void)items; }
@end

@interface ProbeSELArg : NSObject
- (void)setMenuItems:(SEL)items;
@end
@implementation ProbeSELArg
- (void)setMenuItems:(SEL)items { gCalls++; (void)items; }
@end

@interface ProbeBlockArg : NSObject
- (void)setMenuItems:(void (^)(void))items;
@end
@implementation ProbeBlockArg
- (void)setMenuItems:(void (^)(void))items { gCalls++; (void)items; }
@end

@interface ProbePointerArg : NSObject
- (void)setMenuItems:(NSArray **)items;
@end
@implementation ProbePointerArg
- (void)setMenuItems:(NSArray **)items { gCalls++; (void)items; }
@end

@interface ProbeStructArg : NSObject
- (void)setMenuItems:(CGRect)items;
@end
@implementation ProbeStructArg
- (void)setMenuItems:(CGRect)items { gCalls++; (void)items; }
@end

/* Never executed: only the declared encoding of the wide method is read. */
static void SRProbeNeverCalled(id self, SEL command, id argument) {
    gCalls++; (void)self; (void)command; (void)argument;
}

/* Register a method with an explicit Objective-C type encoding. This keeps the
 * l/L probe independent from the host compiler's native long width: on LP64,
 * a C `long` is encoded as q, while the ABI still has distinct l/L tokens. */
static Class RegisterEncodedSetter(const char *name, const char *encoding) {
    Class cls = objc_allocateClassPair(NSObject.class, name, 0);
    assert(cls != Nil);
    BOOL added = class_addMethod(cls, NSSelectorFromString(@"setMenuItems:"),
                                 (IMP)SRProbeNeverCalled, encoding);
    assert(added);
    objc_registerClassPair(cls);
    return cls;
}

static NSArray *Whitelist(void) {
    return @[@"void", @"object", @"block", @"SEL", @"bool", @"char", @"uchar", @"int16", @"uint16",
             @"int32", @"uint32", @"long", @"ulong", @"int64", @"uint64", @"pointer", @"unknown"];
}

static NSDictionary *EntryFor(Class menuClass, Class itemClass, NSUInteger index) {
    SRMenuABIProbe *probe = [[SRMenuABIProbe alloc] initWithResolver:^Class(NSString *name) {
        if ([name isEqual:@"MMMenuController"]) return menuClass;
        if ([name isEqual:@"MMMenuItem"]) return itemClass;
        return (Class)nil;
    }];
    NSArray *snapshot = probe.snapshot;
    CHECK(snapshot.count == 3);
    CHECK([snapshot[0][@"candidate"] isEqual:@"MMMenuController / setMenuItems:"]);
    CHECK([snapshot[1][@"candidate"] isEqual:@"MMMenuController / onMenuItemSelected:itemView:"]);
    CHECK([snapshot[2][@"candidate"] isEqual:@"MMMenuItem / initWithTitle:icon:target:action:"]);
    NSSet *keys = [NSSet setWithArray:@[@"candidate", @"classStatus", @"methodStatus",
                                        @"argumentCount", @"returnToken", @"argumentTokens"]];
    NSArray *allowed = Whitelist();
    for (NSDictionary *entry in snapshot) {
        CHECK([[NSSet setWithArray:entry.allKeys] isEqualToSet:keys]);
        CHECK([allowed containsObject:entry[@"returnToken"]]);
        for (NSString *token in entry[@"argumentTokens"]) CHECK([allowed containsObject:token]);
        CHECK([entry[@"argumentTokens"] count] <= 8);
    }
    return snapshot[index];
}

int main(void) {
    @autoreleasepool {
        CHECK(gCalls == 0);

        NSDictionary *setter = EntryFor(ProbeMenuController.class, ProbeMenuItem.class, 0);
        CHECK([setter[@"classStatus"] isEqual:@"present"]);
        CHECK([setter[@"methodStatus"] isEqual:@"direct"]);
        CHECK([setter[@"argumentCount"] isEqual:@"3"]);
        CHECK([setter[@"returnToken"] isEqual:@"void"]);
        CHECK([setter[@"argumentTokens"] isEqualToArray:(@[@"object", @"SEL", @"object"])]);
        NSDictionary *selection = EntryFor(ProbeMenuController.class, ProbeMenuItem.class, 1);
        CHECK([selection[@"argumentTokens"] isEqualToArray:(@[@"object", @"SEL", @"object", @"object"])]);
        NSDictionary *initializer = EntryFor(ProbeMenuController.class, ProbeMenuItem.class, 2);
        CHECK([initializer[@"argumentCount"] isEqual:@"6"]);
        CHECK([initializer[@"returnToken"] isEqual:@"object"]);
        CHECK([initializer[@"argumentTokens"] isEqualToArray:
            (@[@"object", @"SEL", @"object", @"object", @"object", @"SEL"])]);

        CHECK([EntryFor(nil, ProbeMenuItem.class, 0)[@"classStatus"] isEqual:@"missing"]);
        NSDictionary *partial = EntryFor(ProbePartialController.class, ProbeMenuItem.class, 1);
        CHECK([partial[@"classStatus"] isEqual:@"present"]);
        CHECK([partial[@"methodStatus"] isEqual:@"missing"]);
        CHECK([EntryFor(ProbeClassOnlyController.class, ProbeMenuItem.class, 0)[@"methodStatus"] isEqual:@"class_only"]);
        CHECK([EntryFor(ProbeSubController.class, ProbeMenuItem.class, 0)[@"methodStatus"] isEqual:@"inherited"]);

        // A class that resolves missing methods must not be asked to.
        Class resolving = objc_getClass("ProbeResolvingController");
        CHECK(resolving != Nil);
        CHECK(gInitialize == 0 && gResolveInstance == 0 && gResolveClass == 0);
        NSDictionary *unresolved = EntryFor(resolving, ProbeMenuItem.class, 0);
        CHECK([unresolved[@"methodStatus"] isEqual:@"missing"]);
        CHECK(gInitialize == 0 && gResolveInstance == 0 && gResolveClass == 0);

        // Integer width and signedness stay distinct; c is not BOOL. C long's
        // encoding is platform-defined, so derive its expected token from the
        // compiler encoding while testing raw l/L independently below.
        CHECK([EntryFor(ProbeInt32Arg.class, ProbeMenuItem.class, 0)[@"argumentTokens"] isEqualToArray:(@[@"object", @"SEL", @"int32"])]);
        // @encode yields a C string, so compare with strcmp instead of messaging it.
        const char *longEncoding = @encode(long);
        const char *unsignedLongEncoding = @encode(unsigned long);
        CHECK(strcmp(longEncoding, "l") == 0 || strcmp(longEncoding, "q") == 0);
        CHECK(strcmp(unsignedLongEncoding, "L") == 0 || strcmp(unsignedLongEncoding, "Q") == 0);
        NSString *longToken = strcmp(longEncoding, "l") == 0 ? @"long" : @"int64";
        NSString *unsignedLongToken = strcmp(unsignedLongEncoding, "L") == 0 ? @"ulong" : @"uint64";
        CHECK([EntryFor(ProbeLongArg.class, ProbeMenuItem.class, 0)[@"argumentTokens"] isEqualToArray:(@[@"object", @"SEL", longToken])]);
        CHECK([EntryFor(ProbeULongArg.class, ProbeMenuItem.class, 0)[@"argumentTokens"] isEqualToArray:(@[@"object", @"SEL", unsignedLongToken])]);
        Class rawLong = RegisterEncodedSetter("ProbeRawLongArg", "v24@0:8l16");
        Class rawULong = RegisterEncodedSetter("ProbeRawULongArg", "v24@0:8L16");
        CHECK([EntryFor(rawLong, ProbeMenuItem.class, 0)[@"argumentTokens"] isEqualToArray:(@[@"object", @"SEL", @"long"])]);
        CHECK([EntryFor(rawULong, ProbeMenuItem.class, 0)[@"argumentTokens"] isEqualToArray:(@[@"object", @"SEL", @"ulong"])]);
        CHECK([EntryFor(ProbeLongLongArg.class, ProbeMenuItem.class, 0)[@"argumentTokens"] isEqualToArray:(@[@"object", @"SEL", @"int64"])]);
        CHECK([EntryFor(ProbeULongLongArg.class, ProbeMenuItem.class, 0)[@"argumentTokens"] isEqualToArray:(@[@"object", @"SEL", @"uint64"])]);
        CHECK([EntryFor(ProbeBoolArg.class, ProbeMenuItem.class, 0)[@"argumentTokens"][2] isEqual:@"bool"]);
        CHECK([EntryFor(ProbeSCharArg.class, ProbeMenuItem.class, 0)[@"argumentTokens"][2] isEqual:@"char"]);
        CHECK([EntryFor(ProbeSELArg.class, ProbeMenuItem.class, 0)[@"argumentTokens"][2] isEqual:@"SEL"]);
        CHECK([EntryFor(ProbeBlockArg.class, ProbeMenuItem.class, 0)[@"argumentTokens"][2] isEqual:@"block"]);
        CHECK([EntryFor(ProbePointerArg.class, ProbeMenuItem.class, 0)[@"argumentTokens"][2] isEqual:@"pointer"]);
        CHECK([EntryFor(ProbeStructArg.class, ProbeMenuItem.class, 0)[@"argumentTokens"][2] isEqual:@"unknown"]);

        // Wrong implicit self / _cmd are reported as their real tokens.
        Class badSelf = objc_allocateClassPair(NSObject.class, "ProbeBadSelf", 0);
        class_addMethod(badSelf, NSSelectorFromString(@"setMenuItems:"), (IMP)SRProbeNeverCalled, "v24q0:8@16");
        objc_registerClassPair(badSelf);
        CHECK([EntryFor(badSelf, ProbeMenuItem.class, 0)[@"argumentTokens"] isEqualToArray:(@[@"int64", @"SEL", @"object"])]);
        Class badCommand = objc_allocateClassPair(NSObject.class, "ProbeBadCommand", 0);
        class_addMethod(badCommand, NSSelectorFromString(@"setMenuItems:"), (IMP)SRProbeNeverCalled, "v24@0q8@16");
        objc_registerClassPair(badCommand);
        CHECK([EntryFor(badCommand, ProbeMenuItem.class, 0)[@"argumentTokens"] isEqualToArray:(@[@"object", @"int64", @"object"])]);

        // Over the ceiling: reported, arguments not walked.
        Class wide = objc_allocateClassPair(NSObject.class, "ProbeWideController", 0);
        class_addMethod(wide, NSSelectorFromString(@"setMenuItems:"), (IMP)SRProbeNeverCalled, "v@:@@@@@@@@@");
        objc_registerClassPair(wide);
        NSDictionary *wideEntry = EntryFor(wide, ProbeMenuItem.class, 0);
        CHECK([wideEntry[@"argumentCount"] isEqual:@"over_limit"]);
        CHECK([wideEntry[@"argumentTokens"] count] == 0);

        CHECK(gCalls == 0);
        CHECK(gResolveInstance == 0 && gResolveClass == 0 && gInitialize == 0);
        puts("PASS: the ABI probe reads existing method lists only, reports fixed bounded tokens, "
             "and never resolves, calls or constructs anything");
    }
    return 0;
}
