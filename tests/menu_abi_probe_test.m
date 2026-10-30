#import <Foundation/Foundation.h>
#import "Adapter/SRMenuABIProbe.h"
#import <objc/runtime.h>
#include <assert.h>
#include <string.h>
#include <stdio.h>
#define CHECK(...) assert((__VA_ARGS__))

static NSUInteger gCalls = 0;
static NSUInteger gResolveInstance = 0;
static NSUInteger gResolveClass = 0;
static NSUInteger gInitialize = 0;
static NSUInteger gFreshInitialize = 0;
static NSUInteger gFreshResolveInstance = 0;
static NSUInteger gFreshResolveClass = 0;

/* A second, independently created class. Its counters live apart from the first
 * one so a warmed class cannot mask a stage. Never messaged except by the probe. */
static void SRFreshInitialize(id self, SEL command) { gFreshInitialize++; (void)self; (void)command; }
static BOOL SRFreshResolveInstance(id self, SEL command, SEL selector) {
    gFreshResolveInstance++; (void)self; (void)command; (void)selector; return NO;
}
static BOOL SRFreshResolveClass(id self, SEL command, SEL selector) {
    gFreshResolveClass++; (void)self; (void)command; (void)selector; return NO;
}

/* Numeric, bounded, flushed before any assertion can abort. */
static void SRCounterStage(const char *stage) {
    fprintf(stderr, "[probe-stage] %-22s initialize=%lu resolveInstance=%lu resolveClass=%lu calls=%lu\n",
            stage, (unsigned long)gInitialize, (unsigned long)gResolveInstance,
            (unsigned long)gResolveClass, (unsigned long)gCalls);
    fflush(stderr);
}

static void SRFreshStage(const char *stage) {
    fprintf(stderr, "[probe-fresh] %-22s initialize=%lu resolveInstance=%lu resolveClass=%lu calls=%lu\n",
            stage, (unsigned long)gFreshInitialize, (unsigned long)gFreshResolveInstance,
            (unsigned long)gFreshResolveClass, (unsigned long)gCalls);
    fflush(stderr);
}

/* Which runtime primitive realizes a class?
 *
 * The production missing-method path calls object_getClass, class_copyMethodList
 * on the class and on its metaclass, class_getSuperclass, method_getName and the
 * method shape reads. Each primitive runs on its own class declared at compile
 * time: no class is allocated, registered or extended at runtime, so a ready
 * record reflects a compile-time baseline instead of dynamic class setup. Only
 * read-only runtime calls are used: no class_getInstanceMethod or
 * class_getClassMethod, no selector is sent, and no host object is created. */
static NSUInteger gPrimGetClassInitialize = 0;
static NSUInteger gPrimInstanceListInitialize = 0;
static NSUInteger gPrimSuperclassInitialize = 0;
static NSUInteger gPrimMetaListInitialize = 0;
static NSUInteger gPrimMethodShapeInitialize = 0;

/* Each class counts its own +initialize; the self check keeps an inherited
 * +initialize from being counted for a subclass. */
@interface ProbePrimGetClass : NSObject
@end
@implementation ProbePrimGetClass
+ (void)initialize { if (self == (id)objc_getClass("ProbePrimGetClass")) gPrimGetClassInitialize++; }
@end

@interface ProbePrimInstanceList : NSObject
@end
@implementation ProbePrimInstanceList
+ (void)initialize { if (self == (id)objc_getClass("ProbePrimInstanceList")) gPrimInstanceListInitialize++; }
@end

@interface ProbePrimSuperclass : NSObject
@end
@implementation ProbePrimSuperclass
+ (void)initialize { if (self == (id)objc_getClass("ProbePrimSuperclass")) gPrimSuperclassInitialize++; }
@end

@interface ProbePrimMetaList : NSObject
@end
@implementation ProbePrimMetaList
+ (void)initialize { if (self == (id)objc_getClass("ProbePrimMetaList")) gPrimMetaListInitialize++; }
@end

/* Declares a real method the shape stage can read. The method is never sent. */
@interface ProbePrimMethodShape : NSObject
- (void)setMenuItems:(id)items;
@end
@implementation ProbePrimMethodShape
+ (void)initialize { if (self == (id)objc_getClass("ProbePrimMethodShape")) gPrimMethodShapeInitialize++; }
- (void)setMenuItems:(id)items { gCalls++; (void)items; }
@end

/* Fixed labels, integers only, flushed before any assertion can abort. */
static void SRPrimitiveStage(const char *stage) {
    fprintf(stderr,
            "[probe-primitive] %-24s getClass=%lu instanceList=%lu superclass=%lu metaList=%lu methodShape=%lu\n",
            stage,
            (unsigned long)gPrimGetClassInitialize,
            (unsigned long)gPrimInstanceListInitialize,
            (unsigned long)gPrimSuperclassInitialize,
            (unsigned long)gPrimMetaListInitialize,
            (unsigned long)gPrimMethodShapeInitialize);
    fflush(stderr);
}

/* Return-value handshake experiment.
 *
 * Production receives a Class from a block: the block returns it and the caller
 * stores it in a strong local. These four dynamic classes measure that path and
 * three controls. Each has its own counter and is created inline, so no helper
 * returns a Class. A nonzero ready count marks that group's premise invalid; it
 * is recorded, the run continues, and the other groups still report. */
static NSUInteger gRetCInitialize = 0;
static NSUInteger gRetAInitialize = 0;
static NSUInteger gRetDInitialize = 0;
static NSUInteger gRetBInitialize = 0;

static Class gRetCClass = Nil;
static Class gRetAClass = Nil;
static Class gRetDClass = Nil;
static Class gRetBClass = Nil;

/* Counts +initialize per class. Compares class pointers only. */
static void SRReturnInitialize(id self, SEL command) {
    if (self == (id)gRetCClass) gRetCInitialize++;
    else if (self == (id)gRetAClass) gRetAInitialize++;
    else if (self == (id)gRetDClass) gRetDInitialize++;
    else if (self == (id)gRetBClass) gRetBInitialize++;
    (void)command;
}

static void SRReturnStage(const char *stage) {
    fprintf(stderr, "[probe-return] %-22s C=%lu A=%lu D=%lu B=%lu\n",
            stage,
            (unsigned long)gRetCInitialize,
            (unsigned long)gRetAInitialize,
            (unsigned long)gRetDInitialize,
            (unsigned long)gRetBInitialize);
    fflush(stderr);
}

/* Explicit collect versus read-only latest: the resolver must not run on init,
 * on a read, or when the stored result is serialized. */
static NSUInteger gCollectResolverCalls = 0;
static void SRCollectStage(const char *stage, NSUInteger entries) {
    fprintf(stderr, "[probe-collect] %-20s resolverCalls=%lu entries=%lu\n",
            stage, (unsigned long)gCollectResolverCalls, (unsigned long)entries);
    fflush(stderr);
}


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
    SRMenuABIProbe *probe = [[SRMenuABIProbe alloc] initWithResolver:^(NSString *name,
                                                                      __unsafe_unretained Class _Nullable * _Nonnull resolvedClass) {
        if ([name isEqual:@"MMMenuController"]) *resolvedClass = menuClass;
        else if ([name isEqual:@"MMMenuItem"]) *resolvedClass = itemClass;
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

        // The injected resolver now delivers through a non-owning out-parameter.
        // Registering a class under the candidate name lets these probes tell
        // "the resolver wrote nothing" apart from "the default lookup ran".
        Class registeredMenu = objc_allocateClassPair(NSObject.class, "MMMenuController", 0);
        CHECK(registeredMenu != Nil);
        objc_registerClassPair(registeredMenu);
        SRCounterStage("resolver-class-registered");

        SRMenuABIProbe *writeProbe = [[SRMenuABIProbe alloc] initWithResolver:^(NSString *name,
                                                                               __unsafe_unretained Class _Nullable * _Nonnull resolvedClass) {
            if ([name isEqual:@"MMMenuController"]) *resolvedClass = registeredMenu;
        }];
        SRCounterStage("resolver-write-built");
        NSArray *writeSnapshot = [writeProbe snapshot];
        SRCounterStage("resolver-write-snapshot");
        BOOL resolverWroteClass = writeSnapshot.count == 3 &&
                                  [writeSnapshot[0][@"classStatus"] isEqual:@"present"];

        SRMenuABIProbe *nilWriteProbe = [[SRMenuABIProbe alloc] initWithResolver:^(NSString *name,
                                                                                  __unsafe_unretained Class _Nullable * _Nonnull resolvedClass) {
            (void)name;
            *resolvedClass = Nil;
        }];
        NSArray *nilWriteSnapshot = [nilWriteProbe snapshot];
        BOOL resolverWroteNil = nilWriteSnapshot.count == 3 &&
                                [nilWriteSnapshot[0][@"classStatus"] isEqual:@"missing"];

        SRMenuABIProbe *silentProbe = [[SRMenuABIProbe alloc] initWithResolver:^(NSString *name,
                                                                                __unsafe_unretained Class _Nullable * _Nonnull resolvedClass) {
            (void)name;
            (void)resolvedClass;
        }];
        NSArray *silentSnapshot = [silentProbe snapshot];
        BOOL resolverWroteNothing = silentSnapshot.count == 3 &&
                                    [silentSnapshot[0][@"classStatus"] isEqual:@"missing"];

        SRMenuABIProbe *defaultProbe = [[SRMenuABIProbe alloc] initWithResolver:nil];
        NSArray *defaultSnapshot = [defaultProbe snapshot];
        BOOL defaultLookupFoundClass = defaultSnapshot.count == 3 &&
                                       [defaultSnapshot[0][@"classStatus"] isEqual:@"present"];
        SRCounterStage("resolver-probes-done");

        // Explicit collect versus read-only latest. The resolver must not run on
        // init, on a read, or when the stored result is serialized; a second
        // collect replaces the first and never accumulates history.
        gCollectResolverCalls = 0;
        SRMenuABIProbe *collectProbe = [[SRMenuABIProbe alloc] initWithResolver:^(NSString *name,
                                                                                 __unsafe_unretained Class _Nullable * _Nonnull resolvedClass) {
            gCollectResolverCalls++;
            if ([name isEqual:@"MMMenuController"]) *resolvedClass = ProbeMenuController.class;
        }];
        SRCollectStage("init", 0);
        BOOL noResolveOnInit = (collectProbe.lastSnapshot == nil && gCollectResolverCalls == 0);
        NSArray *readBeforeCollect = collectProbe.lastSnapshot;
        BOOL noResolveOnRead = (readBeforeCollect == nil && gCollectResolverCalls == 0);
        [collectProbe collect];
        NSUInteger callsAfterFirst = gCollectResolverCalls;
        SRCollectStage("collected", collectProbe.lastSnapshot.count);
        BOOL firstCollectionFixed = (collectProbe.lastSnapshot.count == 3 && callsAfterFirst == 3);
        NSArray *readAfterCollect = collectProbe.lastSnapshot;
        BOOL noResolveOnReread = (readAfterCollect.count == 3 && gCollectResolverCalls == callsAfterFirst);
        [collectProbe collect];
        BOOL secondCollectionReplaced = (collectProbe.lastSnapshot.count == 3 &&
                                         gCollectResolverCalls == callsAfterFirst * 2);
        SRCollectStage("recollected", collectProbe.lastSnapshot.count);

        SRMenuABIProbe *missingProbe = [[SRMenuABIProbe alloc] initWithResolver:^(NSString *name,
                                                                                 __unsafe_unretained Class _Nullable * _Nonnull resolvedClass) {
            (void)name;
            (void)resolvedClass;
        }];
        [missingProbe collect];
        NSDictionary *missingEntry = missingProbe.lastSnapshot.firstObject;
        BOOL missingStaysMissing = ([missingEntry[@"classStatus"] isEqual:@"missing"] &&
                                    [missingEntry[@"returnToken"] isEqual:@"unknown"] &&
                                    [missingEntry[@"argumentTokens"] count] == 0);
        NSData *missingJSON = [NSJSONSerialization dataWithJSONObject:missingProbe.lastSnapshot options:0 error:NULL];
        NSString *missingText = missingJSON ? [[NSString alloc] initWithData:missingJSON encoding:NSUTF8StringEncoding] : nil;
        BOOL missingExportsSafely = (missingText.length > 0 &&
                                     [missingText rangeOfString:@"compatible"].location == NSNotFound &&
                                     [missingText rangeOfString:@"supported"].location == NSNotFound &&
                                     [missingText rangeOfString:@"passed"].location == NSNotFound);
        SRCollectStage("missing-export", missingProbe.lastSnapshot.count);

        // A class that resolves missing methods must not be asked to. The two
        // groups below measure different paths and never share a class, so the
        // first group's control call cannot warm what the second one measures.
        //
        // These diagnostics only touch stand-ins, so each group records its
        // stages first and the zero-side-effect checks all run afterwards: a
        // non-zero count in group 1 must not stop group 2 from producing
        // evidence. Counters are never cleared, no recorded failure is dropped
        // and no check is relaxed. Broken prerequisites (class creation, method
        // installation) still abort immediately, because such a group would
        // measure nothing.
        //
        // Group 1 keeps the untouched original call as the control path:
        // EntryFor builds the resolver-backed probe, calls snapshot, then reads
        // the returned entry. A non-zero count here is only known to be
        // somewhere inside that whole call; construction, the snapshot and the
        // metadata reads are not separated, so this group cannot yet tell them
        // apart (尚不能区分).
        Class resolving = objc_getClass("ProbeResolvingController");
        CHECK(resolving != Nil);
        SRCounterStage("original-before");
        NSDictionary *resolvingEntry = EntryFor(resolving, ProbeMenuItem.class, 0);
        NSString *resolvingMethodStatus = resolvingEntry[@"methodStatus"];
        SRCounterStage("original-after");

        // Group 2 runs the decomposed construction/snapshot path on a class
        // allocated here, which was never messaged before. A non-zero count at
        // fresh-resolver-built localises to the probe construction/copy step; a
        // count that first appears at fresh-snapshot-called still mixes the
        // resolver callbacks with the method-list and type-encoding reads, so
        // neither stage identifies a single trigger mechanism by itself.
        Class fresh = objc_allocateClassPair(NSObject.class, "ProbeResolveFresh", 0);
        CHECK(fresh != Nil);
        BOOL addedInitialize = class_addMethod(object_getClass(fresh),
                                               NSSelectorFromString(@"initialize"),
                                               (IMP)SRFreshInitialize, "v@:");
        BOOL addedResolveInstance = class_addMethod(object_getClass(fresh),
                                                    NSSelectorFromString(@"resolveInstanceMethod:"),
                                                    (IMP)SRFreshResolveInstance, "B@::");
        BOOL addedResolveClass = class_addMethod(object_getClass(fresh),
                                                 NSSelectorFromString(@"resolveClassMethod:"),
                                                 (IMP)SRFreshResolveClass, "B@::");
        // An uninstalled counter would let the group pass while measuring
        // nothing, so each installation is proven before the stage runs.
        CHECK(addedInitialize);
        CHECK(addedResolveInstance);
        CHECK(addedResolveClass);
        objc_registerClassPair(fresh);
        SRFreshStage("fresh-created");
        SRFreshStage("fresh-pool-before");
        SRMenuABIProbe *freshProbe = nil;
        NSArray *freshSnapshot = nil;
        @autoreleasepool {
            freshProbe = [[SRMenuABIProbe alloc] initWithResolver:^(NSString *name,
                                                                   __unsafe_unretained Class _Nullable * _Nonnull resolvedClass) {
                if ([name isEqual:@"MMMenuController"]) *resolvedClass = fresh;
            }];
            SRFreshStage("fresh-resolver-built");
            freshSnapshot = [freshProbe snapshot];
            SRFreshStage("fresh-snapshot-called");
        }
        SRFreshStage("fresh-pool-after");
        BOOL freshMissing = freshSnapshot.count == 3 &&
                            [freshSnapshot[0][@"methodStatus"] isEqual:@"missing"];
        SRFreshStage("fresh-entry-read");

        // Primitive-by-primitive on compiled classes. Taking the Class object
        // sends no message, so a ready count above zero means the runtime had
        // already initialized that class before its primitive ran; the run then
        // fails here instead of explaining the after value as that primitive.
        Class primGetClass = objc_getClass("ProbePrimGetClass");
        CHECK(primGetClass != Nil);
        SRPrimitiveStage("getClass-ready");
        CHECK(gPrimGetClassInitialize == 0);
        SRPrimitiveStage("getClass-before");
        Class primMetaResult = object_getClass(primGetClass);
        (void)primMetaResult;
        SRPrimitiveStage("getClass-after");

        Class primInstanceList = objc_getClass("ProbePrimInstanceList");
        CHECK(primInstanceList != Nil);
        SRPrimitiveStage("instanceList-ready");
        CHECK(gPrimInstanceListInitialize == 0);
        SRPrimitiveStage("instanceList-before");
        unsigned int primInstanceCount = 0;
        Method *primInstanceMethods = class_copyMethodList(primInstanceList, &primInstanceCount);
        free(primInstanceMethods);
        SRPrimitiveStage("instanceList-after");

        Class primSuperclass = objc_getClass("ProbePrimSuperclass");
        CHECK(primSuperclass != Nil);
        SRPrimitiveStage("superclass-ready");
        CHECK(gPrimSuperclassInitialize == 0);
        SRPrimitiveStage("superclass-before");
        Class primSuperclassResult = class_getSuperclass(primSuperclass);
        (void)primSuperclassResult;
        SRPrimitiveStage("superclass-after");

        Class primMetaList = objc_getClass("ProbePrimMetaList");
        CHECK(primMetaList != Nil);
        SRPrimitiveStage("metaList-ready");
        CHECK(gPrimMetaListInitialize == 0);
        // The metaclass read and the metaclass method-list read stay separate,
        // each with its own before/after record.
        SRPrimitiveStage("metaList-getClass-before");
        Class primMetaClass = object_getClass(primMetaList);
        SRPrimitiveStage("metaList-getClass-after");
        SRPrimitiveStage("metaList-list-before");
        unsigned int primMetaCount = 0;
        Method *primMetaMethods = class_copyMethodList(primMetaClass, &primMetaCount);
        SRPrimitiveStage("metaList-list-after");
        free(primMetaMethods);

        Class primMethodShape = objc_getClass("ProbePrimMethodShape");
        CHECK(primMethodShape != Nil);
        SRPrimitiveStage("methodShape-ready");
        CHECK(gPrimMethodShapeInitialize == 0);

        // A Method can only be had from the method list, so this class records
        // the list, the name scan and each shape read separately: if the list
        // stage already realizes the class, the reads after it cannot be
        // separated from that realization and the records say so.
        SRPrimitiveStage("methodShape-before");
        unsigned int primShapeCount = 0;
        Method *primShapeMethods = class_copyMethodList(primMethodShape, &primShapeCount);
        SRPrimitiveStage("methodShape-list");
        // An empty list would let every shape read be skipped while the final
        // zero-count checks still pass, so an empty list is a broken premise.
        CHECK(primShapeCount > 0);
        Method primShapeMethod = NULL;
        for (unsigned int index = 0; index < primShapeCount; index++) {
            if (method_getName(primShapeMethods[index]) == NSSelectorFromString(@"setMenuItems:")) {
                primShapeMethod = primShapeMethods[index];
                break;
            }
        }
        SRPrimitiveStage("methodShape-name");
        // Without the real method the three reads below would measure nothing.
        CHECK(primShapeMethod != NULL);
        unsigned int primShapeArguments = method_getNumberOfArguments(primShapeMethod);
        SRPrimitiveStage("methodShape-argcount");
        // self, _cmd and at least one declared argument, so the last argument
        // index passed to method_copyArgumentType must exist.
        CHECK(primShapeArguments >= 3);
        char *primShapeReturn = method_copyReturnType(primShapeMethod);
        free(primShapeReturn);
        SRPrimitiveStage("methodShape-returntype");
        char *primShapeArgument = method_copyArgumentType(primShapeMethod, primShapeArguments - 1);
        free(primShapeArgument);
        SRPrimitiveStage("methodShape-argtype");
        free(primShapeMethods);
        SRPrimitiveStage("methodShape-done");

        // C: creation control. Nothing is returned and nothing is read, so any
        // count recorded here means class creation alone polluted this group.
        Class retC = objc_allocateClassPair(NSObject.class, "ProbeReturnC", 0);
        CHECK(retC != Nil);
        gRetCClass = retC;
        BOOL retCCounterAdded = class_addMethod(object_getClass(retC),
                                                NSSelectorFromString(@"initialize"),
                                                (IMP)SRReturnInitialize, "v@:");
        CHECK(retCCounterAdded);
        objc_registerClassPair(retC);
        SRReturnStage("C-ready");
        if (gRetCInitialize != 0) SRReturnStage("C-ready-invalid");
        @autoreleasepool {
            SRReturnStage("C-scope-before");
            (void)retC;
            SRReturnStage("C-scope-after");
        }
        SRReturnStage("C-done");

        // A: the production shape. A Class-returning block is copied, then
        // called and stored in a strong Class local, as entryForClassName: does.
        Class retA = objc_allocateClassPair(NSObject.class, "ProbeReturnA", 0);
        CHECK(retA != Nil);
        gRetAClass = retA;
        BOOL retACounterAdded = class_addMethod(object_getClass(retA),
                                                NSSelectorFromString(@"initialize"),
                                                (IMP)SRReturnInitialize, "v@:");
        CHECK(retACounterAdded);
        objc_registerClassPair(retA);
        SRReturnStage("A-ready");
        if (gRetAInitialize != 0) SRReturnStage("A-ready-invalid");
        Class retAReceived = Nil;
        SRReturnStage("A-pool-before");
        @autoreleasepool {
            Class (^returnClass)(void) = ^Class(void) { return retA; };
            SRReturnStage("A-block-built");
            Class (^copiedReturn)(void) = [returnClass copy];
            SRReturnStage("A-block-copied");
            SRReturnStage("A-before-call");
            retAReceived = copiedReturn();
            SRReturnStage("A-after-call");
        }
        SRReturnStage("A-pool-after");
        BOOL retAReceivedIsClass = (retAReceived == retA);
        SRReturnStage("A-done");

        // D: delivery without a Class return. A void block writes the Class into
        // an explicitly non-owning out-parameter; nothing returns a Class.
        Class retD = objc_allocateClassPair(NSObject.class, "ProbeReturnD", 0);
        CHECK(retD != Nil);
        gRetDClass = retD;
        BOOL retDCounterAdded = class_addMethod(object_getClass(retD),
                                                NSSelectorFromString(@"initialize"),
                                                (IMP)SRReturnInitialize, "v@:");
        CHECK(retDCounterAdded);
        objc_registerClassPair(retD);
        SRReturnStage("D-ready");
        if (gRetDInitialize != 0) SRReturnStage("D-ready-invalid");
        __unsafe_unretained Class retDReceived = Nil;
        SRReturnStage("D-pool-before");
        @autoreleasepool {
            void (^deliverClass)(__unsafe_unretained Class *) =
                ^(__unsafe_unretained Class *out) { *out = retD; };
            SRReturnStage("D-block-built");
            void (^copiedDeliver)(__unsafe_unretained Class *) = [deliverClass copy];
            SRReturnStage("D-block-copied");
            SRReturnStage("D-before-call");
            copiedDeliver(&retDReceived);
            SRReturnStage("D-after-call");
        }
        SRReturnStage("D-pool-after");
        BOOL retDReceivedIsClass = (retDReceived == retD);
        SRReturnStage("D-done");

        // B: a metadata read with no Class return anywhere on the path.
        Class retB = objc_allocateClassPair(NSObject.class, "ProbeReturnB", 0);
        CHECK(retB != Nil);
        gRetBClass = retB;
        BOOL retBCounterAdded = class_addMethod(object_getClass(retB),
                                                NSSelectorFromString(@"initialize"),
                                                (IMP)SRReturnInitialize, "v@:");
        CHECK(retBCounterAdded);
        objc_registerClassPair(retB);
        SRReturnStage("B-ready");
        if (gRetBInitialize != 0) SRReturnStage("B-ready-invalid");
        unsigned int retBMethodCount = 0;
        Method *retBMethods = class_copyMethodList(retB, &retBMethodCount);
        free(retBMethods);
        SRReturnStage("B-after");
        @autoreleasepool {
            SRReturnStage("B-scope-before");
            SRReturnStage("B-scope-after");
        }
        SRReturnStage("B-done");

        // Both groups, every primitive and every return-path stage have recorded
        // their values. Run the deferred checks now, unchanged in strength.
        SRCounterStage("original-assert");
        SRFreshStage("fresh-assert");
        SRPrimitiveStage("primitive-assert");
        SRReturnStage("return-assert");
        SRCounterStage("resolver-assert");
        CHECK(resolverWroteClass);
        CHECK(resolverWroteNil);
        CHECK(resolverWroteNothing);
        CHECK(defaultLookupFoundClass);
        SRCollectStage("assert", collectProbe.lastSnapshot.count);
        CHECK(noResolveOnInit);
        CHECK(noResolveOnRead);
        CHECK(firstCollectionFixed);
        CHECK(noResolveOnReread);
        CHECK(secondCollectionReplaced);
        CHECK(missingStaysMissing);
        CHECK(missingExportsSafely);
        CHECK(retAReceivedIsClass);
        CHECK(retDReceivedIsClass);
        CHECK(gInitialize == 0 && gResolveInstance == 0 && gResolveClass == 0);
        CHECK(gFreshInitialize == 0 && gFreshResolveInstance == 0 && gFreshResolveClass == 0);
        CHECK(gPrimGetClassInitialize == 0);
        CHECK(gPrimInstanceListInitialize == 0);
        CHECK(gPrimSuperclassInitialize == 0);
        CHECK(gPrimMetaListInitialize == 0);
        CHECK(gPrimMethodShapeInitialize == 0);
        CHECK([resolvingMethodStatus isEqual:@"missing"]);
        CHECK(freshMissing);
        SRFreshStage("fresh-done");

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
