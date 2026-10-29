#import "SRMessageMenuHook.h"
#import "Core/SRLibraryIntake.h"
#import <objc/runtime.h>
#include <stdlib.h>

/* The item this pure adapter appends in tests. A future, ABI-verified entry
 * layer must adapt this marker to the host menu item without changing the
 * frozen context or claiming another tweak's object. */
@interface SRMenuOwnItem : NSObject
@property(nonatomic, strong) SRMenuMessageContext *context;
@end
@implementation SRMenuOwnItem
@end

/* Private storage with hand-written getters. The public header declares only
 * readonly properties, and no setter is synthesised here, so a frozen
 * confirmation cannot be rewritten through the runtime after the fact. */
@implementation SRMenuMessageContext {
    NSString *_account;
    NSString *_body;
    NSString *_generation;
    NSString *_ownerToken;
    NSString *_messageIdentity;
    NSString *_operationKey;
}
- (instancetype)initWithAccount:(NSString *)account body:(NSString *)body generation:(NSString *)generation
                     ownerToken:(NSString *)ownerToken messageIdentity:(NSString *)messageIdentity
                operationKey:(NSString *)operationKey {
    self = [super init];
    if (self) {
        // copy, not retain: a caller's NSMutableString cannot change this later.
        _account = [account copy];
        _body = [body copy];
        _generation = [generation copy];
        _ownerToken = [ownerToken copy];
        _messageIdentity = [messageIdentity copy];
        _operationKey = [operationKey copy];
    }
    return self;
}
- (NSString *)account { return _account; }
- (NSString *)body { return _body; }
- (NSString *)generation { return _generation; }
- (NSString *)ownerToken { return _ownerToken; }
- (NSString *)messageIdentity { return _messageIdentity; }
- (NSString *)operationKey { return _operationKey; }
@end

@implementation SRMenuCurrentIdentity {
    NSString *_account;
    NSString *_ownerToken;
    NSString *_generation;
    NSString *_messageIdentity;
}
- (instancetype)initWithAccount:(NSString *)account ownerToken:(NSString *)ownerToken
                      generation:(NSString *)generation messageIdentity:(NSString *)messageIdentity {
    self = [super init];
    if (self) {
        _account = [account copy];
        _ownerToken = [ownerToken copy];
        _generation = [generation copy];
        _messageIdentity = [messageIdentity copy];
    }
    return self;
}
- (NSString *)account { return _account; }
- (NSString *)ownerToken { return _ownerToken; }
- (NSString *)generation { return _generation; }
- (NSString *)messageIdentity { return _messageIdentity; }
@end

@interface SRMessageMenuHook ()
@property(nonatomic, strong) SRLibraryIntake *intake;
@property(nonatomic, copy, nullable) NSString * (^currentAccount)(void);
@property(nonatomic, copy, nullable) BOOL (^accountActive)(NSString *account);
/* Read at append time and again at click time: turning the preference off
 * must also refuse an item that is already on screen. */
@property(nonatomic, copy, nullable) BOOL (^enabled)(void);
@property(nonatomic) BOOL installed;
/* item object -> frozen context. Keys are weak so an old menu item can be
 * forgotten when the host releases it; keeping the mapping across generations
 * separates ownership (is this ours?) from validity (is it still current?). */
@property(nonatomic, strong) NSMapTable *contexts;
/* The generation currently being rendered. Older owned items are stale, not
 * foreign, even while a reused host cell still retains them. */
@property(nonatomic, copy) NSString *activeGeneration;
/* The exact owned item currently published for that generation. A replacement
 * with the same generation is still stale if the host rebuilt the array without
 * the previous item. */
@property(nonatomic, weak) id activeItem;
@property(nonatomic, strong) NSObject *lock;
@end

@implementation SRMessageMenuHook

- (instancetype)initWithIntake:(SRLibraryIntake *)intake
                currentAccount:(NSString * _Nullable (^)(void))currentAccount
                 accountActive:(BOOL (^)(NSString *))accountActive
                       enabled:(BOOL (^)(void))enabled {
    self = [super init];
    if (self) {
        _intake = intake;
        _currentAccount = [currentAccount copy];
        _accountActive = [accountActive copy];
        _enabled = [enabled copy];
        _contexts = [[NSMapTable alloc]
            initWithKeyOptions:(NSPointerFunctionsWeakMemory | NSPointerFunctionsOpaquePersonality)
            valueOptions:NSPointerFunctionsStrongMemory capacity:0];
        _lock = [NSObject new];
        _activeGeneration = @"";
    }
    return self;
}


/* Qualifiers may precede the type character; nothing else is ignored. */
static char *SRTypeStart(char *type) {
    if (!type) return NULL;
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' || *type == 'O' ||
           *type == 'R' || *type == 'V') type++;
    return type;
}

/* A plain object is `@`; `@?` is a block and is a different class. */
static BOOL SRObjectType(char *type) {
    char *start = SRTypeStart(type);
    if (!start || *start != '@') return NO;
    return start[1] != '?';
}

static BOOL SRSELType(char *type) {
    char *start = SRTypeStart(type);
    return start != NULL && *start == ':';
}

static BOOL SRVoidType(char *type) {
    char *start = SRTypeStart(type);
    return start != NULL && *start == 'v';
}

/* Every candidate method must take a plain object self and a SEL _cmd. */
static BOOL SRImplicitParametersMatch(Method method) {
    char *selfType = method_copyArgumentType(method, 0);
    BOOL selfOK = SRObjectType(selfType);
    free(selfType);
    char *commandType = method_copyArgumentType(method, 1);
    BOOL commandOK = SRSELType(commandType);
    free(commandType);
    return selfOK && commandOK;
}

- (SRMenuGateStatus)gateMenuClass:(Class)menuClass itemClass:(Class)itemClass {
    if (!menuClass || !itemClass) return SRMenuGateClassMissing;
    Method setter = class_getInstanceMethod(menuClass, NSSelectorFromString(@"setMenuItems:"));
    Method selection = class_getInstanceMethod(menuClass, NSSelectorFromString(@"onMenuItemSelected:itemView:"));
    Method initializer = class_getInstanceMethod(itemClass, NSSelectorFromString(@"initWithTitle:icon:target:action:"));
    // A class method is not returned here, which is the intended refusal: all
    // three candidates must be instance methods.
    if (!setter || !selection || !initializer) return SRMenuGateMethodMissing;

    // self, _cmd and the declared arguments.
    if (method_getNumberOfArguments(setter) != 3) return SRMenuGateEncodingMismatch;
    if (method_getNumberOfArguments(selection) != 4) return SRMenuGateEncodingMismatch;
    if (method_getNumberOfArguments(initializer) != 6) return SRMenuGateEncodingMismatch;

    // Implicit parameters are part of the signature, not an assumption.
    if (!SRImplicitParametersMatch(setter) || !SRImplicitParametersMatch(selection) ||
        !SRImplicitParametersMatch(initializer)) return SRMenuGateEncodingMismatch;

    SRMenuGateStatus status = SRMenuGateMatched;
    char *type = NULL;

    type = method_copyReturnType(setter);
    if (!SRVoidType(type)) status = SRMenuGateEncodingMismatch;
    free(type);

    if (status == SRMenuGateMatched) {
        type = method_copyArgumentType(setter, 2);
        if (!SRObjectType(type)) status = SRMenuGateEncodingMismatch;
        free(type);
    }
    if (status == SRMenuGateMatched) {
        type = method_copyReturnType(selection);
        if (!SRVoidType(type)) status = SRMenuGateEncodingMismatch;
        free(type);
    }
    for (unsigned int index = 2; index <= 3 && status == SRMenuGateMatched; index++) {
        type = method_copyArgumentType(selection, index);
        if (!SRObjectType(type)) status = SRMenuGateEncodingMismatch;
        free(type);
    }
    if (status == SRMenuGateMatched) {
        type = method_copyReturnType(initializer);
        if (!SRObjectType(type)) status = SRMenuGateEncodingMismatch;
        free(type);
    }
    for (unsigned int index = 2; index <= 4 && status == SRMenuGateMatched; index++) {
        type = method_copyArgumentType(initializer, index);
        if (!SRObjectType(type)) status = SRMenuGateEncodingMismatch;
        free(type);
    }
    if (status == SRMenuGateMatched) {
        type = method_copyArgumentType(initializer, 5);
        if (!SRSELType(type)) status = SRMenuGateEncodingMismatch;
        free(type);
    }
    return status;
}


- (BOOL)isInstalled { return self.installed; }
- (void)markInstalled { self.installed = YES; }

- (NSArray *)appendOwnItemToItems:(NSArray *)items generation:(NSString *)generation
                           source:(SRMenuMessageContext *)source {
    NSArray *original = [items isKindOfClass:NSArray.class] ? items : @[];
    // Off means transparent: the host array is returned untouched.
    if (!self.enabled || !self.enabled()) return original;
    @synchronized(self.lock) {
        // Rebuilding the same generation is idempotent only when the incoming
        // array still contains our own item. If a host rebuilt the array from
        // foreign items alone, append the item again rather than silently
        // dropping the entry.
        if ([self.activeGeneration isEqual:generation] && self.activeItem) {
            BOOL foundActive = NO;
            BOOL hasOtherOwn = NO;
            for (id item in original) {
                if (![self.contexts objectForKey:item]) continue;
                if (item == self.activeItem && !foundActive) foundActive = YES;
                else hasOtherOwn = YES;
            }
            if (foundActive && !hasOtherOwn) return original;
            if (foundActive) {
                NSMutableArray *normalized = [NSMutableArray arrayWithCapacity:original.count];
                BOOL addedActive = NO;
                for (id item in original) {
                    if (item == self.activeItem) {
                        if (!addedActive) [normalized addObject:item];
                        addedActive = YES;
                    }
                    else if (![self.contexts objectForKey:item]) [normalized addObject:item];
                }
                return [normalized copy];
            }
        }
        SRMenuOwnItem *own = [SRMenuOwnItem new];
        /* Freeze by value through the designated initializer. The caller's object
         * is neither stored nor mutated: editing its own mutable strings, or the
         * source object, afterwards cannot change what this item will save. */
        SRMenuMessageContext *frozen = [[SRMenuMessageContext alloc]
            initWithAccount:source.account body:source.body generation:generation
            ownerToken:source.ownerToken messageIdentity:source.messageIdentity
            operationKey:source.operationKey];
        own.context = frozen;
        [self.contexts setObject:frozen forKey:own];
        self.activeGeneration = [generation copy];
        self.activeItem = own;
        NSMutableArray *published = [NSMutableArray arrayWithCapacity:original.count + 1];
        for (id item in original) {
            // Remove only items created by this adapter. Foreign objects,
            // including same-titled items from other tweaks, retain identity
            // and order exactly as received.
            if (![self.contexts objectForKey:item]) [published addObject:item];
        }
        [published addObject:own];
        return [published copy];
    }
}

- (BOOL)ownsItem:(id)item {
    if (!item) return NO;
    @synchronized(self.lock) { return [self.contexts objectForKey:item] != nil; }
}

- (SRMenuMessageContext *)contextForOwnItem:(id)item {
    if (!item) return nil;
    @synchronized(self.lock) { return [self.contexts objectForKey:item]; }
}

- (SRMenuIntentResult)handleSelection:(id)item current:(SRMenuCurrentIdentity *)current {
    SRMenuMessageContext *context = [self contextForOwnItem:item];
    if (!context) return SRMenuIntentNotOurs;
    if (!self.enabled || !self.enabled()) return SRMenuIntentDisabled;
    // Identity is re-checked at click time: the independently observed menu,
    // account and selected message must still be the ones this item was built
    // for. Missing identity is stale, never a wildcard.
    if (!current.account.length || !current.ownerToken.length || !current.generation.length ||
        !current.messageIdentity.length) return SRMenuIntentContextStale;
    if (![context.account isEqual:current.account] ||
        ![context.ownerToken isEqual:current.ownerToken] ||
        ![context.generation isEqual:current.generation] ||
        ![context.messageIdentity isEqual:current.messageIdentity]) {
        return SRMenuIntentContextStale;
    }
    @synchronized(self.lock) {
        if (self.activeItem != item || ![context.generation isEqual:self.activeGeneration]) {
            return SRMenuIntentContextStale;
        }
    }
    // Both callbacks are independent runtime checks. Missing verification is
    // treated as stale rather than as an implicit allow.
    if (!self.currentAccount || !self.accountActive) return SRMenuIntentContextStale;
    NSString * _Nullable liveAccount = self.currentAccount();
    if (!liveAccount.length || ![liveAccount isEqual:current.account]) return SRMenuIntentContextStale;
    if (!self.accountActive(current.account)) return SRMenuIntentContextStale;
    // Intake owns operation idempotence and conflict handling. The adapter must
    // not maintain a second success ledger that could hide a store failure or
    // answer a replay without consulting the durable source of truth.
    SRLibraryIntakeResult result = SRLibraryIntakeWriteFailed;
    NSString *itemID = [self.intake saveMessageOfType:@"text" payload:@{@"text": context.body}
        operationKey:context.operationKey account:context.account
        capturedAt:NSDate.date.timeIntervalSince1970 result:&result error:NULL];
    switch (result) {
        case SRLibraryIntakeSaved: return SRMenuIntentSaved;
        case SRLibraryIntakeDuplicate: return SRMenuIntentDuplicate;
        case SRLibraryIntakeUnsupportedType: return SRMenuIntentUnsupported;
        case SRLibraryIntakeAccountUnavailable:
        case SRLibraryIntakeStoreUnavailable: return SRMenuIntentStorageUnavailable;
        case SRLibraryIntakeInvalidInput:
        case SRLibraryIntakeConflictingRequest:
        case SRLibraryIntakeWriteFailed: return SRMenuIntentWriteFailed;
    }
    return itemID.length ? SRMenuIntentSaved : SRMenuIntentWriteFailed;
}

@end
