#import <Foundation/Foundation.h>
#import "Adapter/SRMessageMenuHook.h"
#import "Core/SRStore.h"
#import "Core/SREntryPreferences.h"
#import "Core/SRLibraryIntake.h"
#import <objc/runtime.h>
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

/* Host-shaped stand-ins. The gate's expected types are fixed in the adapter,
 * not read back from the methods under test. */
@interface SRFakeMenuController : NSObject
- (void)setMenuItems:(NSArray *)items;
- (void)onMenuItemSelected:(id)item itemView:(id)view;
@end
@implementation SRFakeMenuController
- (void)setMenuItems:(NSArray *)items { (void)items; }
- (void)onMenuItemSelected:(id)item itemView:(id)view { (void)item; (void)view; }
@end

@interface SRFakeMenuItem : NSObject
@property(nonatomic, strong) id target;
@property(nonatomic) SEL action;
- (instancetype)initWithTitle:(id)title icon:(id)icon target:(id)target action:(SEL)action;
@end
/* 0 = self, 1 = nil, 2 = replacement object, for the whole fixture class. */
static NSInteger gMenuItemInitMode = 0;
@interface SRFakeMenuItemSubclass : SRFakeMenuItem
@end
@implementation SRFakeMenuItemSubclass
@end
@implementation SRFakeMenuItem
- (instancetype)initWithTitle:(id)title icon:(id)icon target:(id)target action:(SEL)action {
    self = [super init];
    (void)title; (void)icon;
    if (gMenuItemInitMode == 1) return nil;
    if (gMenuItemInitMode == 2) return (id)[SRFakeMenuItemSubclass new];
    if (gMenuItemInitMode == 3) return (id)[NSObject new];
    _target = target; _action = action;
    return self;
}
@end
/* Host-style dispatch: the host sends target/action with the item view as the
 * sender, never the item itself. */
static void SRDispatchMenuAction(id item, id sender) {
    // Only a published menu item may provide the dispatch channel; a fixture
    // without target/action is a broken test input, not a silent no-op.
    CHECK([item respondsToSelector:@selector(target)]);
    CHECK([item respondsToSelector:@selector(action)]);
    id target = [item target];
    SEL action = [item action];
    CHECK(target != nil && action != NULL);
    IMP imp = [target methodForSelector:action];
    CHECK(imp != NULL);
    ((void (*)(id, SEL, id))imp)(target, action, sender);
}

@interface SRIncompleteMenuController : NSObject
- (void)setMenuItems:(NSArray *)items;
@end
@implementation SRIncompleteMenuController
- (void)setMenuItems:(NSArray *)items { (void)items; }
@end

/* Same argument counts, deliberately wrong classes. */
@interface SRClassMethodOnlyController : NSObject
+ (void)setMenuItems:(NSArray *)items;
+ (void)onMenuItemSelected:(id)item itemView:(id)view;
@end
@implementation SRClassMethodOnlyController
+ (void)setMenuItems:(NSArray *)items { (void)items; }
+ (void)onMenuItemSelected:(id)item itemView:(id)view { (void)item; (void)view; }
@end

@interface SRWrongReturnController : NSObject
- (BOOL)setMenuItems:(NSArray *)items;
- (void)onMenuItemSelected:(id)item itemView:(id)view;
@end
@implementation SRWrongReturnController
- (BOOL)setMenuItems:(NSArray *)items { (void)items; return YES; }
- (void)onMenuItemSelected:(id)item itemView:(id)view { (void)item; (void)view; }
@end

@interface SRSELArgumentController : NSObject
- (void)setMenuItems:(SEL)items;
- (void)onMenuItemSelected:(id)item itemView:(id)view;
@end
@implementation SRSELArgumentController
- (void)setMenuItems:(SEL)items { (void)items; }
- (void)onMenuItemSelected:(id)item itemView:(id)view { (void)item; (void)view; }
@end

@interface SRBlockArgumentController : NSObject
- (void)setMenuItems:(void (^)(void))items;
- (void)onMenuItemSelected:(id)item itemView:(id)view;
@end
@implementation SRBlockArgumentController
- (void)setMenuItems:(void (^)(void))items { (void)items; }
- (void)onMenuItemSelected:(id)item itemView:(id)view { (void)item; (void)view; }
@end

@interface SRIntegerArgumentController : NSObject
- (void)setMenuItems:(NSInteger)items;
- (void)onMenuItemSelected:(id)item itemView:(id)view;
@end
@implementation SRIntegerArgumentController
- (void)setMenuItems:(NSInteger)items { (void)items; }
- (void)onMenuItemSelected:(id)item itemView:(id)view { (void)item; (void)view; }
@end

/* initializer whose last parameter is an object instead of a SEL. */
@interface SRObjectActionItem : NSObject
- (instancetype)initWithTitle:(id)title icon:(id)icon target:(id)target action:(id)action;
@end
@implementation SRObjectActionItem
- (instancetype)initWithTitle:(id)title icon:(id)icon target:(id)target action:(id)action {
    self = [super init]; (void)title; (void)icon; (void)target; (void)action; return self;
}
@end

/* initializer whose third parameter is a pointer instead of an object. */
@interface SRPointerArgumentItem : NSObject
- (instancetype)initWithTitle:(id)title icon:(id)icon target:(NSArray **)target action:(SEL)action;
@end
@implementation SRPointerArgumentItem
- (instancetype)initWithTitle:(id)title icon:(id)icon target:(NSArray **)target action:(SEL)action {
    self = [super init]; (void)title; (void)icon; (void)target; (void)action; return self;
}
@end


/* Methods registered only for metadata: fabricated encodings whose implicit
 * parameters are wrong while the argument count and explicit types stay right.
 * They are never called. */
static void SRNeverCalled3(id self, SEL command, id argument) {
    (void)self; (void)command; (void)argument;
}
static void SRNeverCalled4(id self, SEL command, id first, id second) {
    (void)self; (void)command; (void)first; (void)second;
}

/* Selection with a wrong return type or a wrong explicit parameter. */
@interface SRSelectionBadReturn : NSObject
- (void)setMenuItems:(NSArray *)items;
- (BOOL)onMenuItemSelected:(id)item itemView:(id)view;
@end
@implementation SRSelectionBadReturn
- (void)setMenuItems:(NSArray *)items { (void)items; }
- (BOOL)onMenuItemSelected:(id)item itemView:(id)view { (void)item; (void)view; return YES; }
@end

@interface SRSelectionSELArgument : NSObject
- (void)setMenuItems:(NSArray *)items;
- (void)onMenuItemSelected:(SEL)item itemView:(id)view;
@end
@implementation SRSelectionSELArgument
- (void)setMenuItems:(NSArray *)items { (void)items; }
- (void)onMenuItemSelected:(SEL)item itemView:(id)view { (void)item; (void)view; }
@end

@interface SRSelectionBlockArgument : NSObject
- (void)setMenuItems:(NSArray *)items;
- (void)onMenuItemSelected:(void (^)(void))item itemView:(id)view;
@end
@implementation SRSelectionBlockArgument
- (void)setMenuItems:(NSArray *)items { (void)items; }
- (void)onMenuItemSelected:(void (^)(void))item itemView:(id)view { (void)item; (void)view; }
@end

@interface SRSelectionIntegerArgument : NSObject
- (void)setMenuItems:(NSArray *)items;
- (void)onMenuItemSelected:(id)item itemView:(NSInteger)view;
@end
@implementation SRSelectionIntegerArgument
- (void)setMenuItems:(NSArray *)items { (void)items; }
- (void)onMenuItemSelected:(id)item itemView:(NSInteger)view { (void)item; (void)view; }
@end

@interface SRForeignItem : NSObject
@property(nonatomic, copy) NSString *title;
@end
@implementation SRForeignItem
@end

/* --- observation-only menu call observer fixtures ----------------------- */
static NSUInteger gResponderGetterCalls = 0;
@interface SRObservedMenu : NSObject
@property(nonatomic, strong) id responder;
@property(nonatomic) NSUInteger setCalls;
@property(nonatomic) NSUInteger selectCalls;
@property(nonatomic) BOOL raiseOnSet;
@property(nonatomic, strong) NSArray *lastItems;
@property(nonatomic, strong) id lastItem;
@property(nonatomic, strong) id lastView;
- (void)observeAction:(id)item;
@end
@implementation SRObservedMenu
@synthesize responder = _responder;
- (id)responder { gResponderGetterCalls++; return _responder; }
- (void)setMenuItems:(NSArray *)items {
    self.setCalls++;
    self.lastItems = items;
    if (self.raiseOnSet) @throw [NSException exceptionWithName:@"SRTestHost" reason:@"host" userInfo:nil];
}
- (void)onMenuItemSelected:(id)item itemView:(id)view {
    self.selectCalls++; self.lastItem = item; self.lastView = view;
}
- (void)observeAction:(id)item { (void)item; }
@end

/* Declares the three handler getters the observer may read after ABI checks. */
static NSUInteger gTargetGetterCalls = 0;
static NSUInteger gActionGetterCalls = 0;
static NSUInteger gBlockGetterCalls = 0;
@interface SRObservedItem : NSObject
@property(nonatomic, strong) id handlerTarget;
@property(nonatomic) SEL handlerAction;
@property(nonatomic, copy) void (^handlerBlock)(void);
@property(nonatomic) BOOL raiseOnHandlerTarget;
@property(nonatomic, copy) void (^targetGetterHook)(void);
- (instancetype)initWithTitle:(id)title icon:(id)icon target:(id)target action:(SEL)action;
- (id)target;
- (SEL)action;
- (void (^)(void))actionBlock;
@end
/* The original implementation's behaviour is switched here so the init-family
 * ownership cases can all use the one allowed class pair. 0 = self,
 * 1 = nil, 2 = replacement object. */
static NSInteger gItemInitMode = 0;
@implementation SRObservedItem
- (id)target {
    gTargetGetterCalls++;
    if (self.targetGetterHook) self.targetGetterHook();
    if (self.raiseOnHandlerTarget) {
        @throw [NSException exceptionWithName:@"SRTestGetter" reason:@"target" userInfo:nil];
    }
    return self.handlerTarget;
}
- (SEL)action { gActionGetterCalls++; return self.handlerAction; }
- (void (^)(void))actionBlock { gBlockGetterCalls++; return self.handlerBlock; }
- (instancetype)initWithTitle:(id)title icon:(id)icon target:(id)target action:(SEL)action {
    (void)title; (void)icon; (void)target; (void)action;
    if (gItemInitMode == 1) return nil;
    if (gItemInitMode == 2) return (id)[NSObject new];
    self = [super init];
    return self;
}
@end

/* Inherits all three candidate methods: not a direct declaration, so the
 * observer must refuse rather than replace a superclass IMP. */
@interface SRInheritedMenuController : SRFakeMenuController
@end
@implementation SRInheritedMenuController
@end

/* Distinct objects that compare equal and share a hash. The observer's weak set
 * must use pointer identity and never call -hash / -isEqual. */
static NSUInteger gTwinHashCalls = 0;
static NSUInteger gTwinEqualCalls = 0;
@interface SRTwinItem : NSObject
@end
@implementation SRTwinItem
- (NSUInteger)hash { gTwinHashCalls++; return 4242; }
- (BOOL)isEqual:(id)object { gTwinEqualCalls++; return [object isKindOfClass:SRTwinItem.class]; }
@end

/* A legal NSArray subclass that reenters the observer while it is enumerated. */
@interface SRReentrantArray : NSArray
@property(nonatomic, copy) void (^onAccess)(void);
@property(nonatomic, strong) NSArray *storage;
@property(nonatomic) BOOL fired;
@end
@implementation SRReentrantArray
- (NSUInteger)count { [self fireOnce]; return self.storage.count; }
- (id)objectAtIndex:(NSUInteger)index { [self fireOnce]; return self.storage[index]; }
- (void)fireOnce {
    if (self.fired) return;
    self.fired = YES;
    if (self.onAccess) self.onAccess();
}
@end

/* Counts every host-container access, so a refused build can be proven not to
 * have read the container at all. `onAccess` fires once, on the first read. */
static NSUInteger gArrayCountCalls = 0;
static NSUInteger gArrayIndexCalls = 0;
@interface SRCountingArray : NSArray
@property(nonatomic, strong) NSArray *storage;
@property(nonatomic, copy) void (^onAccess)(void);
@property(nonatomic) BOOL fired;
@end
@implementation SRCountingArray
- (NSUInteger)count {
    gArrayCountCalls++;
    if (!self.fired && self.onAccess) { self.fired = YES; self.onAccess(); }
    return self.storage.count;
}
- (id)objectAtIndex:(NSUInteger)index { gArrayIndexCalls++; return self.storage[index]; }
@end

/* Fails while being read; the host call must still run exactly once. */
@interface SRThrowingArray : NSArray
@property(nonatomic, strong) NSArray *storage;
@end
@implementation SRThrowingArray
- (NSUInteger)count { @throw [NSException exceptionWithName:@"SRTestArray" reason:@"read" userInfo:nil]; }
- (id)objectAtIndex:(NSUInteger)index { (void)index; return nil; }
@end

/* Declares its action, so the signature is read from a real method list. */
static NSUInteger gOtherActionCalls = 0;
@interface SRSecondaryTarget : NSObject
- (void)otherAction:(id)sender;
@end
@implementation SRSecondaryTarget
- (void)otherAction:(__unused id)sender { gOtherActionCalls++; }
@end

/* Must never be asked to resolve: the observer reads declared methods only. */
static NSUInteger gResolverCalls = 0;
@interface SRUnresolvedTarget : NSObject
@end
@implementation SRUnresolvedTarget
+ (BOOL)resolveInstanceMethod:(__unused SEL)selector { gResolverCalls++; return NO; }
@end

/* Wrong getter shapes: none of these may be called, and none may wake the
 * runtime resolver. */
static NSUInteger gWrongTargetCalls = 0;
static NSUInteger gWrongActionCalls = 0;
static NSUInteger gWrongBlockCalls = 0;
static NSUInteger gWrongResponderCalls = 0;
static NSUInteger gWrongABIResolverCalls = 0;
@interface SRWrongABIItem : NSObject
@end
@implementation SRWrongABIItem
+ (BOOL)resolveInstanceMethod:(__unused SEL)selector { gWrongABIResolverCalls++; return NO; }
- (int)target { gWrongTargetCalls++; return 7; }
- (void)action { gWrongActionCalls++; }
- (id)actionBlock { gWrongBlockCalls++; return [NSObject new]; }
@end
@interface SRWrongABIReceiver : NSObject
@end
@implementation SRWrongABIReceiver
- (int)responder { gWrongResponderCalls++; return 9; }
@end
@interface SRResponderABIItem : NSObject
@end
@implementation SRResponderABIItem
- (id)target { return nil; }
- (SEL)action { return @selector(otherAction:); }
- (void (^)(void))actionBlock { return nil; }
@end
@interface SRNoGetterItem : NSObject
@end
@implementation SRNoGetterItem
@end
@interface SRMenuCallObserver (SRTestSeam)
+ (NSDictionary *)inspectHandlerGettersForItem:(id)item receiver:(id)receiver;
@end

/* Host-shaped source chain: menu.responder -> cover.delegate -> cell -> wrap. */
@interface SRHostMenu : NSObject
@property(nonatomic, strong) id responder;
@end
@implementation SRHostMenu
@end
@interface SRHostCoverView : NSObject
@property(nonatomic, strong) id delegate;
@end
@implementation SRHostCoverView
@end
@interface SRHostMessageCell : NSObject
@property(nonatomic, strong) id currentWrap;
- (id)getCurrentMessageWrap;
@end
@implementation SRHostMessageCell
- (id)getCurrentMessageWrap { return self.currentWrap; }
@end
@interface SRHostWrap : NSObject
@property(nonatomic) unsigned long long m_uiMesLocalID;
@property(nonatomic) unsigned int m_uiMessageType;
@property(nonatomic) unsigned long long m_uiCreateTime;
@property(nonatomic, copy) NSString *m_nsFromUsr;
@property(nonatomic, copy) NSString *m_nsToUsr;
@property(nonatomic, copy) NSString *m_nsContent;
@end
@implementation SRHostWrap
@end
/* Wrong ABI: the local id getter returns an object instead of an integer. */
@interface SRHostBadWrap : NSObject
@property(nonatomic, strong) id m_uiMesLocalID;
@property(nonatomic) unsigned int m_uiMessageType;
@property(nonatomic) unsigned long long m_uiCreateTime;
@property(nonatomic, copy) NSString *m_nsFromUsr;
@property(nonatomic, copy) NSString *m_nsToUsr;
@property(nonatomic, copy) NSString *m_nsContent;
@end
@implementation SRHostBadWrap
@end
static id gReadbackWrap = nil;
@interface SRThrowingLookupProxy : NSProxy
@end
@implementation SRThrowingLookupProxy
- (instancetype)init { return self; }
- (BOOL)respondsToSelector:(__unused SEL)selector {
    @throw [NSException exceptionWithName:@"SRTestProxy" reason:@"lookup" userInfo:nil];
}
- (NSMethodSignature *)methodSignatureForSelector:(__unused SEL)selector { return nil; }
@end
static NSUInteger gConflictCalls = 0;
@interface SRConflictingLookup : NSObject
- (id)GetMsg:(id)session LocalID:(unsigned int)localID;
@end
@implementation SRConflictingLookup
- (id)GetMsg:(__unused id)session LocalID:(__unused unsigned int)localID { gConflictCalls++; return nil; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (selector == NSSelectorFromString(@"GetMsg:LocalID:")) {
        // Declared I, reflected Q: both valid integer shapes, but they differ.
        return [NSMethodSignature signatureWithObjCTypes:"@@:@Q"];
    }
    return [super methodSignatureForSelector:selector];
}
@end
@interface SRFakeLookupProxy : NSProxy
@property(nonatomic, strong) id target;
@end
@implementation SRFakeLookupProxy
- (instancetype)init { return self; }
- (BOOL)respondsToSelector:(SEL)selector { return [self.target respondsToSelector:selector]; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector { return [self.target methodSignatureForSelector:selector]; }
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:self.target]; }
@end
static NSUInteger gReadbackCalls = 0;
static id gReadbackSession = nil;
static unsigned long long gReadbackLocalID = 0;
@interface SRFakeMessageManager : NSObject
- (id)GetMsg:(id)session LocalID:(unsigned long long)localID;
@end
@implementation SRFakeMessageManager
- (id)GetMsg:(id)session LocalID:(unsigned long long)localID {
    gReadbackCalls++; gReadbackSession = session; gReadbackLocalID = localID;
    return gReadbackWrap;
}
@end
@interface SRFakeMenuItemView : NSObject
@property(nonatomic, strong) id menuItem;
@end
@implementation SRFakeMenuItemView
@end
@interface SRMessageMenuHook (SRTestAction)
- (void)srMenuAction:(id)sender;
@end

/* Production build interposer fixtures. */
static NSUInteger gBuildSetCalls = 0;
static IMP gBuildForeignNext;
static void SRBuildForeignHook(id self, SEL command, id items) {
    if (gBuildForeignNext) ((void (*)(id, SEL, id))gBuildForeignNext)(self, command, items);
}
@interface SRMenuBuildHook (SRTestPublish)
- (id)publishItems:(id)items menu:(id)menu;
@property(nonatomic) NSTimeInterval reuseWindow;
@end

@interface SRBuildMenuController : NSObject
@property(nonatomic, strong) id responder;
@property(nonatomic, strong) NSArray *lastItems;
@property(nonatomic, strong) NSArray *currentMenuItems;
@property(nonatomic) NSUInteger showCalls;
- (void)setMenuItems:(NSArray *)items;
- (void)setMenuVisible:(BOOL)visible responder:(id)responder animated:(BOOL)animated;
@end
@implementation SRBuildMenuController
- (void)setMenuItems:(NSArray *)items { gBuildSetCalls++; self.lastItems = items; self.currentMenuItems = items; }
- (void)setMenuVisible:(__unused BOOL)visible responder:(__unused id)responder animated:(__unused BOOL)animated {
    self.showCalls++;
}
@end

/* A later hook installed on top of the observer's trampoline. */
static NSUInteger gExternalHookCalls = 0;
static IMP gExternalHookNext;
static void SRTestExternalHook(id self, SEL command, id items) {
    gExternalHookCalls++;
    if (gExternalHookNext) ((void (*)(id, SEL, id))gExternalHookNext)(self, command, items);
}

static NSDictionary *context(NSString *account, NSString *body, NSString *identity) {
    NSMutableDictionary *value = [NSMutableDictionary dictionary];
    value[@"account"] = account; value[@"body"] = body; value[@"identity"] = identity;
    return value;
}

static NSString *gHelperBody = @"body";
static SRMenuMessageContext *makeContext(NSString *account, NSString *body, NSString *identity, NSString *key) {
    gHelperBody = [body copy];
    return [[SRMenuMessageContext alloc] initWithAccount:account body:body generation:@"g1"
        ownerToken:@"owner-1" messageIdentity:identity session:@"chat" messageType:@"1"
        createdAt:@"1000" epoch:@"0" operationKey:key];
}
static SRMenuMessageContext *makeContextFull(NSString *account, NSString *body, NSString *identity,
                                             NSString *key, NSString *session, NSString *type,
                                             NSString *created) {
    return [[SRMenuMessageContext alloc] initWithAccount:account body:body generation:@"g1"
        ownerToken:@"owner-1" messageIdentity:identity session:session messageType:type
        createdAt:created epoch:@"0" operationKey:key];
}

static SRMenuCurrentIdentity *currentIdentity(NSString *account, NSString *owner,
                                               NSString *generation, NSString *message) {
    return [[SRMenuCurrentIdentity alloc] initWithAccount:account ownerToken:owner
        generation:generation messageIdentity:message session:@"chat" messageType:@"1"
        createdAt:@"1000" epoch:@"0" body:gHelperBody];
}
static SRMenuCurrentIdentity *currentIdentityFull(NSString *account, NSString *owner, NSString *generation,
                                                  NSString *message, NSString *session, NSString *type,
                                                  NSString *created, NSString *body) {
    return [[SRMenuCurrentIdentity alloc] initWithAccount:account ownerToken:owner
        generation:generation messageIdentity:message session:session messageType:type
        createdAt:created epoch:@"0" body:body];
}

int main(void) {
    @autoreleasepool {
        (void)context;  // kept for readability of the fixtures above
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *path = [directory stringByAppendingPathComponent:@"menu.sqlite3"];
        SRStore *store = [[SRStore alloc] initWithPath:path error:NULL]; CHECK(store);
        SRLibraryIntake *intake = [SRLibraryIntake intakeForStore:store];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"andyz.syncrelay.menutest"];
        [defaults removePersistentDomainForName:@"andyz.syncrelay.menutest"];
        SREntryPreferences *preferences = [[SREntryPreferences alloc] initWithDefaults:defaults];
        __block NSString *account = @"account";

        // The preference is off by default and persists.
        CHECK(!preferences.libraryMenuEntryEnabled);

        SRMessageMenuHook *hook = [[SRMessageMenuHook alloc] initWithIntake:intake
            currentAccount:^NSString *{ return account; }
            accountActive:^BOOL(NSString *value) { return [value isEqual:account]; }
            enabled:^BOOL { return preferences.libraryMenuEntryEnabled; }];
        __block unsigned long long menuEpoch = 0;
        [hook configureEpochProvider:^{ return menuEpoch; }];

        // --- gate ---
        CHECK([hook gateMenuClass:SRFakeMenuController.class itemClass:SRFakeMenuItem.class] == SRMenuGateMatched);
        CHECK([hook gateMenuClass:nil itemClass:SRFakeMenuItem.class] == SRMenuGateClassMissing);
        CHECK([hook gateMenuClass:SRIncompleteMenuController.class itemClass:SRFakeMenuItem.class] == SRMenuGateMethodMissing);
        CHECK([hook gateMenuClass:SRClassMethodOnlyController.class itemClass:SRFakeMenuItem.class] == SRMenuGateMethodMissing);
        // Same argument counts, wrong classes: each one must be refused.
        CHECK([hook gateMenuClass:SRWrongReturnController.class itemClass:SRFakeMenuItem.class] == SRMenuGateEncodingMismatch);
        CHECK([hook gateMenuClass:SRSELArgumentController.class itemClass:SRFakeMenuItem.class] == SRMenuGateEncodingMismatch);
        CHECK([hook gateMenuClass:SRBlockArgumentController.class itemClass:SRFakeMenuItem.class] == SRMenuGateEncodingMismatch);
        CHECK([hook gateMenuClass:SRIntegerArgumentController.class itemClass:SRFakeMenuItem.class] == SRMenuGateEncodingMismatch);
        CHECK([hook gateMenuClass:SRFakeMenuController.class itemClass:SRObjectActionItem.class] == SRMenuGateEncodingMismatch);
        CHECK([hook gateMenuClass:SRFakeMenuController.class itemClass:SRPointerArgumentItem.class] == SRMenuGateEncodingMismatch);
                CHECK([hook gateMenuClass:SRSelectionBadReturn.class itemClass:SRFakeMenuItem.class] == SRMenuGateEncodingMismatch);
        CHECK([hook gateMenuClass:SRSelectionSELArgument.class itemClass:SRFakeMenuItem.class] == SRMenuGateEncodingMismatch);
        CHECK([hook gateMenuClass:SRSelectionBlockArgument.class itemClass:SRFakeMenuItem.class] == SRMenuGateEncodingMismatch);
        CHECK([hook gateMenuClass:SRSelectionIntegerArgument.class itemClass:SRFakeMenuItem.class] == SRMenuGateEncodingMismatch);
        // Implicit self / _cmd fabricated on a throwaway class.
        Class badSelf = objc_allocateClassPair(NSObject.class, "SRBadSelfMenuController", 0);
        class_addMethod(badSelf, NSSelectorFromString(@"setMenuItems:"), (IMP)SRNeverCalled3, "v24q0:8@16");
        class_addMethod(badSelf, NSSelectorFromString(@"onMenuItemSelected:itemView:"), (IMP)SRNeverCalled4, "v32@0:8@16@24");
        objc_registerClassPair(badSelf);
        CHECK([hook gateMenuClass:badSelf itemClass:SRFakeMenuItem.class] == SRMenuGateEncodingMismatch);
        Class badCommand = objc_allocateClassPair(NSObject.class, "SRBadCommandMenuController", 0);
        class_addMethod(badCommand, NSSelectorFromString(@"setMenuItems:"), (IMP)SRNeverCalled3, "v24@0q8@16");
        class_addMethod(badCommand, NSSelectorFromString(@"onMenuItemSelected:itemView:"), (IMP)SRNeverCalled4, "v32@0:8@16@24");
        objc_registerClassPair(badCommand);
        CHECK([hook gateMenuClass:badCommand itemClass:SRFakeMenuItem.class] == SRMenuGateEncodingMismatch);
        SRForeignItem *foreign = [SRForeignItem new]; foreign.title = @"SR 入库";
        NSArray *base = @[foreign];

        // --- switch off: nothing is appended, the host array is untouched ---
        NSArray *offAppend = [hook appendOwnItemToItems:base generation:@"g0"
            source:makeContext(@"account", @"关时正文", @"msg-0", @"op-0")];
        CHECK(offAppend.count == 1 && offAppend[0] == foreign);

        // --- switch on: exactly one own item, foreign kept first ---
        preferences.libraryMenuEntryEnabled = YES;
        NSArray *first = [hook appendOwnItemToItems:base generation:@"g1"
            source:makeContext(@"account", @"完整正文一", @"msg-1", @"op-1")];
        CHECK(first.count == 2 && first[0] == foreign);
        NSArray *again = [hook appendOwnItemToItems:first generation:@"g1"
            source:makeContext(@"account", @"完整正文一", @"msg-1", @"op-1")];
        CHECK(again.count == 2);
        CHECK(![hook ownsItem:foreign]);
        CHECK([hook ownsItem:first.lastObject]);
        CHECK([hook handleSelection:foreign current:currentIdentity(@"account", @"owner-1", @"g1", @"msg-0")]  == SRMenuIntentNotOurs);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == 0);

        // --- switch off again: an item already on screen refuses ---
        preferences.libraryMenuEntryEnabled = NO;
        CHECK([hook handleSelection:first.lastObject current:currentIdentity(@"account", @"owner-1", @"g1", @"msg-1")]  == SRMenuIntentDisabled);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == 0);
        preferences.libraryMenuEntryEnabled = YES;

        // --- identity re-checks ---
        CHECK([hook handleSelection:first.lastObject current:currentIdentity(@"account", @"owner-1", @"g2", @"msg-1")]  == SRMenuIntentContextStale);
        CHECK([hook handleSelection:first.lastObject current:currentIdentity(@"other", @"owner-1", @"g1", @"msg-1")]  == SRMenuIntentContextStale);
        account = @"other";
        CHECK([hook handleSelection:first.lastObject current:currentIdentity(@"other", @"owner-1", @"g1", @"msg-1")]  == SRMenuIntentContextStale);
        // Even a matching current identity is stale if the live account
        // changed after the menu was built.
        CHECK([hook handleSelection:first.lastObject current:currentIdentity(@"account", @"owner-1", @"g1", @"msg-1")] == SRMenuIntentContextStale);
        account = @"account";
        CHECK([hook handleSelection:first.lastObject current:currentIdentity(@"account", @"wrong-owner", @"g1", @"msg-1")] == SRMenuIntentContextStale);
        CHECK([hook handleSelection:first.lastObject current:currentIdentity(@"account", @"owner-1", @"g1", @"wrong-message")] == SRMenuIntentContextStale);
        CHECK([hook handleSelection:first.lastObject current:nil] == SRMenuIntentContextStale);
        CHECK([hook handleSelection:first.lastObject current:currentIdentity(@"account", @"owner-1", @"g1", @"")] == SRMenuIntentContextStale);

        // --- one save per operation ---
        CHECK([hook handleSelection:first.lastObject current:currentIdentity(@"account", @"owner-1", @"g1", @"msg-1")]  == SRMenuIntentSaved);
        CHECK([hook handleSelection:first.lastObject current:currentIdentity(@"account", @"owner-1", @"g1", @"msg-1")]  == SRMenuIntentDuplicate);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == 1);

        // --- a new generation invalidates the old item (cell reuse) ---
        NSArray *second = [hook appendOwnItemToItems:first generation:@"g2"
            source:makeContext(@"account", @"另一条正文", @"msg-2", @"op-2")];
        CHECK(second.count == 2 && second[0] == foreign);
        CHECK([hook ownsItem:first.lastObject]);
        CHECK([hook handleSelection:first.lastObject current:currentIdentity(@"account", @"owner-1", @"g2", @"msg-1")]  == SRMenuIntentContextStale);

        // If the host rebuilds the same generation from foreign items only,
        // append one replacement. The omitted old item remains ours but is no
        // longer the active click target.
        NSArray *rebuilt = [hook appendOwnItemToItems:@[foreign] generation:@"g2"
            source:makeContext(@"account", @"另一条正文", @"msg-2", @"op-2")];
        CHECK(rebuilt.count == 2 && rebuilt[0] == foreign && rebuilt.lastObject != second.lastObject);
        CHECK([hook ownsItem:second.lastObject]);
        CHECK([hook handleSelection:second.lastObject current:currentIdentity(@"account", @"owner-1", @"g2", @"msg-2")] == SRMenuIntentContextStale);
        NSArray *withStaleDuplicate = @[foreign, second.lastObject, rebuilt.lastObject];
        NSArray *normalized = [hook appendOwnItemToItems:withStaleDuplicate generation:@"g2"
            source:makeContext(@"account", @"另一条正文", @"msg-2", @"op-2")];
        CHECK(normalized.count == 2 && normalized[0] == foreign && normalized.lastObject == rebuilt.lastObject);

        // Same body, different message: a separate operation and entry.
        NSArray *third = [hook appendOwnItemToItems:rebuilt generation:@"g3"
            source:makeContext(@"account", @"完整正文一", @"msg-3", @"op-3")];
        CHECK([hook handleSelection:third.lastObject current:currentIdentity(@"account", @"owner-1", @"g3", @"msg-3")]  == SRMenuIntentSaved);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == 2);

        // --- host source chain and the real host item path ---
        SRHostMenu *hostMenu = [SRHostMenu new];
        SRHostCoverView *cover = [SRHostCoverView new];
        SRHostMessageCell *cell = [SRHostMessageCell new];
        SRHostWrap *wrap = [SRHostWrap new];
        wrap.m_uiMesLocalID = 42;
        wrap.m_uiMessageType = 1;
        wrap.m_uiCreateTime = 1000;
        wrap.m_nsFromUsr = @"chat@chatroom";
        wrap.m_nsToUsr = @"account";
        wrap.m_nsContent = @"宿主正文";
        cell.currentWrap = wrap;
        cover.delegate = cell;
        hostMenu.responder = cover;
        [hook configureHostClasses:SRHostMenu.class coverClass:SRHostCoverView.class cellClass:SRHostMessageCell.class];
        SRFakeMessageManager *readbackManager = [SRFakeMessageManager new];
        [hook configureReadbackProvider:^{ return readbackManager; }];
        gReadbackWrap = wrap;

        SRMenuHostSource *source = [SRMenuHostSource sourceForMenu:hostMenu menuClass:SRHostMenu.class
                                                       coverClass:SRHostCoverView.class cellClass:SRHostMessageCell.class account:@"account"];
        CHECK(source != nil);
        CHECK([source.messageIdentity isEqual:@"local:42"]);
        CHECK(source.localID == 42);
        CHECK(source.isText && [source.body isEqual:@"宿主正文"]);
        CHECK([source.session isEqual:@"chat@chatroom"]);   // incoming: from is the session
        wrap.m_nsFromUsr = @"account";                    // outgoing: to is the session
        wrap.m_nsToUsr = @"chat@chatroom";
        SRMenuHostSource *outgoing = [SRMenuHostSource sourceForMenu:hostMenu menuClass:SRHostMenu.class
                                                          coverClass:SRHostCoverView.class
                                                           cellClass:SRHostMessageCell.class account:@"account"];
        CHECK(outgoing != nil && [outgoing.session isEqual:@"chat@chatroom"]);
        wrap.m_nsFromUsr = @"someone@chatroom";           // neither side is the current account
        wrap.m_nsToUsr = @"other";
        CHECK([SRMenuHostSource sourceForMenu:hostMenu menuClass:SRHostMenu.class coverClass:SRHostCoverView.class
                                    cellClass:SRHostMessageCell.class account:@"account"] == nil);
        wrap.m_nsFromUsr = @"chat@chatroom";
        wrap.m_nsToUsr = @"account";
        // Every gate refuses on its own; nothing falls back to a recent message.
        CHECK([SRMenuHostSource sourceForMenu:hostMenu menuClass:SRForeignItem.class coverClass:SRHostCoverView.class cellClass:SRHostMessageCell.class account:@"account"] == nil);
        CHECK([SRMenuHostSource sourceForMenu:hostMenu menuClass:SRHostMenu.class coverClass:SRForeignItem.class cellClass:SRHostMessageCell.class account:@"account"] == nil);
        CHECK([SRMenuHostSource sourceForMenu:hostMenu menuClass:SRHostMenu.class coverClass:SRHostCoverView.class cellClass:SRForeignItem.class account:@"account"] == nil);
        SRHostCoverView *bareCover = [SRHostCoverView new];
        hostMenu.responder = bareCover;
        CHECK([SRMenuHostSource sourceForMenu:hostMenu menuClass:SRHostMenu.class coverClass:SRHostCoverView.class cellClass:SRHostMessageCell.class account:@"account"] == nil);
        hostMenu.responder = cover;
        cell.currentWrap = nil;
        CHECK([SRMenuHostSource sourceForMenu:hostMenu menuClass:SRHostMenu.class coverClass:SRHostCoverView.class cellClass:SRHostMessageCell.class account:@"account"] == nil);
        SRHostBadWrap *badWrap = [SRHostBadWrap new];
        badWrap.m_uiMesLocalID = @"not-a-number";
        badWrap.m_uiMessageType = 1;
        badWrap.m_uiCreateTime = 1000;
        badWrap.m_nsFromUsr = @"chat@chatroom";
        badWrap.m_nsToUsr = @"account";
        badWrap.m_nsContent = @"x";
        cell.currentWrap = badWrap;
        CHECK([SRMenuHostSource sourceForMenu:hostMenu menuClass:SRHostMenu.class coverClass:SRHostCoverView.class cellClass:SRHostMessageCell.class account:@"account"] == nil);
        cell.currentWrap = wrap;
        wrap.m_nsContent = @"";
        CHECK([SRMenuHostSource sourceForMenu:hostMenu menuClass:SRHostMenu.class coverClass:SRHostCoverView.class cellClass:SRHostMessageCell.class account:@"account"] == nil);
        wrap.m_nsContent = @"宿主正文";
        wrap.m_uiMesLocalID = 0;
        CHECK([SRMenuHostSource sourceForMenu:hostMenu menuClass:SRHostMenu.class coverClass:SRHostCoverView.class cellClass:SRHostMessageCell.class account:@"account"] == nil);
        wrap.m_uiMesLocalID = 42;
        wrap.m_uiMessageType = 49;
        SRMenuHostSource *nonText = [SRMenuHostSource sourceForMenu:hostMenu menuClass:SRHostMenu.class
                                                        coverClass:SRHostCoverView.class cellClass:SRHostMessageCell.class account:@"account"];
        CHECK(nonText != nil && !nonText.isText);
        wrap.m_uiMessageType = 1;

        SRMenuMessageContext *hostContext = [hook contextForMenu:hostMenu generation:@"g9"];
        CHECK(hostContext != nil && [hostContext.messageIdentity isEqual:@"local:42"]);
        CHECK([hook contextForMenu:nil generation:@"g9"] == nil);
        NSArray *hostItems = [hook appendHostItemToItems:@[foreign] menu:hostMenu source:hostContext
                                               itemClass:SRFakeMenuItem.class generation:@"g9"];
        CHECK(hostItems.count == 2 && hostItems[0] == foreign);
        CHECK([hook ownsItem:hostItems.lastObject]);
        // A wrong item ABI refuses the append instead of building something else.
        CHECK([hook appendHostItemToItems:@[foreign] menu:hostMenu source:hostContext itemClass:NSObject.class generation:@"g9"].count == 1);

        SRFakeMenuItemView *itemView = [SRFakeMenuItemView new];
        NSUInteger savedBeforeHostClick = [[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count];
        __block NSUInteger hostGeneration = 0;
        void (^rebuild)(void) = ^{
            hostGeneration++;
            NSString *gen = [NSString stringWithFormat:@"host-%lu", (unsigned long)hostGeneration];
            NSArray *items = [hook appendHostItemToItems:@[foreign] menu:hostMenu
                source:[hook contextForMenu:hostMenu generation:gen]
                itemClass:SRFakeMenuItem.class generation:gen];
            itemView.menuItem = items.lastObject;
        };
        // Every rejection uses a fresh, unsaved operation and changes one field.

        // 1) the clicked menu now resolves to a different local id.
        rebuild();
        wrap.m_uiMesLocalID = 99;
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick);
        wrap.m_uiMesLocalID = 42;

        // 2) readback returns the same id/body but a different session.
        SRHostWrap *sameIdOtherSession = [SRHostWrap new];
        sameIdOtherSession.m_uiMesLocalID = 42;
        sameIdOtherSession.m_uiMessageType = 1;
        sameIdOtherSession.m_uiCreateTime = 1000;
        sameIdOtherSession.m_nsFromUsr = @"account";
        sameIdOtherSession.m_nsToUsr = @"another@chatroom";
        sameIdOtherSession.m_nsContent = @"宿主正文";
        gReadbackWrap = sameIdOtherSession;
        rebuild();
        gReadbackCalls = 0;
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK(gReadbackCalls >= 1);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick);

        // 3) same id/body, different message type.
        SRHostWrap *sameIdOtherType = [SRHostWrap new];
        sameIdOtherType.m_uiMesLocalID = 42;
        sameIdOtherType.m_uiMessageType = 49;
        sameIdOtherType.m_uiCreateTime = 1000;
        sameIdOtherType.m_nsFromUsr = @"chat@chatroom";
        sameIdOtherType.m_nsToUsr = @"account";
        sameIdOtherType.m_nsContent = @"宿主正文";
        gReadbackWrap = sameIdOtherType;
        rebuild();
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick);

        // 4) same id/body, different creation time.
        SRHostWrap *sameIdOtherTime = [SRHostWrap new];
        sameIdOtherTime.m_uiMesLocalID = 42;
        sameIdOtherTime.m_uiMessageType = 1;
        sameIdOtherTime.m_uiCreateTime = 2000;
        sameIdOtherTime.m_nsFromUsr = @"chat@chatroom";
        sameIdOtherTime.m_nsToUsr = @"account";
        sameIdOtherTime.m_nsContent = @"宿主正文";
        gReadbackWrap = sameIdOtherTime;
        rebuild();
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick);
        gReadbackWrap = wrap;

        // 5) account changed after the menu was built.
        rebuild();
        account = @"other";
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick);
        account = @"account";

        // 6) switch off refuses an item already on screen.
        rebuild();
        preferences.libraryMenuEntryEnabled = NO;
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick);
        preferences.libraryMenuEntryEnabled = YES;

        // 7) a sender carrying a foreign item is refused by the entry itself:
        // dispatch through our own published item, not the foreign one.
        SRFakeMenuItemView *foreignView = [SRFakeMenuItemView new];
        foreignView.menuItem = foreign;
        CHECK([hook ownsItem:itemView.menuItem]);
        CHECK(![hook ownsItem:foreignView.menuItem]);
        gReadbackCalls = 0;
        SRDispatchMenuAction(itemView.menuItem, foreignView);
        CHECK(gReadbackCalls == 0);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick);

        // 8) receiver epoch changed after the menu was built.
        rebuild();
        menuEpoch = 2;
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick);
        menuEpoch = 0;

        // 9) the normal path saves once, and a repeat is a duplicate.
        rebuild();
        gReadbackCalls = 0;
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK(gReadbackCalls >= 1);
        CHECK([gReadbackSession isEqual:@"chat@chatroom"]);
        CHECK(gReadbackLocalID == 42);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick + 1);
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick + 1);

        // A forwarding proxy is a valid lookup service; a class object and a
        // plain object are refused before any readback.
        SRFakeLookupProxy *serviceProxy = [[SRFakeLookupProxy alloc] init];
        serviceProxy.target = readbackManager;
        [hook configureReadbackProvider:^{ return serviceProxy; }];
        rebuild();
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick + 2);
        // A proxy query that throws is refused, not propagated to the host.
        [hook configureReadbackProvider:^{ return [[SRThrowingLookupProxy alloc] init]; }];
        rebuild();
        gReadbackCalls = 0;
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK(gReadbackCalls == 0);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick + 2);
        // A declaration that conflicts with the reflected signature is refused.
        gConflictCalls = 0;
        [hook configureReadbackProvider:^{ return [SRConflictingLookup new]; }];
        rebuild();
        gReadbackCalls = 0;
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK(gReadbackCalls == 0);
        CHECK(gConflictCalls == 0);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick + 2);
        [hook configureReadbackProvider:^{ return (id)SRFakeMessageManager.class; }];
        rebuild();
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick + 2);
        [hook configureReadbackProvider:^{ return [NSObject new]; }];
        rebuild();
        SRDispatchMenuAction(itemView.menuItem, itemView);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == savedBeforeHostClick + 2);
        [hook configureReadbackProvider:^{ return readbackManager; }];

        // Missing epoch provider and the unavailable token are refused, while a
        // real initial 0 stays valid (covered by the success cases above).
        SRMessageMenuHook *noEpochHook = [[SRMessageMenuHook alloc] initWithIntake:intake
            currentAccount:^NSString * { return @"account"; }
            accountActive:^BOOL(NSString *value) { return [value isEqual:@"account"]; }
            enabled:^BOOL { return YES; }];
        NSArray *noEpochItems = [noEpochHook appendOwnItemToItems:@[] generation:@"g1"
            source:makeContext(@"account", @"body", @"msg-ne", @"op-ne")];
        CHECK([noEpochHook handleSelection:noEpochItems.lastObject
            current:currentIdentity(@"account", @"owner-1", @"g1", @"msg-ne")] == SRMenuIntentContextStale);
        SRMessageMenuHook *unavailableHook = [[SRMessageMenuHook alloc] initWithIntake:intake
            currentAccount:^NSString * { return @"account"; }
            accountActive:^BOOL(NSString *value) { return [value isEqual:@"account"]; }
            enabled:^BOOL { return YES; }];
        [unavailableHook configureHostClasses:SRHostMenu.class coverClass:SRHostCoverView.class
                                    cellClass:SRHostMessageCell.class];
        __block NSUInteger epochReads = 0;
        __block unsigned long long unavailableEpoch = 0;
        [unavailableHook configureEpochProvider:^unsigned long long { epochReads++; return unavailableEpoch; }];
        CHECK([unavailableHook contextForMenu:hostMenu generation:@"g1"] != nil);   // 0 is a real token
        NSUInteger readsBefore = epochReads;
        unavailableEpoch = ULLONG_MAX;
        CHECK([unavailableHook contextForMenu:hostMenu generation:@"g1"] == nil);
        CHECK(epochReads > readsBefore);

        // A menu rebuilt from inside the account callback invalidates the click.
        __block SRMessageMenuHook *reentrantHook = nil;
        __block BOOL rebuiltOnce = NO;
        reentrantHook = [[SRMessageMenuHook alloc] initWithIntake:intake
            currentAccount:^NSString * {
                if (!rebuiltOnce) {
                    rebuiltOnce = YES;
                    [reentrantHook appendOwnItemToItems:@[] generation:@"g1"
                        source:makeContext(@"account", @"body", @"msg-other", @"op-other")];
                }
                return @"account";
            }
            accountActive:^BOOL(NSString *value) { return [value isEqual:@"account"]; }
            enabled:^BOOL { return YES; }];
        [reentrantHook configureEpochProvider:^unsigned long long { return 0; }];
        NSArray *reentrantItems = [reentrantHook appendOwnItemToItems:@[] generation:@"g1"
            source:makeContext(@"account", @"body", @"msg-main", @"op-main")];
        CHECK([reentrantHook handleSelection:reentrantItems.lastObject
            current:currentIdentity(@"account", @"owner-1", @"g1", @"msg-main")] == SRMenuIntentContextStale);

        // Turning the switch off from inside the callback also refuses.
        __block BOOL switchOn = YES;
        SRMessageMenuHook *disableHook = [[SRMessageMenuHook alloc] initWithIntake:intake
            currentAccount:^NSString * { switchOn = NO; return @"account"; }
            accountActive:^BOOL(NSString *value) { return [value isEqual:@"account"]; }
            enabled:^BOOL { return switchOn; }];
        [disableHook configureEpochProvider:^unsigned long long { return 0; }];
        NSArray *disableItems = [disableHook appendOwnItemToItems:@[] generation:@"g1"
            source:makeContext(@"account", @"body", @"msg-off", @"op-off")];
        CHECK([disableHook handleSelection:disableItems.lastObject
            current:currentIdentity(@"account", @"owner-1", @"g1", @"msg-off")] == SRMenuIntentDisabled);

        // Message body/session/type/time are part of the frozen identity.
        SRMenuMessageContext *strictContext = makeContextFull(@"account", @"body", @"msg-strict", @"op-strict",
                                                              @"chat", @"1", @"1000");
        NSArray *strictItems = [hook appendOwnItemToItems:@[] generation:@"g1" source:strictContext];
        CHECK(strictItems.count == 1);
        CHECK([hook handleSelection:strictItems.lastObject
            current:currentIdentityFull(@"account", @"owner-1", @"g1", @"msg-strict", @"chat", @"1", @"1000", @"body")] == SRMenuIntentSaved);
        CHECK([hook handleSelection:strictItems.lastObject
            current:currentIdentityFull(@"account", @"owner-1", @"g1", @"msg-strict", @"chat", @"1", @"1000", @"different")] == SRMenuIntentContextStale);
        CHECK([hook handleSelection:strictItems.lastObject
            current:currentIdentityFull(@"account", @"owner-1", @"g1", @"msg-strict", @"otherchat", @"1", @"1000", @"body")] == SRMenuIntentContextStale);
        CHECK([hook handleSelection:strictItems.lastObject
            current:currentIdentityFull(@"account", @"owner-1", @"g1", @"msg-strict", @"chat", @"49", @"1000", @"body")] == SRMenuIntentContextStale);
        CHECK([hook handleSelection:strictItems.lastObject
            current:currentIdentityFull(@"account", @"owner-1", @"g1", @"msg-strict", @"chat", @"1", @"2000", @"body")] == SRMenuIntentContextStale);

        // A KVO subclass of the menu class is still the same host class.
        Class kvoMenuClass = objc_allocateClassPair(SRHostMenu.class, "NSKVONotifying_SRHostMenu", 0);
        objc_registerClassPair(kvoMenuClass);
        SRHostMenu *kvoMenu = [[kvoMenuClass alloc] init];
        kvoMenu.responder = cover;
        CHECK([SRMenuHostSource sourceForMenu:kvoMenu menuClass:SRHostMenu.class coverClass:SRHostCoverView.class
                                    cellClass:SRHostMessageCell.class account:@"account"] != nil);

        // The click-time generation comes from the menu, not the active item.
        NSArray *regenerated = [hook appendHostItemToItems:@[foreign] menu:hostMenu
            source:[hook contextForMenu:hostMenu generation:@"g9"] itemClass:SRFakeMenuItem.class generation:@"g9"];
        CHECK(regenerated.count == 2 && [hook ownsItem:regenerated.lastObject]);
        SRFakeMenuItemView *regeneratedView = [SRFakeMenuItemView new];
        regeneratedView.menuItem = regenerated.lastObject;
        CHECK([hook contextForMenu:hostMenu generation:@"g10"] != nil);
        NSUInteger beforeStaleGeneration = [[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count];
        SRDispatchMenuAction(regeneratedView.menuItem, regeneratedView);
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == beforeStaleGeneration);

        // --- item initializer ownership: self / nil / replacement ---
        gMenuItemInitMode = 1;   // init returns nil: nothing may be appended
        NSArray *nilAppend = [hook appendHostItemToItems:@[foreign] menu:hostMenu source:hostContext
                                               itemClass:SRFakeMenuItem.class generation:@"g11"];
        CHECK(nilAppend.count == 1 && nilAppend[0] == foreign);
        gMenuItemInitMode = 2;   // init replaces the receiver with a compatible item
        NSArray *replacedAppend = [hook appendHostItemToItems:@[foreign] menu:hostMenu source:hostContext
                                                    itemClass:SRFakeMenuItem.class generation:@"g11"];
        CHECK(replacedAppend.count == 2 && [hook ownsItem:replacedAppend.lastObject]);
        CHECK([replacedAppend.lastObject isKindOfClass:SRFakeMenuItem.class]);
        gMenuItemInitMode = 3;   // incompatible replacement: refused, nothing published
        NSArray *incompatible = [hook appendHostItemToItems:@[foreign] menu:hostMenu source:hostContext
                                                 itemClass:SRFakeMenuItem.class generation:@"g11"];
        CHECK(incompatible.count == 1 && incompatible[0] == foreign);
        gMenuItemInitMode = 0;
        __weak id weakOwnedItem = nil;
        @autoreleasepool {
            NSArray *owned = [hook appendHostItemToItems:@[foreign] menu:hostMenu source:hostContext
                                              itemClass:SRFakeMenuItem.class generation:@"g12"];
            weakOwnedItem = owned.lastObject;
        }
        CHECK(weakOwnedItem == nil);   // the hook keeps only a weak key

        // --- production build interposer: append, forward once, refusal ---
        SRBuildMenuController *buildMenu = [SRBuildMenuController new];
        buildMenu.responder = cover;
        gBuildSetCalls = 0;
        SRMenuBuildHook *buildHook = [[SRMenuBuildHook alloc] initWithHook:hook
            menuClass:SRBuildMenuController.class coverClass:SRHostCoverView.class
            cellClass:SRHostMessageCell.class itemClass:SRFakeMenuItem.class];
        Method hostSetterMethod = class_getInstanceMethod(SRBuildMenuController.class, @selector(setMenuItems:));
        IMP hostSetterIMP = method_getImplementation(hostSetterMethod);
        CHECK([buildHook install:NULL]);
        CHECK(buildHook.installed && !buildHook.restoreRefused);
        [buildMenu setMenuItems:@[foreign]];
        CHECK(gBuildSetCalls == 1);
        CHECK(buildMenu.lastItems.count == 2 && [hook ownsItem:buildMenu.lastItems.lastObject]);
        // A later hook takes the method; uninstall must keep forwarding intact.
        Method buildSetter = class_getInstanceMethod(SRBuildMenuController.class, @selector(setMenuItems:));
        IMP buildTrampoline = method_getImplementation(buildSetter);
        gBuildForeignNext = buildTrampoline;
        method_setImplementation(buildSetter, (IMP)SRBuildForeignHook);
        [buildHook uninstall];
        CHECK(buildHook.installed && buildHook.restoreRefused);
        NSUInteger callsBeforeForeign = gBuildSetCalls;
        [buildMenu setMenuItems:@[foreign]];
        CHECK(gBuildSetCalls == callsBeforeForeign + 1);   // still forwarded once
        // Remove the foreign hook, then restore cleanly through the trampoline so
        // uninstall can put the original implementation back itself.
        method_setImplementation(buildSetter, buildTrampoline);
        gBuildForeignNext = NULL;
        [buildHook uninstall];
        CHECK(!buildHook.installed && !buildHook.restoreRefused);
        // A host that passes the controller (not the item view) still resolves the
        // published item and saves.
        rebuild();
        NSUInteger beforeFallback = [[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count];
        [hook srMenuAction:hostMenu];
        CHECK([[store libraryItemsForAccount:@"account" limit:50 offset:0 error:NULL] count] == beforeFallback + 1);

        // A presentation refreshes the item even when the host kept a cached
        // array: the show interposer appends before the menu is displayed.
        SRBuildMenuController *showMenu = [SRBuildMenuController new];
        showMenu.responder = cover;
        showMenu.currentMenuItems = @[foreign];
        SRMenuBuildHook *showHook = [[SRMenuBuildHook alloc] initWithHook:hook
            menuClass:SRBuildMenuController.class coverClass:SRHostCoverView.class
            cellClass:SRHostMessageCell.class itemClass:SRFakeMenuItem.class];
        CHECK([showHook install:NULL]);
        [showMenu setMenuVisible:YES responder:cover animated:NO];
        CHECK(showMenu.showCalls == 1);
        CHECK(showMenu.currentMenuItems.count == 2);
        CHECK([hook ownsItem:showMenu.currentMenuItems.lastObject]);
        [showHook uninstall];
        CHECK(!showHook.installed);

        // A rebuild within the same long-press keeps the item when the source is
        // momentarily unavailable; after the window it is dropped again.
        SRBuildMenuController *rebuildMenu = [SRBuildMenuController new];
        rebuildMenu.responder = cover;
        NSArray *firstPublish = [buildHook publishItems:@[] menu:rebuildMenu];
        CHECK(firstPublish.count == 1 && [hook ownsItem:firstPublish.lastObject]);
        NSArray *secondPublish = [buildHook publishItems:@[] menu:rebuildMenu];
        CHECK(secondPublish.count == 1);
        cover.delegate = nil;                       // source resolution fails
        NSArray *reusedPublish = [buildHook publishItems:@[] menu:rebuildMenu];
        CHECK(reusedPublish.count == 1 && [hook ownsItem:reusedPublish.lastObject]);
        buildHook.reuseWindow = 0;
        NSArray *droppedPublish = [buildHook publishItems:@[] menu:rebuildMenu];
        CHECK(droppedPublish.count == 0);
        cover.delegate = cell;
        buildHook.reuseWindow = 3.0;

        // A call already inside the trampoline still forwards after a clean
        // uninstall; the captured original is not cleared.
        NSUInteger callsAfterRestore = gBuildSetCalls;
        ((void (*)(id, SEL, id))buildTrampoline)(buildMenu, @selector(setMenuItems:), @[foreign]);
        CHECK(gBuildSetCalls == callsAfterRestore + 1);
        // The same class may be re-installed while the chain is the original one.
        SRMenuBuildHook *sameClass = [[SRMenuBuildHook alloc] initWithHook:hook
            menuClass:SRBuildMenuController.class coverClass:SRHostCoverView.class
            cellClass:SRHostMessageCell.class itemClass:SRFakeMenuItem.class];
        CHECK([sameClass install:NULL]);
        CHECK(sameClass.installed);
        [sameClass uninstall];
        CHECK(!sameClass.installed);
        // A chain that now points elsewhere is refused without modification.
        gBuildForeignNext = method_getImplementation(buildSetter);
        method_setImplementation(buildSetter, (IMP)SRBuildForeignHook);
        IMP beforeRefusal = method_getImplementation(buildSetter);
        SRMenuBuildHook *changedChain = [[SRMenuBuildHook alloc] initWithHook:hook
            menuClass:SRBuildMenuController.class coverClass:SRHostCoverView.class
            cellClass:SRHostMessageCell.class itemClass:SRFakeMenuItem.class];
        CHECK(![changedChain install:NULL]);
        CHECK(method_getImplementation(buildSetter) == beforeRefusal);
        method_setImplementation(buildSetter, hostSetterIMP);
        gBuildForeignNext = NULL;
        // Re-installing on a different class after restore is refused.
        SRMenuBuildHook *crossClass = [[SRMenuBuildHook alloc] initWithHook:hook menuClass:SRHostMenu.class
            coverClass:SRHostCoverView.class cellClass:SRHostMessageCell.class itemClass:SRFakeMenuItem.class];
        CHECK(![crossClass install:NULL]);
        CHECK(!crossClass.installed);

        // --- storage gone: refuse, never report success ---
        // Isolated fixture: the store is created inside an inner pool and is
        // released when that pool drains, while the hook and its item stay
        // strongly held in this outer scope. That way "the store was released"
        // cannot be confused with "the hook or the menu item disappeared".
        NSString *deadPath = [directory stringByAppendingPathComponent:@"dead.sqlite3"];
        SRMessageMenuHook *deadHook = nil;
        NSArray *deadItems = nil;
        __weak SRStore *weakDeadStore = nil;
        @autoreleasepool {
            SRStore *deadStore = [[SRStore alloc] initWithPath:deadPath error:NULL];
            CHECK(deadStore != nil);
            weakDeadStore = deadStore;
            SRLibraryIntake *deadIntake = [[SRLibraryIntake alloc] initWithStore:deadStore];
            CHECK(deadIntake != nil);
            // The callbacks capture the account string only, never the store.
            deadHook = [[SRMessageMenuHook alloc] initWithIntake:deadIntake
                currentAccount:^NSString *{ return @"account"; }
                accountActive:^BOOL(NSString *value) { return [value isEqual:@"account"]; }
                enabled:^BOOL { return YES; }];
            CHECK(deadHook != nil);
        [deadHook configureEpochProvider:^unsigned long long { return 0; }];
            // A new operation that was never clicked and never saved.
            deadItems = [deadHook appendOwnItemToItems:@[] generation:@"g4"
                source:makeContext(@"account", @"写入但存储已失效", @"msg-4", @"op-4")];
            CHECK(deadItems.count == 1);
            deadStore = nil;
        }
        // Precondition: the store is really gone while hook and item survive.
        CHECK(weakDeadStore == nil);
        CHECK(deadHook != nil);
        CHECK([deadHook ownsItem:deadItems.lastObject]);
        CHECK([deadHook contextForOwnItem:deadItems.lastObject] != nil);
        SRMenuIntentResult deadResult = [deadHook handleSelection:deadItems.lastObject
            current:currentIdentity(@"account", @"owner-1", @"g4", @"msg-4")];
        if (deadResult != SRMenuIntentStorageUnavailable) {
            // Numbers only: no body, account, message ID or address.
            NSLog(@"storage-gone fixture returned intent %lu", (unsigned long)deadResult);
        }
        CHECK(deadResult == SRMenuIntentStorageUnavailable);

        // --- freeze: a mutable source cannot change what an item will save ---
        NSMutableString *mAccount = [@"account" mutableCopy];
        NSMutableString *mBody = [@"冻结正文 synthetic body" mutableCopy];
        NSMutableString *mGeneration = [@"g-freeze" mutableCopy];
        NSMutableString *mIdentity = [@"msg-freeze" mutableCopy];
        NSMutableString *mKey = [@"op-freeze" mutableCopy];
        SRMenuMessageContext *liveSource = [[SRMenuMessageContext alloc] initWithAccount:mAccount
            body:mBody generation:mGeneration ownerToken:@"owner-freeze" messageIdentity:mIdentity
            session:@"chat" messageType:@"1" createdAt:@"1000" epoch:@"0" operationKey:mKey];
        preferences.libraryMenuEntryEnabled = YES;
        NSArray *frozenItems = [hook appendOwnItemToItems:@[] generation:@"g-freeze" source:liveSource];
        CHECK(frozenItems.count == 1);
        [mAccount appendString:@"-mutated"];
        [mBody appendString:@"-mutated"];
        [mGeneration appendString:@"-mutated"];
        [mIdentity appendString:@"-mutated"];
        [mKey appendString:@"-mutated"];
        // append must never rewrite the caller's generation.
        CHECK([mGeneration isEqual:@"g-freeze-mutated"]);
        SRMenuMessageContext *snapshot = [hook contextForOwnItem:frozenItems.lastObject];
        CHECK(snapshot != nil && snapshot != liveSource);
        CHECK([snapshot.account isEqual:@"account"]);
        CHECK([snapshot.body isEqual:@"冻结正文 synthetic body"]);
        CHECK([snapshot.generation isEqual:@"g-freeze"]);
        CHECK([snapshot.ownerToken isEqual:@"owner-freeze"]);
        CHECK([snapshot.messageIdentity isEqual:@"msg-freeze"]);
        CHECK([snapshot.operationKey isEqual:@"op-freeze"]);
        // No public setter exists, so nothing can rewrite a frozen snapshot.
        for (NSString *setter in @[@"setAccount:", @"setBody:", @"setGeneration:", @"setOwnerToken:",
                                   @"setMessageIdentity:", @"setOperationKey:"]) {
            CHECK(class_getInstanceMethod(SRMenuMessageContext.class, NSSelectorFromString(setter)) == NULL);
        }
        for (NSString *setter in @[@"setAccount:", @"setOwnerToken:", @"setGeneration:", @"setMessageIdentity:"]) {
            CHECK(class_getInstanceMethod(SRMenuCurrentIdentity.class, NSSelectorFromString(setter)) == NULL);
        }

        // --- observation-only menu call observer ---
        // (1) install gate: missing, inherited and wrong signatures are refused
        // before any IMP changes.
        IMP initBefore = method_getImplementation(class_getInstanceMethod(SRFakeMenuItem.class,
            @selector(initWithTitle:icon:target:action:)));
        SRMenuCallObserver *gateObserver = [[SRMenuCallObserver alloc] initWithClock:^NSTimeInterval { return 0; }];
        CHECK(![gateObserver installOnMenuClass:SRIncompleteMenuController.class itemClass:SRFakeMenuItem.class error:NULL]);
        CHECK(![gateObserver installOnMenuClass:SRInheritedMenuController.class itemClass:SRFakeMenuItem.class error:NULL]);
        CHECK(![gateObserver installOnMenuClass:SRWrongReturnController.class itemClass:SRFakeMenuItem.class error:NULL]);
        CHECK(![gateObserver installOnMenuClass:SRObservedMenu.class itemClass:nil error:NULL]);
        IMP initAfter = method_getImplementation(class_getInstanceMethod(SRFakeMenuItem.class,
            @selector(initWithTitle:icon:target:action:)));
        CHECK(initBefore == initAfter);
        CHECK(!gateObserver.installed);

        // (2) one installer per process.
        __block NSTimeInterval observedNow = 1000;
        __block BOOL clockThrows = NO;
        __block NSMutableArray<NSNumber *> *clockScript = nil;
        SRMenuCallObserver *observer = [[SRMenuCallObserver alloc] initWithClock:^NSTimeInterval {
            if (clockThrows) @throw [NSException exceptionWithName:@"SRTestClock" reason:@"clock" userInfo:nil];
            if (clockScript.count) {
                double value = clockScript.firstObject.doubleValue;
                [clockScript removeObjectAtIndex:0];
                return value;
            }
            return observedNow;
        }];
        CHECK(!observer.installed);
        CHECK(!observer.sampling);
        CHECK(observer.state == SRMenuCallObserverIdle);
        CHECK(!observer.restoreRefused);
        SRObservedMenu *observedMenu = [SRObservedMenu new];
        [observedMenu setMenuItems:@[]];
        CHECK(observedMenu.setCalls == 1);
        CHECK([(NSArray *)observer.diagnostics[@"events"] count] == 0);

        CHECK([observer installOnMenuClass:SRObservedMenu.class itemClass:SRObservedItem.class error:NULL]);
        CHECK(observer.installed && !observer.sampling);
        SRMenuCallObserver *conflictingObserver = [[SRMenuCallObserver alloc] initWithClock:^NSTimeInterval { return 0; }];
        CHECK(![conflictingObserver installOnMenuClass:SRObservedMenu.class itemClass:SRObservedItem.class error:NULL]);
        CHECK(![conflictingObserver installOnMenuClass:SRFakeMenuController.class itemClass:SRFakeMenuItem.class error:NULL]);
        CHECK(!conflictingObserver.installed);
        [observedMenu setMenuItems:@[]];
        CHECK(observedMenu.setCalls == 2);
        CHECK([(NSArray *)observer.diagnostics[@"events"] count] == 0);

        // (5) unsupported session parameters are refused before anything runs.
        CHECK(![observer beginSamplingWithTimeout:0 eventBudget:8 error:NULL]);
        CHECK(![observer beginSamplingWithTimeout:NAN eventBudget:8 error:NULL]);
        CHECK(![observer beginSamplingWithTimeout:INFINITY eventBudget:8 error:NULL]);
        CHECK(![observer beginSamplingWithTimeout:301 eventBudget:8 error:NULL]);
        CHECK(![observer beginSamplingWithTimeout:30 eventBudget:4 error:NULL]);
        CHECK(![observer beginSamplingWithTimeout:30 eventBudget:257 error:NULL]);
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:24 error:NULL]);
        CHECK(observer.sampling && observer.state == SRMenuCallObserverSampling);

        // Session A: construction, build, selections, truncation, twins.
        SRObservedItem *ownItem = [[SRObservedItem alloc] initWithTitle:@"canary-title" icon:nil
            target:observedMenu action:@selector(observeAction:)];
        CHECK(ownItem != nil);
        SRForeignItem *otherItem = [SRForeignItem new];
        NSArray *menuItems = @[otherItem, ownItem];
        [observedMenu setMenuItems:menuItems];
        CHECK(observedMenu.setCalls == 3);
        CHECK(observedMenu.lastItems == menuItems);
        [observedMenu onMenuItemSelected:ownItem itemView:otherItem];
        [observedMenu onMenuItemSelected:otherItem itemView:otherItem];
        [observedMenu onMenuItemSelected:nil itemView:nil];
        CHECK(observedMenu.selectCalls == 3);

        NSDictionary *observed = observer.diagnostics;
        NSArray *events = observed[@"events"];
        CHECK(events.count == 5);
        CHECK([events[0][@"kind"] isEqual:@"init"]);
        CHECK([events[0][@"titleNull"] boolValue] == NO);
        CHECK([events[0][@"iconNull"] boolValue] == YES);
        CHECK([events[0][@"targetIsMenuClass"] boolValue] == YES);
        CHECK([events[0][@"actionDeclared"] boolValue] == YES);
        CHECK([events[0][@"actionArgs"] unsignedIntegerValue] == 3);
        CHECK([events[0][@"resultNull"] boolValue] == NO);
        CHECK([events[1][@"kind"] isEqual:@"build"]);
        CHECK([events[1][@"items"] unsignedIntegerValue] == 2);
        CHECK([events[1][@"inspected"] unsignedIntegerValue] == 2);
        CHECK([events[1][@"coverage"] isEqual:@"complete"]);
        CHECK([events[1][@"known"] unsignedIntegerValue] == 1);
        CHECK([events[1][@"foreign"] unsignedIntegerValue] == 1);
        // A foreign object that really was in the array is `seen`, not `not_seen`.
        CHECK([events[2][@"itemPresence"] isEqual:@"seen"]);
        CHECK([events[2][@"viewPresence"] isEqual:@"seen"]);
        CHECK([events[2][@"itemKnown"] boolValue] == YES);
        CHECK([events[2][@"viewKnown"] boolValue] == NO);
        CHECK([events[3][@"itemPresence"] isEqual:@"seen"]);
        CHECK([events[3][@"sameObject"] boolValue] == YES);
        CHECK([events[4][@"itemPresence"] isEqual:@"unknown"]);
        CHECK([events[4][@"viewPresence"] isEqual:@"unknown"]);
        CHECK([events[4][@"itemNull"] boolValue] == YES);

        // (7) bounded runtime metadata: real classes, the one action selector and
        // normalized declared type tokens, all read from the same arguments.
        NSDictionary *metadata = observed[@"menuCallMetadata"];
        NSArray *metadataEntries = metadata[@"entries"];
        CHECK(metadataEntries.count == 5);
        CHECK([metadataEntries[0][@"kind"] isEqual:@"init"]);
        CHECK([metadataEntries[0][@"target"] isEqual:@"SRObservedMenu"]);
        CHECK([metadataEntries[0][@"action"] isEqual:@"observeAction:"]);
        CHECK([metadataEntries[0][@"icon"] isEqual:@"<nil>"]);
        CHECK([metadataEntries[0][@"result"] isEqual:@"SRObservedItem"]);
        CHECK([metadataEntries[0][@"signature"] isEqual:@"ret=void;args=object,sel,object"]);
        CHECK([metadataEntries[0][@"declared"] boolValue] == YES);
        CHECK([metadataEntries[1][@"kind"] isEqual:@"build"]);
        CHECK([metadataEntries[1][@"receiver"] isEqual:@"SRObservedMenu"]);
        // The construction link is identity-only and matched to this session's init.
        CHECK([metadataEntries[2][@"view"] isEqual:@"SRForeignItem"]);
        CHECK([metadataEntries[2][@"link"] isEqual:@"matched"]);
        CHECK([metadataEntries[2][@"init"] unsignedIntegerValue] == 0);
        CHECK([metadataEntries[3][@"link"] isEqual:@"unmatched"]);
        CHECK([metadataEntries[3][@"init"] isEqual:@"<unmatched>"]);
        CHECK([metadataEntries[4][@"init"] isEqual:@"<unmatched>"]);
        CHECK([metadata[@"dropped"] unsignedIntegerValue] == 0);
        CHECK([metadata[@"linksTruncated"] boolValue] == NO);
        NSData *metadataJSON = [NSJSONSerialization dataWithJSONObject:metadata options:0 error:NULL];
        NSString *metadataText = [[NSString alloc] initWithData:metadataJSON encoding:NSUTF8StringEncoding];
        CHECK([metadataText rangeOfString:@"0x"].location == NSNotFound);
        CHECK([metadataText rangeOfString:@"<SRObserved"].location == NSNotFound);
        CHECK([metadataText rangeOfString:@"canary-title"].location == NSNotFound);

        // (6) an object beyond the 64-item cap is unobserved, not denied.
        NSMutableArray *tail = [NSMutableArray array];
        for (NSUInteger index = 0; index < 64; index++) [tail addObject:[SRForeignItem new]];
        [tail addObject:ownItem];
        [observedMenu setMenuItems:tail];
        SRForeignItem *notInArray = [SRForeignItem new];
        [observedMenu onMenuItemSelected:ownItem itemView:notInArray];
        observed = observer.diagnostics;
        events = observed[@"events"];
        NSDictionary *capped = events[5];
        CHECK([capped[@"kind"] isEqual:@"build"]);
        CHECK([capped[@"items"] unsignedIntegerValue] == 65);
        CHECK([capped[@"inspected"] unsignedIntegerValue] == 64);
        CHECK([capped[@"truncated"] boolValue] == YES);
        CHECK([capped[@"coverage"] isEqual:@"truncated"]);
        CHECK([events[6][@"itemPresence"] isEqual:@"unknown"]);   // own item is the tail
        CHECK([events[6][@"viewPresence"] isEqual:@"unknown"]);   // never inspected

        // Twins: pointer identity inside a complete build.
        SRTwinItem *twinA = [SRTwinItem new];
        SRTwinItem *twinB = [SRTwinItem new];
        gTwinHashCalls = 0; gTwinEqualCalls = 0;
        [observedMenu setMenuItems:@[twinA]];
        [observedMenu onMenuItemSelected:twinB itemView:twinA];
        observed = observer.diagnostics;
        events = observed[@"events"];
        CHECK([events[7][@"coverage"] isEqual:@"complete"]);
        CHECK([events[8][@"itemPresence"] isEqual:@"not_seen"]);  // twinB never appeared
        CHECK([events[8][@"viewPresence"] isEqual:@"seen"]);      // twinA did
        CHECK(gTwinHashCalls == 0 && gTwinEqualCalls == 0);

        // (3) a legal NSArray subclass that reenters the observer mid-build.
        SRReentrantArray *reentrant = [SRReentrantArray new];
        reentrant.storage = @[ownItem];
        reentrant.onAccess = ^{ [observedMenu onMenuItemSelected:ownItem itemView:nil]; };
        NSUInteger forwardsBeforeReentry = observedMenu.setCalls;
        NSUInteger hostSelectsBeforeReentry = observedMenu.selectCalls;
        NSUInteger observedSelectsBeforeReentry =
            [observer.diagnostics[@"counts"][@"select"] unsignedIntegerValue];
        [observedMenu setMenuItems:reentrant];
        // Exactly one host forward, and exactly one extra observation from the
        // single reentrant call: no invented calls to make the numbers match.
        CHECK(observedMenu.setCalls == forwardsBeforeReentry + 1);
        CHECK(observedMenu.selectCalls == hostSelectsBeforeReentry + 1);
        observed = observer.diagnostics;
        CHECK([observed[@"counts"][@"build"] unsignedIntegerValue] == 4);
        CHECK([observed[@"counts"][@"select"] unsignedIntegerValue] == observedSelectsBeforeReentry + 1);

        // (4) redaction on a snapshot that really holds all three kinds.
        NSMutableSet *kinds = [NSMutableSet set];
        for (NSDictionary *event in (NSArray *)observed[@"events"]) [kinds addObject:event[@"kind"]];
        CHECK([kinds containsObject:@"init"] && [kinds containsObject:@"build"] &&
              [kinds containsObject:@"select"]);
        NSData *observedJSON = [NSJSONSerialization dataWithJSONObject:observed options:0 error:NULL];
        NSString *observedText = observedJSON ? [[NSString alloc] initWithData:observedJSON
                                                                     encoding:NSUTF8StringEncoding] : nil;
        CHECK(observedText.length > 0);
        CHECK([observedText rangeOfString:@"canary-title"].location == NSNotFound);
        // Class names are allowed only in the separate metadata area; the event
        // list still exports none of them.
        NSData *eventsJSON = [NSJSONSerialization dataWithJSONObject:(NSArray *)observed[@"events"] options:0 error:NULL];
        NSString *eventsText = [[NSString alloc] initWithData:eventsJSON encoding:NSUTF8StringEncoding];
        CHECK([eventsText rangeOfString:@"SRObserved"].location == NSNotFound);
        CHECK([eventsText rangeOfString:@"SRTwin"].location == NSNotFound);
        CHECK([observedText rangeOfString:@"account"].location == NSNotFound);

        // (3) an unreadable build invalidates the previous association.
        [observedMenu setMenuItems:@[ownItem]];
        [observedMenu onMenuItemSelected:ownItem itemView:nil];
        observed = observer.diagnostics;
        events = observed[@"events"];
        CHECK([events.lastObject[@"itemPresence"] isEqual:@"seen"]);
        [observedMenu setMenuItems:(NSArray *)[NSObject new]];   // not an NSArray
        [observedMenu onMenuItemSelected:ownItem itemView:nil];
        observed = observer.diagnostics;
        events = observed[@"events"];
        CHECK([events.lastObject[@"itemPresence"] isEqual:@"unknown"]);
        CHECK([events.lastObject[@"coverage"] isEqual:@"stale"]);

        SRThrowingArray *throwing = [SRThrowingArray new];
        NSUInteger hostBeforeThrowing = observedMenu.setCalls;
        [observedMenu setMenuItems:throwing];
        // The container threw while being read; the host call still ran once.
        CHECK(observedMenu.setCalls == hostBeforeThrowing + 1);
        [observedMenu onMenuItemSelected:ownItem itemView:nil];
        observed = observer.diagnostics;
        events = observed[@"events"];
        CHECK([events.lastObject[@"itemPresence"] isEqual:@"unknown"]);

        // (5) the deadline is enforced by the observed call itself.
        NSUInteger beforeTimeout = [(NSArray *)observer.diagnostics[@"events"] count];
        SRCountingArray *countingAfterTimeout = [SRCountingArray new];
        countingAfterTimeout.storage = @[ownItem];
        gArrayCountCalls = 0; gArrayIndexCalls = 0;
        NSUInteger hostBeforeTimeoutCall = observedMenu.setCalls;
        observedNow += 31;
        [observedMenu setMenuItems:countingAfterTimeout];
        // Refused before the container is read; the host call still ran once.
        CHECK(gArrayCountCalls == 0 && gArrayIndexCalls == 0);
        CHECK(observedMenu.setCalls == hostBeforeTimeoutCall + 1);
        NSDictionary *afterTimeout = observer.diagnostics;
        CHECK([(NSArray *)afterTimeout[@"events"] count] == beforeTimeout);
        CHECK(!observer.sampling);
        CHECK(observer.state == SRMenuCallObserverStopped);
        CHECK([afterTimeout[@"stopReason"] isEqual:@"timeout"]);

        // The container is read outside the lock; a deadline crossed during that
        // read must not commit the build event or its association.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        SRCountingArray *countingSlow = [SRCountingArray new];
        countingSlow.storage = @[ownItem];
        countingSlow.onAccess = ^{ observedNow += 31; };
        NSUInteger hostBeforeSlow = observedMenu.setCalls;
        [observedMenu setMenuItems:countingSlow];
        CHECK(observedMenu.setCalls == hostBeforeSlow + 1);   // host call still exactly once
        observed = observer.diagnostics;
        CHECK(!observer.sampling);
        CHECK([observed[@"stopReason"] isEqual:@"timeout"]);
        CHECK([observed[@"counts"][@"build"] unsignedIntegerValue] == 0);
        CHECK([observed[@"counts"][@"buildRefs"] unsignedIntegerValue] == 0);
        CHECK([(NSArray *)observed[@"events"] count] == 0);

        // (6) a skipped build makes later presence unknown, not not_seen.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:14 error:NULL]);
        for (NSUInteger index = 0; index < 8; index++) [observedMenu setMenuItems:@[ownItem]];
        CHECK([observer.diagnostics[@"counts"][@"build"] unsignedIntegerValue] == 8);
        SRCountingArray *countingRejected = [SRCountingArray new];
        countingRejected.storage = @[ownItem];
        gArrayCountCalls = 0; gArrayIndexCalls = 0;
        NSUInteger hostBeforeRejected = observedMenu.setCalls;
        [observedMenu setMenuItems:countingRejected];       // build limit reached
        // Refused before the container is read; the host call still ran once.
        CHECK(gArrayCountCalls == 0 && gArrayIndexCalls == 0);
        CHECK(observedMenu.setCalls == hostBeforeRejected + 1);
        [observedMenu onMenuItemSelected:ownItem itemView:nil];
        observed = observer.diagnostics;
        events = observed[@"events"];
        CHECK([observed[@"counts"][@"build"] unsignedIntegerValue] == 8);
        CHECK([events.lastObject[@"coverage"] isEqual:@"stale"]);
        CHECK([events.lastObject[@"itemPresence"] isEqual:@"unknown"]);

        // The skipped build only marked the association stale; the session is
        // still running, so stop it explicitly before starting the next one.
        CHECK(observer.sampling);
        [observer stopSampling];
        CHECK(!observer.sampling);

        // Budget too small for another build: also refused before any read.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:5 error:NULL]);
        [observedMenu setMenuItems:@[ownItem]];             // one build fits
        SRCountingArray *countingBudget = [SRCountingArray new];
        countingBudget.storage = @[ownItem];
        gArrayCountCalls = 0; gArrayIndexCalls = 0;
        NSUInteger hostBeforeBudget = observedMenu.setCalls;
        [observedMenu setMenuItems:countingBudget];
        CHECK(gArrayCountCalls == 0 && gArrayIndexCalls == 0);
        CHECK(observedMenu.setCalls == hostBeforeBudget + 1);
        // The small-budget session is still recording; close it explicitly.
        CHECK(observer.sampling);
        [observer stopSampling];
        CHECK(!observer.sampling);

        // A click whose construction was not observed is reported as none.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        [observedMenu onMenuItemSelected:ownItem itemView:nil];
        NSDictionary *unconstructed = observer.diagnostics;
        NSArray *unconstructedEntries = unconstructed[@"menuCallMetadata"][@"entries"];
        CHECK([unconstructedEntries.lastObject[@"link"] isEqual:@"none"]);
        CHECK([unconstructedEntries.lastObject[@"init"] isEqual:@"<none>"]);
        CHECK([unconstructed[@"menuCallMetadata"][@"linksTruncated"] boolValue] == NO);
        [observer stopSampling];

        // Metadata is capped independently of the event budget.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:24 error:NULL]);
        for (NSUInteger index = 0; index < 8; index++) [observedMenu setMenuItems:@[ownItem]];
        for (NSUInteger index = 0; index < 16; index++) [observedMenu onMenuItemSelected:ownItem itemView:nil];
        NSDictionary *cappedMetadata = observer.diagnostics[@"menuCallMetadata"];
        CHECK([(NSArray *)cappedMetadata[@"entries"] count] == 12);
        CHECK([cappedMetadata[@"dropped"] unsignedIntegerValue] > 0);
        NSUInteger cappedCount = [(NSArray *)cappedMetadata[@"entries"] count];
        [observer stopSampling];
        [observedMenu setMenuItems:@[ownItem]];
        [observedMenu onMenuItemSelected:ownItem itemView:nil];
        CHECK([(NSArray *)observer.diagnostics[@"menuCallMetadata"][@"entries"] count] == cappedCount);
        CHECK(!observer.sampling);

        // The link table is bounded: a construction beyond it cannot be named.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:12 error:NULL]);
        NSMutableArray *linkItems = [NSMutableArray array];
        for (NSUInteger index = 0; index < 5; index++) {
            SRObservedItem *item = [[SRObservedItem alloc] initWithTitle:@"link" icon:nil
                target:observedMenu action:@selector(observeAction:)];
            [linkItems addObject:item];
        }
        [observedMenu onMenuItemSelected:linkItems.lastObject itemView:nil];
        NSDictionary *overflowMetadata = observer.diagnostics[@"menuCallMetadata"];
        CHECK([overflowMetadata[@"linksTruncated"] boolValue] == YES);
        NSArray *overflowEntries = overflowMetadata[@"entries"];
        CHECK([overflowEntries.lastObject[@"init"] isEqual:@"<overflow>"]);
        [observer stopSampling];
        CHECK(!observer.sampling);

        // Two constructions with different target/action are individually locatable.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        SRSecondaryTarget *secondary = [SRSecondaryTarget new];
        SRObservedItem *secondItem = [[SRObservedItem alloc] initWithTitle:@"b" icon:nil
            target:secondary action:@selector(otherAction:)];
        SRObservedItem *firstItem = [[SRObservedItem alloc] initWithTitle:@"a" icon:nil
            target:observedMenu action:@selector(observeAction:)];
        [observedMenu onMenuItemSelected:secondItem itemView:nil];
        NSArray *linkedEntries = observer.diagnostics[@"menuCallMetadata"][@"entries"];
        NSUInteger secondSelectIndex = [linkedEntries.lastObject[@"init"] unsignedIntegerValue];
        NSDictionary *secondInit = linkedEntries[secondSelectIndex];
        CHECK([secondInit[@"target"] isEqual:@"SRSecondaryTarget"]);
        CHECK([secondInit[@"action"] isEqual:@"otherAction:"]);
        [observedMenu onMenuItemSelected:firstItem itemView:nil];
        NSArray *linkedEntries2 = observer.diagnostics[@"menuCallMetadata"][@"entries"];
        NSUInteger firstSelectIndex = [linkedEntries2.lastObject[@"init"] unsignedIntegerValue];
        NSDictionary *firstInit = linkedEntries2[firstSelectIndex];
        CHECK([firstInit[@"target"] isEqual:@"SRObservedMenu"]);
        CHECK([firstInit[@"action"] isEqual:@"observeAction:"]);
        CHECK(firstSelectIndex != secondSelectIndex);
        [observer stopSampling];
        CHECK(!observer.sampling);

        // An undeclared action is reported without asking the runtime to resolve it.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        gResolverCalls = 0;
        SRUnresolvedTarget *unresolved = [SRUnresolvedTarget new];
        SRObservedItem *unresolvedItem = [[SRObservedItem alloc] initWithTitle:@"u" icon:nil
            target:unresolved action:NSSelectorFromString(@"missingAction:")];
        (void)unresolvedItem;
        NSArray *resolverEntries = observer.diagnostics[@"menuCallMetadata"][@"entries"];
        NSDictionary *resolverInit = resolverEntries.lastObject;
        CHECK([resolverInit[@"declared"] boolValue] == NO);
        CHECK([resolverInit[@"signature"] isEqual:@"<undeclared>"]);
        CHECK(gResolverCalls == 0);
        [observer stopSampling];
        CHECK(!observer.sampling);

        // (8) Clicked-item handler clues from declared getters only.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:16 error:NULL]);
        SRSecondaryTarget *handlerTarget = [SRSecondaryTarget new];
        SRObservedItem *handlerItem = [[SRObservedItem alloc] init];
        handlerItem.handlerTarget = handlerTarget;
        handlerItem.handlerAction = @selector(otherAction:);
        gOtherActionCalls = 0;
        [observedMenu onMenuItemSelected:handlerItem itemView:nil];
        NSDictionary *handlerMeta = [(NSArray *)observer.diagnostics[@"menuCallMetadata"][@"entries"] lastObject];
        CHECK([handlerMeta[@"handlerKind"] isEqual:@"target"]);
        CHECK([handlerMeta[@"handlerTarget"] isEqual:@"SRSecondaryTarget"]);
        CHECK([handlerMeta[@"handlerAction"] isEqual:@"otherAction:"]);
        CHECK([handlerMeta[@"handlerSignature"] isEqual:@"ret=void;args=object,sel,object"]);
        CHECK([handlerMeta[@"actionBlock"] isEqual:@"no"]);
        CHECK(gOtherActionCalls == 0);           // the action is never called

        // target nil: the same click resolves the controller's responder.
        SRObservedItem *responderItem = [[SRObservedItem alloc] init];
        responderItem.handlerAction = @selector(otherAction:);
        observedMenu.responder = handlerTarget;
        [observedMenu onMenuItemSelected:responderItem itemView:nil];
        NSDictionary *responderMeta = [(NSArray *)observer.diagnostics[@"menuCallMetadata"][@"entries"] lastObject];
        CHECK([responderMeta[@"handlerKind"] isEqual:@"responder"]);
        CHECK([responderMeta[@"handlerTarget"] isEqual:@"<nil>"]);
        CHECK([responderMeta[@"responder"] isEqual:@"SRSecondaryTarget"]);
        CHECK([responderMeta[@"responderSignature"] isEqual:@"ret=void;args=object,sel,object"]);
        observedMenu.responder = nil;

        // Block presence is recorded; the block is never executed.
        __block NSUInteger blockRuns = 0;
        SRObservedItem *blockItem = [[SRObservedItem alloc] init];
        blockItem.handlerBlock = ^{ blockRuns++; };
        [observedMenu onMenuItemSelected:blockItem itemView:nil];
        NSDictionary *blockMeta = [(NSArray *)observer.diagnostics[@"menuCallMetadata"][@"entries"] lastObject];
        CHECK([blockMeta[@"handlerKind"] isEqual:@"block"]);
        CHECK([blockMeta[@"actionBlock"] isEqual:@"yes"]);
        CHECK(blockRuns == 0);

        // A throwing getter is explicit and never breaks the host call.
        SRObservedItem *raisingItem = [[SRObservedItem alloc] init];
        raisingItem.raiseOnHandlerTarget = YES;
        NSUInteger hostBeforeRaising = observedMenu.selectCalls;
        [observedMenu onMenuItemSelected:raisingItem itemView:nil];
        CHECK(observedMenu.selectCalls == hostBeforeRaising + 1);
        NSDictionary *raisingMeta = [(NSArray *)observer.diagnostics[@"menuCallMetadata"][@"entries"] lastObject];
        CHECK([raisingMeta[@"handlerTarget"] isEqual:@"<error>"]);
        CHECK([raisingMeta[@"handlerKind"] isEqual:@"none"]);

        // An undeclared action stays undeclared and never wakes the resolver.
        SRUnresolvedTarget *unresolvedTarget = [SRUnresolvedTarget new];
        SRObservedItem *handlerUnresolvedItem = [[SRObservedItem alloc] init];
        handlerUnresolvedItem.handlerTarget = unresolvedTarget;
        handlerUnresolvedItem.handlerAction = NSSelectorFromString(@"missingAction:");
        gResolverCalls = 0;
        [observedMenu onMenuItemSelected:handlerUnresolvedItem itemView:nil];
        NSDictionary *unresolvedMeta = [(NSArray *)observer.diagnostics[@"menuCallMetadata"][@"entries"] lastObject];
        CHECK([unresolvedMeta[@"handlerSignature"] isEqual:@"<undeclared>"]);
        CHECK(gResolverCalls == 0);

        // After a stop no further getter is read.
        [observer stopSampling];
        CHECK(!observer.sampling);
        NSUInteger targetGets = gTargetGetterCalls;
        [observedMenu onMenuItemSelected:handlerItem itemView:nil];
        CHECK(gTargetGetterCalls == targetGets);

        // (9) The getter window is protected: stop, restart, deadline or a
        // reentrant click during a getter stops further reads and never commits
        // the stale observation into another session.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        SRObservedItem *stopItem = [[SRObservedItem alloc] init];
        stopItem.handlerTarget = handlerTarget;
        stopItem.handlerAction = @selector(otherAction:);
        stopItem.targetGetterHook = ^{ [observer stopSampling]; };
        gTargetGetterCalls = 0; gActionGetterCalls = 0; gBlockGetterCalls = 0;
        [observedMenu onMenuItemSelected:stopItem itemView:nil];
        CHECK(gTargetGetterCalls == 1);
        CHECK(gActionGetterCalls == 0 && gBlockGetterCalls == 0);
        CHECK(!observer.sampling);
        CHECK([observer.diagnostics[@"counts"][@"select"] unsignedIntegerValue] == 0);

        // A getter may even restart a session; the old click must not land in it.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        NSUInteger beforeRestartToken = observer.sessionToken;
        SRObservedItem *restartItem = [[SRObservedItem alloc] init];
        restartItem.handlerTarget = handlerTarget;
        restartItem.handlerAction = @selector(otherAction:);
        restartItem.targetGetterHook = ^{
            [observer stopSampling];
            [observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL];
        };
        gTargetGetterCalls = 0; gActionGetterCalls = 0;
        [observedMenu onMenuItemSelected:restartItem itemView:nil];
        CHECK(gTargetGetterCalls == 1);
        CHECK(gActionGetterCalls == 0);
        CHECK(observer.sessionToken != beforeRestartToken);
        CHECK([observer.diagnostics[@"counts"][@"select"] unsignedIntegerValue] == 0);
        [observer stopSampling];

        // A getter that crosses the deadline stops the session and the reads.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        SRObservedItem *deadlineItem = [[SRObservedItem alloc] init];
        deadlineItem.handlerTarget = handlerTarget;
        deadlineItem.handlerAction = @selector(otherAction:);
        deadlineItem.targetGetterHook = ^{ observedNow += 31; };
        gTargetGetterCalls = 0; gActionGetterCalls = 0;
        [observedMenu onMenuItemSelected:deadlineItem itemView:nil];
        CHECK(gTargetGetterCalls == 1);
        CHECK(gActionGetterCalls == 0);
        CHECK(!observer.sampling);
        CHECK([observer.diagnostics[@"stopReason"] isEqual:@"timeout"]);
        CHECK([observer.diagnostics[@"counts"][@"select"] unsignedIntegerValue] == 0);

        // Reentrant click from a getter: bounded reads, both calls forwarded once.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        SRObservedItem *nestedItem = [[SRObservedItem alloc] init];
        SRObservedItem *outerItem = [[SRObservedItem alloc] init];
        outerItem.handlerTarget = handlerTarget;
        outerItem.handlerAction = @selector(otherAction:);
        outerItem.targetGetterHook = ^{ [observedMenu onMenuItemSelected:nestedItem itemView:nil]; };
        gTargetGetterCalls = 0;
        NSUInteger forwardsBeforeNested = observedMenu.selectCalls;
        [observedMenu onMenuItemSelected:outerItem itemView:nil];
        CHECK(observedMenu.selectCalls == forwardsBeforeNested + 2);
        CHECK(gTargetGetterCalls == 1);
        CHECK([observer.diagnostics[@"counts"][@"select"] unsignedIntegerValue] == 1);

        // After the guard is released, a later normal click is observed again.
        [observedMenu onMenuItemSelected:nestedItem itemView:nil];
        CHECK([observer.diagnostics[@"counts"][@"select"] unsignedIntegerValue] == 2);
        [observer stopSampling];

        // Budget exhaustion stops sampling before any getter is read.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:5 error:NULL]);
        for (NSUInteger index = 0; index < 5; index++) [observedMenu onMenuItemSelected:nestedItem itemView:nil];
        gTargetGetterCalls = 0; gActionGetterCalls = 0; gBlockGetterCalls = 0;
        gResponderGetterCalls = 0;
        [observedMenu onMenuItemSelected:nestedItem itemView:nil];
        CHECK(gTargetGetterCalls == 0);
        CHECK(gActionGetterCalls == 0 && gBlockGetterCalls == 0);
        CHECK(gResponderGetterCalls == 0);
        CHECK(!observer.sampling);
        CHECK([observer.diagnostics[@"stopReason"] isEqual:@"budget"]);
        CHECK([observer.diagnostics[@"counts"][@"select"] unsignedIntegerValue] == 5);

        // Select-limit rejection keeps the original dropped accounting.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:24 error:NULL]);
        for (NSUInteger index = 0; index < 16; index++) [observedMenu onMenuItemSelected:nestedItem itemView:nil];
        gTargetGetterCalls = 0; gActionGetterCalls = 0; gBlockGetterCalls = 0;
        gResponderGetterCalls = 0;
        [observedMenu onMenuItemSelected:nestedItem itemView:nil];
        CHECK(gTargetGetterCalls == 0);
        CHECK(gActionGetterCalls == 0 && gBlockGetterCalls == 0);
        CHECK(gResponderGetterCalls == 0);
        CHECK([observer.diagnostics[@"counts"][@"dropped"] unsignedIntegerValue] == 1);
        CHECK([observer.diagnostics[@"counts"][@"select"] unsignedIntegerValue] == 16);
        [observer stopSampling];

        // A stopped session never reads responder either.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        observedMenu.responder = handlerTarget;
        SRObservedItem *responderStopItem = [[SRObservedItem alloc] init];
        responderStopItem.handlerAction = @selector(otherAction:);
        responderStopItem.targetGetterHook = ^{ [observer stopSampling]; };
        gTargetGetterCalls = 0; gResponderGetterCalls = 0;
        [observedMenu onMenuItemSelected:responderStopItem itemView:nil];
        CHECK(gTargetGetterCalls == 1);
        CHECK(gResponderGetterCalls == 0);
        observedMenu.responder = nil;

        // (10) Guard cleanup covers admission-clock failures, the commit deadline
        // is checked again, and wrong getter shapes are rejected without calls.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        clockThrows = YES;
        NSUInteger forwardsBeforeClockThrow = observedMenu.selectCalls;
        [observedMenu onMenuItemSelected:nestedItem itemView:nil];
        CHECK(observedMenu.selectCalls == forwardsBeforeClockThrow + 1);
        clockThrows = NO;
        CHECK(observer.sampling);                      // no session was reopened
        CHECK([observer.diagnostics[@"counts"][@"select"] unsignedIntegerValue] == 0);
        gTargetGetterCalls = 0;
        [observedMenu onMenuItemSelected:nestedItem itemView:nil];
        CHECK([observer.diagnostics[@"counts"][@"select"] unsignedIntegerValue] == 1);
        CHECK(gTargetGetterCalls <= 1);                // guard was released
        [observer stopSampling];

        // Getter checks pass, but the commit clock is past the deadline.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        NSTimeInterval cutoff = observedNow + 30;
        // diagnostics reads self.sampling, which reads the clock: taking the
        // baselines after the script is armed would spend the admission tick.
        NSUInteger selectsBeforeLateCommit = [observer.diagnostics[@"counts"][@"select"] unsignedIntegerValue];
        NSUInteger metadataBeforeLateCommit = [(NSArray *)observer.diagnostics[@"menuCallMetadata"][@"entries"] count];
        NSUInteger forwardsBeforeLateCommit = observedMenu.selectCalls;
        gTargetGetterCalls = 0; gActionGetterCalls = 0; gBlockGetterCalls = 0;
        // Five ticks: admission and the three getter checks are all before the
        // deadline, the fifth one - the commit check - crosses it.
        clockScript = [@[@(cutoff - 1), @(cutoff - 1), @(cutoff - 1), @(cutoff - 1), @(cutoff + 1)] mutableCopy];
        [observedMenu onMenuItemSelected:nestedItem itemView:nil];
        // Before touching sampling/diagnostics again: every getter ran once and
        // the script was consumed exactly.
        CHECK(gTargetGetterCalls == 1);
        CHECK(gActionGetterCalls == 1 && gBlockGetterCalls == 1);
        CHECK(clockScript.count == 0);
        CHECK(observedMenu.selectCalls == forwardsBeforeLateCommit + 1);
        CHECK(!observer.sampling);
        CHECK([observer.diagnostics[@"stopReason"] isEqual:@"timeout"]);
        CHECK([observer.diagnostics[@"counts"][@"select"] unsignedIntegerValue] == selectsBeforeLateCommit);
        CHECK([(NSArray *)observer.diagnostics[@"menuCallMetadata"][@"entries"] count] == metadataBeforeLateCommit);
        clockScript = nil;

        // Wrong getter ABI: rejected before any call, no resolver.
        gWrongTargetCalls = 0; gWrongActionCalls = 0; gWrongBlockCalls = 0;
        gWrongResponderCalls = 0; gWrongABIResolverCalls = 0;
        NSDictionary *wrongABI = [SRMenuCallObserver inspectHandlerGettersForItem:[SRWrongABIItem new]
                                                                        receiver:[SRWrongABIReceiver new]];
        CHECK([wrongABI[@"handlerTarget"] isEqual:@"<missing>"]);
        CHECK([wrongABI[@"handlerAction"] isEqual:@"<missing>"]);
        CHECK([wrongABI[@"actionBlock"] isEqual:@"<missing>"]);
        CHECK(gWrongTargetCalls == 0 && gWrongActionCalls == 0 && gWrongBlockCalls == 0);
        CHECK(gWrongABIResolverCalls == 0);

        // A valid item cannot rescue a wrong responder getter.
        NSDictionary *wrongResponder = [SRMenuCallObserver inspectHandlerGettersForItem:[SRResponderABIItem new]
                                                                             receiver:[SRWrongABIReceiver new]];
        CHECK([wrongResponder[@"handlerTarget"] isEqual:@"<nil>"]);
        CHECK([wrongResponder[@"responder"] isEqual:@"<missing>"]);
        CHECK(gWrongResponderCalls == 0);

        // An object with no getters is explicit, not guessed.
        NSDictionary *noGetters = [SRMenuCallObserver inspectHandlerGettersForItem:[SRNoGetterItem new]
                                                                        receiver:[SRNoGetterItem new]];
        CHECK([noGetters[@"handlerKind"] isEqual:@"none"]);
        CHECK([noGetters[@"handlerTarget"] isEqual:@"<missing>"]);
        CHECK([noGetters[@"actionBlock"] isEqual:@"<missing>"]);

        // Lifecycle stop keeps the interceptors and clears weak references.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        [observedMenu setMenuItems:@[ownItem]];
        CHECK([observer.diagnostics[@"counts"][@"buildRefs"] unsignedIntegerValue] == 1);
        [observer stopForLifecycle];
        CHECK(!observer.sampling);
        CHECK(observer.installed);
        CHECK([observer.diagnostics[@"stopReason"] isEqual:@"lifecycle"]);
        CHECK([observer.diagnostics[@"counts"][@"buildRefs"] unsignedIntegerValue] == 0);

        // (4) the host's own exception propagates unchanged.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        observedMenu.raiseOnSet = YES;
        BOOL raised = NO;
        @try { [observedMenu setMenuItems:@[]]; }
        @catch (NSException *exception) { raised = [exception.name isEqual:@"SRTestHost"]; }
        observedMenu.raiseOnSet = NO;
        CHECK(raised);
        [observer stopSampling];

        // (4) an observation-side failure never skips the host call.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        clockThrows = YES;
        NSUInteger forwardBefore = observedMenu.setCalls;
        [observedMenu setMenuItems:@[]];
        CHECK(observedMenu.setCalls == forwardBefore + 1);
        clockThrows = NO;
        [observer stopSampling];

        // A delayed stop must validate the session token: an old timer can never
        // stop a newer session.
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        NSUInteger firstToken = observer.sessionToken;
        [observer stopSampling];
        CHECK([observer beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        NSUInteger secondToken = observer.sessionToken;
        CHECK(secondToken != firstToken);
        CHECK(![observer stopForDeadlineToken:firstToken]);
        CHECK(observer.sampling);
        CHECK([observer stopForDeadlineToken:secondToken]);
        CHECK(!observer.sampling);
        CHECK([observer.diagnostics[@"stopReason"] isEqual:@"timeout"]);

        // (2) a cached trampoline keeps using its own original after restore.
        Method setter = class_getInstanceMethod(SRObservedMenu.class, @selector(setMenuItems:));
        IMP cachedTrampoline = method_getImplementation(setter);
        [observer uninstall];
        CHECK(!observer.installed);
        CHECK(!observer.restoreRefused);          // cleared by a successful restore
        NSUInteger beforeCached = observedMenu.setCalls;
        ((void (*)(id, SEL, id))cachedTrampoline)(observedMenu, @selector(setMenuItems:), @[]);
        CHECK(observedMenu.setCalls == beforeCached + 1);

        // A different class pair may never reuse the same IMP slots.
        SRMenuCallObserver *crossPair = [[SRMenuCallObserver alloc] initWithClock:^NSTimeInterval { return 0; }];
        CHECK(![crossPair installOnMenuClass:SRFakeMenuController.class itemClass:SRFakeMenuItem.class error:NULL]);
        CHECK(!crossPair.installed);

        // The exact same pair may be installed again after a clean restore.
        SRMenuCallObserver *reinstall = [[SRMenuCallObserver alloc] initWithClock:^NSTimeInterval { return 8000; }];
        CHECK([reinstall installOnMenuClass:SRObservedMenu.class itemClass:SRObservedItem.class error:NULL]);
        [reinstall uninstall];
        CHECK(!reinstall.installed);

        // Closing a session with its own token still restores after an early
        // stop, while a stale token never touches a newer session.
        SRMenuCallObserver *finishObserver = [[SRMenuCallObserver alloc] initWithClock:^NSTimeInterval { return 8200; }];
        CHECK([finishObserver installOnMenuClass:SRObservedMenu.class itemClass:SRObservedItem.class error:NULL]);
        CHECK([finishObserver beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        NSUInteger finishFirst = finishObserver.sessionToken;
        [finishObserver stopSampling];
        CHECK(finishObserver.installed && !finishObserver.sampling);
        CHECK([finishObserver finishSessionWithToken:finishFirst]);      // same session restores
        CHECK(!finishObserver.installed);
        CHECK(!finishObserver.restoreRefused);
        CHECK(![finishObserver beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        CHECK([finishObserver installOnMenuClass:SRObservedMenu.class itemClass:SRObservedItem.class error:NULL]);
        CHECK([finishObserver beginSamplingWithTimeout:30 eventBudget:8 error:NULL]);
        NSUInteger finishSecond = finishObserver.sessionToken;
        CHECK(finishSecond != finishFirst);
        CHECK(![finishObserver finishSessionWithToken:finishFirst]);     // stale token: no touch
        CHECK(finishObserver.sampling && finishObserver.installed);
        CHECK([finishObserver finishSessionForDeadlineToken:finishSecond]);
        CHECK(!finishObserver.sampling && !finishObserver.installed);
        // (3) a later hook is not overwritten; a clean later restore clears the flag.
        SRMenuCallObserver *restoreObserver = [[SRMenuCallObserver alloc] initWithClock:^NSTimeInterval { return 8500; }];
        CHECK([restoreObserver installOnMenuClass:SRObservedMenu.class itemClass:SRObservedItem.class error:NULL]);
        Method restoreSetter = class_getInstanceMethod(SRObservedMenu.class, @selector(setMenuItems:));
        IMP restoreTrampoline = method_getImplementation(restoreSetter);
        gExternalHookNext = restoreTrampoline;
        method_setImplementation(restoreSetter, (IMP)SRTestExternalHook);
        NSUInteger hostBeforeRefusal = observedMenu.setCalls;
        [restoreObserver uninstall];
        CHECK(restoreObserver.installed);
        CHECK(restoreObserver.restoreRefused);
        [observedMenu setMenuItems:@[]];
        CHECK(gExternalHookCalls == 1);
        CHECK(observedMenu.setCalls == hostBeforeRefusal + 1);
        // Remove the foreign hook, then the observer can restore cleanly.
        method_setImplementation(restoreSetter, restoreTrampoline);
        gExternalHookNext = NULL;
        [restoreObserver uninstall];
        CHECK(!restoreObserver.installed);
        CHECK(!restoreObserver.restoreRefused);
        [observedMenu setMenuItems:@[]];
        CHECK(observedMenu.setCalls == hostBeforeRefusal + 2);

        // (1b) initialization ownership through the one allowed pair.
        SRMenuCallObserver *initObserver = [[SRMenuCallObserver alloc] initWithClock:^NSTimeInterval { return 9000; }];
        CHECK([initObserver installOnMenuClass:SRObservedMenu.class itemClass:SRObservedItem.class error:NULL]);
        gItemInitMode = 2;
        id replaced = [[SRObservedItem alloc] initWithTitle:nil icon:nil target:nil action:NULL];
        CHECK(replaced != nil && ![replaced isKindOfClass:SRObservedItem.class]);
        gItemInitMode = 1;
        id nilResult = [[SRObservedItem alloc] initWithTitle:nil icon:nil target:nil action:NULL];
        CHECK(nilResult == nil);
        gItemInitMode = 0;
        __weak SRObservedItem *weakOwned = nil;
        @autoreleasepool {
            SRObservedItem *owned = [[SRObservedItem alloc] initWithTitle:@"ownership-title" icon:nil
                target:nil action:NULL];
            CHECK(owned != nil);
            weakOwned = owned;
        }
        CHECK(weakOwned == nil);
        [initObserver uninstall];
        CHECK(!initObserver.installed);

        // (1) a same-pair reinstall is refused when a foreign hook now fronts the
        // cached trampoline: rebinding would build T -> H -> T recursion.
        SRMenuCallObserver *loopObserver = [[SRMenuCallObserver alloc] initWithClock:^NSTimeInterval { return 9500; }];
        CHECK([loopObserver installOnMenuClass:SRObservedMenu.class itemClass:SRObservedItem.class error:NULL]);
        Method loopSetter = class_getInstanceMethod(SRObservedMenu.class, @selector(setMenuItems:));
        Method loopInitializer = class_getInstanceMethod(SRObservedItem.class,
            @selector(initWithTitle:icon:target:action:));
        IMP loopTrampoline = method_getImplementation(loopSetter);
        [loopObserver uninstall];
        CHECK(!loopObserver.installed);
        gExternalHookNext = loopTrampoline;
        method_setImplementation(loopSetter, (IMP)SRTestExternalHook);
        IMP setterBeforeRefusal = method_getImplementation(loopSetter);
        IMP initBeforeRefusal = method_getImplementation(loopInitializer);
        SRMenuCallObserver *rebindObserver = [[SRMenuCallObserver alloc] initWithClock:^NSTimeInterval { return 9600; }];
        CHECK(![rebindObserver installOnMenuClass:SRObservedMenu.class itemClass:SRObservedItem.class error:NULL]);
        CHECK(!rebindObserver.installed);
        // The refusal moved no IMP at all.
        CHECK(method_getImplementation(loopSetter) == setterBeforeRefusal);
        CHECK(method_getImplementation(loopInitializer) == initBeforeRefusal);
        NSUInteger hookBefore = gExternalHookCalls;
        NSUInteger hostBeforeLoop = observedMenu.setCalls;
        [observedMenu setMenuItems:@[]];
        CHECK(gExternalHookCalls == hookBefore + 1);
        CHECK(observedMenu.setCalls == hostBeforeLoop + 1);   // H -> cached T -> original, once

        [defaults removePersistentDomainForName:@"andyz.syncrelay.menutest"];
        CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: the menu adapter follows its own display switch, appends one owned item, keeps "
             "foreign items and non-own clicks, refuses stale contexts and saves one intent per operation; "
             "the call observer is bounded, transparent and never overwrites a later hook");
    }
    return 0;
}
