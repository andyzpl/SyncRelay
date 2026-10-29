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

        [defaults removePersistentDomainForName:@"andyz.syncrelay.menutest"];
        CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: the menu adapter follows its own display switch, appends one owned item, keeps "
             "foreign items and non-own clicks, refuses stale contexts and saves one intent per operation");
    }
    return 0;
}
