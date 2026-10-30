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
- (instancetype)initWithTitle:(id)title icon:(id)icon target:(id)target action:(SEL)action;
@end
@implementation SRFakeMenuItem
- (instancetype)initWithTitle:(id)title icon:(id)icon target:(id)target action:(SEL)action {
    self = [super init]; (void)title; (void)icon; (void)target; (void)action; return self;
}
@end

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
@interface SRObservedMenu : NSObject
@property(nonatomic) NSUInteger setCalls;
@property(nonatomic) NSUInteger selectCalls;
@property(nonatomic) BOOL raiseOnSet;
@property(nonatomic, strong) NSArray *lastItems;
@property(nonatomic, strong) id lastItem;
@property(nonatomic, strong) id lastView;
- (void)observeAction:(id)item;
@end
@implementation SRObservedMenu
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

@interface SRObservedItem : NSObject
- (instancetype)initWithTitle:(id)title icon:(id)icon target:(id)target action:(SEL)action;
@end
/* The original implementation's behaviour is switched here so the init-family
 * ownership cases can all use the one allowed class pair. 0 = self,
 * 1 = nil, 2 = replacement object. */
static NSInteger gItemInitMode = 0;
@implementation SRObservedItem
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

static SRMenuMessageContext *makeContext(NSString *account, NSString *body, NSString *identity, NSString *key) {
    // The snapshot is only constructible through its designated initializer now.
    return [[SRMenuMessageContext alloc] initWithAccount:account body:body generation:@"g1"
        ownerToken:@"owner-1" messageIdentity:identity operationKey:key];
}

static SRMenuCurrentIdentity *currentIdentity(NSString *account, NSString *owner,
                                               NSString *generation, NSString *message) {
    return [[SRMenuCurrentIdentity alloc] initWithAccount:account ownerToken:owner
        generation:generation messageIdentity:message];
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
            body:mBody generation:mGeneration ownerToken:@"owner-freeze" messageIdentity:mIdentity operationKey:mKey];
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
        SRMenuCallObserver *observer = [[SRMenuCallObserver alloc] initWithClock:^NSTimeInterval {
            if (clockThrows) @throw [NSException exceptionWithName:@"SRTestClock" reason:@"clock" userInfo:nil];
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
        CHECK([observedText rangeOfString:@"SRObserved"].location == NSNotFound);
        CHECK([observedText rangeOfString:@"SRTwin"].location == NSNotFound);
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

        // That session is still running as well: stop it before the lifecycle one.
        CHECK(observer.sampling);
        [observer stopSampling];
        CHECK(!observer.sampling);

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
