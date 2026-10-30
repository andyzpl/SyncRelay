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

/* -------------------------------------------------------------------------
 * Observation-only menu call observer.
 *
 * One installer per process. The three IMPs are replaced only after the direct
 * method declarations are fully validated; every host call is forwarded to the
 * original implementation exactly once, and observation failures are isolated
 * from that forwarding. Only fixed labels, integers and booleans are exported.
 * ---------------------------------------------------------------------- */

#include <mach/mach_time.h>
#include <math.h>

typedef id (*SRMenuObserverInitIMP)(id, SEL, id, id, id, SEL) __attribute__((ns_returns_retained));

static NSObject *SRMenuObserverGlobalLock;
static dispatch_once_t SRMenuObserverGlobalOnce;
/* The single owner of the process-wide interception. Non-nil means the three
 * trampolines are installed by that observer and still forward. */
static SRMenuCallObserver *SRMenuObserverOwner;
static IMP SRMenuObserverMenuSetIMP;
static IMP SRMenuObserverMenuSelectIMP;
static IMP SRMenuObserverItemInitIMP;
/* Cached trampolines from an earlier install keep reading the same three IMP
 * slots, so a later install may only reuse the exact class pair. A different
 * pair would make an old entry call another class's original. */
static Class SRMenuObserverInstalledMenuClass;
static Class SRMenuObserverInstalledItemClass;
static BOOL SRMenuObserverEverInstalled;

static const NSTimeInterval SRMenuObserverMaxTimeout = 300;
static const NSUInteger SRMenuObserverMaxBudget = 256;
/* Slots kept free so construction/build events can never starve a selection. */
static const NSUInteger SRMenuObserverSelectReserve = 4;
static const NSUInteger SRMenuObserverInitLimit = 8;
static const NSUInteger SRMenuObserverBuildLimit = 8;
static const NSUInteger SRMenuObserverSelectLimit = 16;
/* One build event inspects at most this many items. */
static const NSUInteger SRMenuObserverItemCap = 64;

/* Bounded metadata caps: entries, retained init results, one symbol length and
 * the number of declared arguments copied into a signature token. */
static const NSUInteger SRMenuObserverMetadataCap = 12;
static const NSUInteger SRMenuObserverInitLinkCap = 4;
static const NSUInteger SRMenuObserverTokenCap = 48;
static const NSUInteger SRMenuObserverSignatureArgCap = 8;

/* buildState values, exported as fixed strings. Only `complete` allows a
 * definite not_seen answer. */
static const NSInteger SRMenuObserverBuildNone = 0;
static const NSInteger SRMenuObserverBuildComplete = 1;
static const NSInteger SRMenuObserverBuildTruncated = 2;
static const NSInteger SRMenuObserverBuildStale = 3;

static NSObject *SRMenuObserverLock(void) {
    dispatch_once(&SRMenuObserverGlobalOnce, ^{ SRMenuObserverGlobalLock = [NSObject new]; });
    return SRMenuObserverGlobalLock;
}

/* Monotonic seconds; wall-clock jumps cannot extend or shorten a session. */
static NSTimeInterval SRMenuObserverMonotonic(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    return (NSTimeInterval)mach_absolute_time() * (NSTimeInterval)timebase.numer /
        (NSTimeInterval)timebase.denom / 1e9;
}

@interface SRMenuCallObserver (SRRecording)
- (void)recordBuildWithItems:(id)items receiver:(id)receiver;
- (void)recordSelectionItem:(id)item itemView:(id)view receiver:(id)receiver;
- (void)recordInitWithTitle:(id)title icon:(id)icon target:(id)target action:(SEL)action result:(id)result;
@end

/* Sanitized runtime symbol: letters, digits, '_', '.', '$' and ':' only. An
 * empty value, a value over the cap, or one with stripped characters becomes an
 * explicit marker instead of a truncated symbol, so no decision rests on a
 * clipped name. */
static NSString *SRMenuMetadataToken(NSString *value) {
    if (!value) return @"<nil>";
    if (![value isKindOfClass:NSString.class] || value.length == 0) return @"<missing>";
    if (value.length > SRMenuObserverTokenCap) return @"<truncated>";
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.$:"];
    for (NSUInteger index = 0; index < value.length; index++) {
        if (![allowed characterIsMember:[value characterAtIndex:index]]) return @"<truncated>";
    }
    return value;
}

/* Normalized type token. Only the first encoding character is classified; the
 * full encoding is never exported. */
static NSString *SRMenuTypeToken(const char *type) {
    if (!type || !type[0]) return @"<missing>";
    switch (type[0]) {
        case '@': return type[1] == '?' ? @"block" : @"object";
        case '#': return @"class";
        case ':': return @"sel";
        case 'v': return @"void";
        case 'c': return @"char";
        case 'i': return @"int";
        case 's': return @"short";
        case 'l': return @"long";
        case 'q': return @"longlong";
        case 'C': return @"uchar";
        case 'I': return @"uint";
        case 'S': return @"ushort";
        case 'L': return @"ulong";
        case 'Q': return @"ulonglong";
        case 'f': return @"float";
        case 'd': return @"double";
        case 'B': return @"bool";
        case '*': return @"charptr";
        case '^': return @"pointer";
        case '[': return @"array";
        case '{': return @"struct";
        case '(': return @"union";
        case 'b': return @"bitfield";
        default: return @"unknown";
    }
}

/* Declared signature of the action, as normalized tokens, from the Method that
 * the direct method-list walk already returned. Metadata only: the action is
 * never called, no getter is invoked and no resolver is triggered. */
static NSString *SRMenuMetadataSignature(Method method) {
    if (!method) return @"<undeclared>";
    char *returnType = method_copyReturnType(method);
    NSMutableString *text = [NSMutableString stringWithFormat:@"ret=%@;args=", SRMenuTypeToken(returnType)];
    free(returnType);
    NSUInteger count = method_getNumberOfArguments(method);
    NSUInteger limit = MIN(count, SRMenuObserverSignatureArgCap);
    for (NSUInteger index = 0; index < limit; index++) {
        char *argument = method_copyArgumentType(method, index);
        if (index) [text appendString:@","];
        [text appendString:SRMenuTypeToken(argument)];
        free(argument);
    }
    if (count > limit) [text appendString:@",<overflow>"];
    return text;
}

/* Trampolines read the published context under the global lock, isolate the
 * observation, and forward exactly once. Exceptions from the original
 * implementation are never caught here. */
static void SRMenuObserverSetItems(id self, SEL command, id items) {
    IMP original; SRMenuCallObserver *observer;
    @synchronized(SRMenuObserverLock()) {
        original = SRMenuObserverMenuSetIMP;
        observer = SRMenuObserverOwner;
    }
    if (observer) @try {
        [observer recordBuildWithItems:items receiver:self];
    } @catch (__unused NSException *exception) {
        // An observation failure must never replace or skip the host call.
    }
    if (original) ((void (*)(id, SEL, id))original)(self, command, items);
}

static void SRMenuObserverSelect(id self, SEL command, id item, id view) {
    IMP original; SRMenuCallObserver *observer;
    @synchronized(SRMenuObserverLock()) {
        original = SRMenuObserverMenuSelectIMP;
        observer = SRMenuObserverOwner;
    }
    if (observer) @try {
        [observer recordSelectionItem:item itemView:view receiver:self];
    } @catch (__unused NSException *exception) {
    }
    if (original) ((void (*)(id, SEL, id, id))original)(self, command, item, view);
}

static id SRMenuObserverInit(id self, SEL command, id title, id icon, id target, SEL action)
    __attribute__((ns_returns_retained)) {
    IMP original; SRMenuCallObserver *observer;
    @synchronized(SRMenuObserverLock()) {
        original = SRMenuObserverItemInitIMP;
        observer = SRMenuObserverOwner;
    }
    if (!original) return nil;
    id result = ((SRMenuObserverInitIMP)original)(self, command, title, icon, target, action);
    if (observer) @try {
        [observer recordInitWithTitle:title icon:icon target:target action:action result:result];
    } @catch (__unused NSException *exception) {
    }
    return result;
}

/* Directly declared method on this exact class: no superclass walk (an
 * inherited method is not ours to replace) and no dynamic resolution. */
static Method SRMenuDirectMethod(Class cls, SEL selector) {
    if (!cls) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return NULL;
    Method found = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) != selector) continue;
        found = methods[index];
        break;
    }
    free(methods);
    return found;
}

static BOOL SRMenuObserverArgumentIsObject(Method method, unsigned int index) {
    char *type = method_copyArgumentType(method, index);
    BOOL matches = SRObjectType(type);
    free(type);
    return matches;
}
static BOOL SRMenuObserverArgumentIsSEL(Method method, unsigned int index) {
    char *type = method_copyArgumentType(method, index);
    BOOL matches = SRSELType(type);
    free(type);
    return matches;
}
static BOOL SRMenuObserverReturnIsVoid(Method method) {
    char *type = method_copyReturnType(method);
    BOOL matches = SRVoidType(type);
    free(type);
    return matches;
}
static BOOL SRMenuObserverReturnIsObject(Method method) {
    char *type = method_copyReturnType(method);
    BOOL matches = SRObjectType(type);
    free(type);
    return matches;
}

/* void (self, _cmd, object[, object]) with an object self and SEL _cmd. */
static BOOL SRMenuObserverValidateMenuMethod(Method method, unsigned int argumentCount) {
    if (!method || method_getNumberOfArguments(method) != argumentCount) return NO;
    if (!SRMenuObserverReturnIsVoid(method)) return NO;
    if (!SRMenuObserverArgumentIsObject(method, 0)) return NO;
    if (!SRMenuObserverArgumentIsSEL(method, 1)) return NO;
    for (unsigned int index = 2; index < argumentCount; index++) {
        if (!SRMenuObserverArgumentIsObject(method, index)) return NO;
    }
    return YES;
}

/* object (self, _cmd, object, object, object, SEL). */
static BOOL SRMenuObserverValidateInitializer(Method method) {
    if (!method || method_getNumberOfArguments(method) != 6) return NO;
    if (!SRMenuObserverReturnIsObject(method)) return NO;
    if (!SRMenuObserverArgumentIsObject(method, 0)) return NO;
    if (!SRMenuObserverArgumentIsSEL(method, 1)) return NO;
    for (unsigned int index = 2; index <= 4; index++) {
        if (!SRMenuObserverArgumentIsObject(method, index)) return NO;
    }
    return SRMenuObserverArgumentIsSEL(method, 5);
}

/* Declared-method metadata only: walks the real method list of the observed
 * target's class and its superclasses. It never calls the action, never asks the
 * runtime to resolve anything and never triggers +resolveInstanceMethod:. The
 * declared Method itself is returned so the signature and the argument count
 * both come from the same walk. */
static Method SRMenuDeclaredMethodInfo(id target, SEL action, NSUInteger *argumentCount) {
    if (!target || !action) return NULL;
    for (Class current = object_getClass(target); current != Nil; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        if (!methods) continue;
        for (unsigned int index = 0; index < count; index++) {
            if (method_getName(methods[index]) != action) continue;
            Method found = methods[index];
            if (argumentCount) *argumentCount = method_getNumberOfArguments(found);
            free(methods);
            return found;
        }
        free(methods);
    }
    return NULL;
}


@interface SRMenuCallObserver ()
@property(nonatomic, copy, nonnull) NSTimeInterval (^clock)(void);
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *events;
/* Pointer identity only: no -hash or -isEqual is sent to observed objects. */
@property(nonatomic, strong) NSHashTable *buildItems;
/* Bounded metadata area, separate from the event list. */
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *metadata;
/* Weak, identity-only construction link: result object -> metadata index.
 * No -hash/-isEqual is sent to a host object and nothing is retained. */
@property(nonatomic, strong) NSMapTable *constructedIndex;
/* Constructions whose metadata index did not fit the metadata cap. */
@property(nonatomic, strong) NSHashTable *droppedConstructs;
@property(nonatomic) NSUInteger metadataDropped;
@property(nonatomic) BOOL initLinksTruncated;
@property(nonatomic, strong) NSObject *lock;
/* Session token: a snapshot taken before touching host code is only committed
 * if the session is still the same when the lock is taken again. */
@property(nonatomic) NSUInteger session;
/* How much of the last build array was actually inspected:
 * none = no build yet, complete = every element, truncated = cap reached,
 * stale = the last build was skipped or the container was rejected. */
@property(nonatomic) NSInteger buildState;
@property(nonatomic) BOOL installed;
@property(nonatomic) BOOL sampling;
@property(nonatomic) BOOL restoreRefused;
@property(nonatomic) SRMenuCallObserverState state;
@property(nonatomic, copy) NSString *stopReason;
@property(nonatomic) NSTimeInterval deadline;
@property(nonatomic) NSUInteger budget;
@property(nonatomic) NSUInteger initCount;
@property(nonatomic) NSUInteger buildCount;
@property(nonatomic) NSUInteger selectCount;
@property(nonatomic) NSUInteger droppedCount;
@property(nonatomic) Method setterMethod;
@property(nonatomic) Method selectionMethod;
@property(nonatomic) Method initializerMethod;
@property(nonatomic) Class menuClass;
@property(nonatomic) Class itemClass;
@end

@implementation SRMenuCallObserver

- (instancetype)init {
    return [self initWithClock:^NSTimeInterval { return SRMenuObserverMonotonic(); }];
}

- (instancetype)initWithClock:(NSTimeInterval (^)(void))clock {
    self = [super init];
    if (self) {
        _clock = [clock copy];
        _events = [NSMutableArray array];
        _buildItems = [NSHashTable hashTableWithOptions:
            (NSPointerFunctionsWeakMemory | NSPointerFunctionsOpaquePersonality)];
        _metadata = [NSMutableArray array];
        _constructedIndex = [NSMapTable mapTableWithKeyOptions:
                (NSPointerFunctionsWeakMemory | NSPointerFunctionsOpaquePersonality)
            valueOptions:NSPointerFunctionsStrongMemory];
        _droppedConstructs = [NSHashTable hashTableWithOptions:
            (NSPointerFunctionsWeakMemory | NSPointerFunctionsOpaquePersonality)];
        _lock = [NSObject new];
        _stopReason = @"";
        _state = SRMenuCallObserverIdle;
    }
    return self;
}

- (BOOL)installed { return _installed; }
- (BOOL)restoreRefused { return _restoreRefused; }
- (SRMenuCallObserverState)state { return _state; }

- (BOOL)sampling {
    if (!_sampling) return NO;
    NSTimeInterval now = self.clock();
    if (isfinite(now) && now < _deadline) return YES;
    [self stopBecause:@"timeout"];
    return NO;
}

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:@"SyncRelay.MenuObserver" code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (BOOL)installOnMenuClass:(Class)menuClass itemClass:(Class)itemClass error:(NSError **)error {
    @synchronized(SRMenuObserverLock()) {
        // One installer per process: a second instance cannot overwrite the
        // file-static originals or publish a conflicting context.
        if (SRMenuObserverOwner || _installed) {
            if (error) *error = [self errorWithCode:1 message:@"A menu observer is already installed"];
            return NO;
        }
        // A trampoline cached by an earlier install still reads the same three
        // IMP slots. Reusing those slots for another class pair would make the
        // old entry call the wrong class's original, so a different pair is
        // refused permanently.
        if (SRMenuObserverEverInstalled &&
            (menuClass != SRMenuObserverInstalledMenuClass || itemClass != SRMenuObserverInstalledItemClass)) {
            if (error) *error = [self errorWithCode:7 message:@"A different class pair cannot reuse the observer"];
            return NO;
        }
        Method setter = SRMenuDirectMethod(menuClass, NSSelectorFromString(@"setMenuItems:"));
        Method selection = SRMenuDirectMethod(menuClass, NSSelectorFromString(@"onMenuItemSelected:itemView:"));
        Method initializer = SRMenuDirectMethod(itemClass, NSSelectorFromString(@"initWithTitle:icon:target:action:"));
        // Nothing is mutated until all three direct declarations validate.
        if (!SRMenuObserverValidateMenuMethod(setter, 3) ||
            !SRMenuObserverValidateMenuMethod(selection, 4) ||
            !SRMenuObserverValidateInitializer(initializer)) {
            if (error) *error = [self errorWithCode:2 message:@"A candidate method is missing, inherited or has the wrong signature"];
            return NO;
        }
        // Re-installing rebinds the published forwarding context. If the
        // current chain is no longer the originals we restored, a foreign hook
        // is in front of a cached trampoline; installing again would create a
        // loop (T -> H -> T). Refuse before touching any IMP.
        if (SRMenuObserverEverInstalled &&
            (method_getImplementation(setter) != SRMenuObserverMenuSetIMP ||
             method_getImplementation(selection) != SRMenuObserverMenuSelectIMP ||
             method_getImplementation(initializer) != SRMenuObserverItemInitIMP)) {
            if (error) *error = [self errorWithCode:8 message:@"The current chain changed; refusing to rebind"];
            return NO;
        }
        // The displaced IMP comes from the same call that installs ours, so the
        // saved chain is exactly what was replaced.
        SRMenuObserverMenuSetIMP = method_setImplementation(setter, (IMP)SRMenuObserverSetItems);
        SRMenuObserverMenuSelectIMP = method_setImplementation(selection, (IMP)SRMenuObserverSelect);
        SRMenuObserverItemInitIMP = method_setImplementation(initializer, (IMP)SRMenuObserverInit);
        self.setterMethod = setter;
        self.selectionMethod = selection;
        self.initializerMethod = initializer;
        self.menuClass = menuClass;
        self.itemClass = itemClass;
        SRMenuObserverInstalledMenuClass = menuClass;
        SRMenuObserverInstalledItemClass = itemClass;
        SRMenuObserverEverInstalled = YES;
        SRMenuObserverOwner = self;
        _installed = YES;
        _restoreRefused = NO;
        _state = SRMenuCallObserverInstalled;
        return YES;
    }
}

- (BOOL)beginSamplingWithTimeout:(NSTimeInterval)timeout eventBudget:(NSUInteger)eventBudget
                           error:(NSError **)error {
    // Lock order is always global then instance, so install, stop, uninstall and
    // the published forwarding context cannot interleave with a session start.
    @synchronized(SRMenuObserverLock()) {
        if (!_installed) {
            if (error) *error = [self errorWithCode:3 message:@"Menu observer is not installed"];
            return NO;
        }
        @synchronized(self.lock) {
            if (_sampling) {
                if (error) *error = [self errorWithCode:4 message:@"A menu observation session is already running"];
                return NO;
            }
            // Unsupported configurations are refused instead of silently clamped.
            if (!isfinite(timeout) || timeout <= 0 || timeout > SRMenuObserverMaxTimeout) {
                if (error) *error = [self errorWithCode:5 message:@"The timeout is not a supported finite value"];
                return NO;
            }
            if (eventBudget < SRMenuObserverSelectReserve + 1 || eventBudget > SRMenuObserverMaxBudget) {
                if (error) *error = [self errorWithCode:6 message:@"The event budget is not supported"];
                return NO;
            }
            [self.events removeAllObjects];
            [self.buildItems removeAllObjects];
            [self.metadata removeAllObjects];
            [self.constructedIndex removeAllObjects];
            [self.droppedConstructs removeAllObjects];
            self.metadataDropped = 0;
            self.initLinksTruncated = NO;
            self.session++;
            self.buildState = SRMenuObserverBuildNone;
            self.deadline = self.clock() + timeout;
            self.budget = eventBudget;
            self.initCount = 0; self.buildCount = 0; self.selectCount = 0; self.droppedCount = 0;
            self.stopReason = @"";
            _sampling = YES;
            _state = SRMenuCallObserverSampling;
        }
    }
    return YES;
}

- (void)stopLocked:(NSString *)reason {
    // Caller holds the instance lock.
    if (!_sampling) return;
    _sampling = NO;
    _state = SRMenuCallObserverStopped;
    _stopReason = [reason copy];
    [self.buildItems removeAllObjects];
}

- (void)stopBecause:(NSString *)reason {
    @synchronized(self.lock) { [self stopLocked:reason]; }
}

- (void)stopSampling { [self stopBecause:@"manual"]; }
- (void)stopForLifecycle { [self stopBecause:@"lifecycle"]; }

- (NSUInteger)sessionToken { return _session; }

- (BOOL)stopForDeadlineToken:(NSUInteger)token {
    @synchronized(self.lock) {
        if (!_sampling || token != self.session) return NO;
        [self stopLocked:@"timeout"];
        return YES;
    }
}

- (BOOL)finishSessionWithToken:(NSUInteger)token reason:(NSString *)reason {
    @synchronized(SRMenuObserverLock()) {
        // The token identifies the session, not just the recording state: a
        // session that already stopped on its own is still closed here, while a
        // newer session (different token) is never touched.
        if (token == 0 || token != self.session) return NO;
        @synchronized(self.lock) {
            if (_sampling) [self stopLocked:reason];
        }
        [self uninstall];
        return YES;
    }
}

- (BOOL)finishSessionWithToken:(NSUInteger)token {
    return [self finishSessionWithToken:token reason:@"manual"];
}

- (BOOL)finishSessionForDeadlineToken:(NSUInteger)token {
    return [self finishSessionWithToken:token reason:@"timeout"];
}

- (void)uninstall {
    @synchronized(SRMenuObserverLock()) {
        if (!_installed) return;
        @synchronized(self.lock) { [self stopLocked:@"manual"]; }
        // Restore only while all three IMPs are still our trampolines. The
        // comparison runs under our own lock only: another plugin can replace an
        // IMP at any instant, so this is a best-effort refusal, not an atomic
        // claim. If a later hook replaced any of them, keep the lazy forwarding
        // intact instead of overwriting that hook with a stale IMP.
        BOOL ours = self.setterMethod && method_getImplementation(self.setterMethod) == (IMP)SRMenuObserverSetItems &&
            self.selectionMethod && method_getImplementation(self.selectionMethod) == (IMP)SRMenuObserverSelect &&
            self.initializerMethod && method_getImplementation(self.initializerMethod) == (IMP)SRMenuObserverInit;
        if (!ours) {
            _restoreRefused = YES;
            _state = SRMenuCallObserverStopped;
            return;
        }
        method_setImplementation(self.setterMethod, SRMenuObserverMenuSetIMP);
        method_setImplementation(self.selectionMethod, SRMenuObserverMenuSelectIMP);
        method_setImplementation(self.initializerMethod, SRMenuObserverItemInitIMP);
        if (SRMenuObserverOwner == self) SRMenuObserverOwner = nil;
        _installed = NO;
        _restoreRefused = NO;
        _state = SRMenuCallObserverIdle;
        self.menuClass = Nil;
        self.itemClass = Nil;
    }
}

/* Admission runs inside the recording lock and checks the deadline itself, so
 * an expired session stops on the next observed call, not on a read. */
- (BOOL)admitKind:(NSString *)kind limit:(NSUInteger)limit used:(NSUInteger)used now:(NSTimeInterval)now {
    if (!_sampling) return NO;
    if (!isfinite(now) || now >= self.deadline) { [self stopLocked:@"timeout"]; return NO; }
    if (used >= limit) { _droppedCount++; return NO; }
    BOOL selection = [kind isEqual:@"select"];
    NSUInteger reserved = selection ? 0 : SRMenuObserverSelectReserve;
    if (_events.count + reserved >= _budget) {
        if (selection) [self stopLocked:@"budget"]; else _droppedCount++;
        return NO;
    }
    return YES;
}

- (NSString *)coverageName {
    switch (self.buildState) {
        case SRMenuObserverBuildComplete: return @"complete";
        case SRMenuObserverBuildTruncated: return @"truncated";
        case SRMenuObserverBuildStale: return @"stale";
        default: return @"none";
    }
}

/* Presence is a definite `not_seen` only when the whole array was inspected.
 * A stale or missing build cannot answer for the current array, so it stays
 * `unknown` even if an older set still contains the object. */
- (NSString *)presenceForObject:(id)object {
    if (!object) return @"unknown";
    if (self.buildState != SRMenuObserverBuildComplete &&
        self.buildState != SRMenuObserverBuildTruncated) return @"unknown";
    if ([self.buildItems containsObject:object]) return @"seen";
    return self.buildState == SRMenuObserverBuildComplete ? @"not_seen" : @"unknown";
}

/* A build that is refused or cannot be read invalidates the previous set; the
 * old association must not survive into the next selection. */
- (void)markBuildStaleLocked {
    self.buildState = SRMenuObserverBuildStale;
    [self.buildItems removeAllObjects];
}

- (void)markBuildStaleForSession:(NSUInteger)session {
    @synchronized(self.lock) {
        if (session != self.session) return;
        [self markBuildStaleLocked];
    }
}

/* Build admission runs before the host container is touched: a call that is
 * already refused must not call -count or -objectAtIndex:. */
- (BOOL)precheckBuildLocked:(NSTimeInterval)now {
    if (!isfinite(now) || now >= self.deadline) {
        [self stopLocked:@"timeout"];
        [self markBuildStaleLocked];
        return NO;
    }
    if (self.buildCount >= SRMenuObserverBuildLimit) {
        _droppedCount++;
        [self markBuildStaleLocked];
        return NO;
    }
    if (self.events.count + SRMenuObserverSelectReserve >= self.budget) {
        _droppedCount++;
        [self markBuildStaleLocked];
        return NO;
    }
    return YES;
}

- (BOOL)canCommitBuildLocked {
    return self.buildCount < SRMenuObserverBuildLimit &&
        self.events.count + SRMenuObserverSelectReserve < self.budget;
}

- (NSInteger)appendMetadataLocked:(NSDictionary *)entry {
    if (self.metadata.count >= SRMenuObserverMetadataCap) { _metadataDropped++; return NSNotFound; }
    [self.metadata addObject:entry];
    return (NSInteger)self.metadata.count - 1;
}

- (void)recordBuildWithItems:(id)items receiver:(id)receiver {
    NSUInteger session;
    @synchronized(self.lock) {
        if (!_sampling) return;
        if (![self precheckBuildLocked:self.clock()]) return;
        session = self.session;
    }
    // Host container work runs outside the observer lock: a custom NSArray may
    // reenter the observer from its own -count / -objectAtIndex:.
    BOOL valid = [items isKindOfClass:NSArray.class];
    NSUInteger total = 0, inspected = 0;
    BOOL truncated = NO;
    NSMutableArray *snapshot = [NSMutableArray array];
    if (valid) {
        @try {
            total = [(NSArray *)items count];
            inspected = MIN(total, SRMenuObserverItemCap);
            truncated = total > SRMenuObserverItemCap;
            for (NSUInteger index = 0; index < inspected; index++) [snapshot addObject:items[index]];
        } @catch (NSException *exception) {
            // The container failed mid-read: the old association is unusable.
            [self markBuildStaleForSession:session];
            @throw;
        }
    }

    @synchronized(self.lock) {
        // Stop or a new session between the snapshot and the commit drops this
        // observation instead of writing it into the wrong session.
        if (session != self.session || !_sampling) return;
        // The container read happened outside the lock; re-read the clock so a
        // deadline crossed during that read cannot commit an event.
        NSTimeInterval commitNow = self.clock();
        if (!isfinite(commitNow) || commitNow >= self.deadline) {
            [self stopLocked:@"timeout"];
            [self markBuildStaleLocked];
            return;
        }
        if (![self canCommitBuildLocked]) { [self markBuildStaleLocked]; return; }
        [self appendMetadataLocked:@{@"kind": @"build",
            @"receiver": SRMenuMetadataToken(NSStringFromClass(object_getClass(receiver)))}];
        if (!valid) {
            [self markBuildStaleLocked];
            self.buildCount++;
            [self.events addObject:@{@"kind": @"build",
                @"main": @(NSThread.isMainThread),
                @"null": @(items == nil),
                @"items": @(0),
                @"inspected": @(0),
                @"truncated": @(NO),
                @"coverage": [self coverageName],
                @"known": @(0),
                @"foreign": @(0)}];
            return;
        }
        NSUInteger known = 0, foreign = 0;
        [self.buildItems removeAllObjects];
        for (id item in snapshot) {
            if (self.itemClass && object_getClass(item) == self.itemClass) known++;
            else foreign++;
            // Every inspected object is remembered by pointer identity, not just
            // the candidate class: presence and class recognition are separate.
            [self.buildItems addObject:item];
        }
        self.buildState = truncated ? SRMenuObserverBuildTruncated : SRMenuObserverBuildComplete;
        self.buildCount++;
        [self.events addObject:@{@"kind": @"build",
            @"main": @(NSThread.isMainThread),
            @"null": @(items == nil),
            @"items": @(total),
            @"inspected": @(inspected),
            @"truncated": @(truncated),
            @"coverage": [self coverageName],
            @"known": @(known),
            @"foreign": @(foreign)}];
    }
}

- (void)recordSelectionItem:(id)item itemView:(id)view receiver:(id)receiver {
    @synchronized(self.lock) {
        if (!_sampling) return;
        NSTimeInterval now = self.clock();
        if (![self admitKind:@"select" limit:SRMenuObserverSelectLimit used:self.selectCount now:now]) return;
        BOOL itemKnown = item && self.itemClass && object_getClass(item) == self.itemClass;
        BOOL viewKnown = view && self.itemClass && object_getClass(view) == self.itemClass;
        /* In-session construction link: identity only, never a business message
         * identity. `init` is the metadata index of this exact constructed
         * object, or an explicit reason why it cannot be named. */
        id initValue = @"<none>";
        NSString *link = @"none";
        if (self.initCount > 0) {
            NSNumber *index = item ? [self.constructedIndex objectForKey:item] : nil;
            if (index) { initValue = index; link = @"matched"; }
            else if (item && [self.droppedConstructs containsObject:item]) { initValue = @"<overflow>"; link = @"unmatched"; }
            else { initValue = @"<unmatched>"; link = @"unmatched"; }
        }
        [self appendMetadataLocked:@{@"kind": @"select",
            @"receiver": SRMenuMetadataToken(NSStringFromClass(object_getClass(receiver))),
            @"view": SRMenuMetadataToken(NSStringFromClass(object_getClass(view))),
            @"link": link,
            @"init": initValue}];
        self.selectCount++;
        [self.events addObject:@{@"kind": @"select",
            @"main": @(NSThread.isMainThread),
            @"itemNull": @(item == nil),
            @"viewNull": @(view == nil),
            @"itemKnown": @(itemKnown),
            @"viewKnown": @(viewKnown),
            @"itemPresence": [self presenceForObject:item],
            @"viewPresence": [self presenceForObject:view],
            @"coverage": [self coverageName],
            @"sameObject": @(item != nil && item == view)}];
    }
}

- (void)recordInitWithTitle:(id)title icon:(id)icon target:(id)target action:(SEL)action result:(id)result {
    @synchronized(self.lock) {
        NSTimeInterval now = self.clock();
        if (![self admitKind:@"init" limit:SRMenuObserverInitLimit used:self.initCount now:now]) return;
        NSUInteger argumentCount = 0;
        Method declaredMethod = SRMenuDeclaredMethodInfo(target, action, &argumentCount);
        BOOL declared = declaredMethod != NULL;
        self.initCount++;
        NSInteger metaIndex = [self appendMetadataLocked:@{@"kind": @"init",
            @"target": SRMenuMetadataToken(target ? NSStringFromClass(object_getClass(target)) : nil),
            @"action": SRMenuMetadataToken(action ? NSStringFromSelector(action) : nil),
            @"icon": SRMenuMetadataToken(icon ? NSStringFromClass(object_getClass(icon)) : nil),
            @"result": SRMenuMetadataToken(result ? NSStringFromClass(object_getClass(result)) : nil),
            @"signature": (target && action) ? SRMenuMetadataSignature(declaredMethod) : @"<missing>",
            @"declared": @(declared)}];
        if (result) {
            if (metaIndex == NSNotFound) {
                if (self.droppedConstructs.count < SRMenuObserverInitLinkCap) [self.droppedConstructs addObject:result];
                else self.initLinksTruncated = YES;
            } else if (self.constructedIndex.count < SRMenuObserverInitLinkCap) {
                [self.constructedIndex setObject:@(metaIndex) forKey:result];
            } else {
                // The link table is full: keep the fact that this exact object
                // could not be indexed, so a later click reports overflow rather
                // than a fabricated match.
                if (self.droppedConstructs.count < SRMenuObserverInitLinkCap) [self.droppedConstructs addObject:result];
                self.initLinksTruncated = YES;
            }
        }
        [self.events addObject:@{@"kind": @"init",
            @"main": @(NSThread.isMainThread),
            @"titleNull": @(title == nil),
            @"iconNull": @(icon == nil),
            @"targetNull": @(target == nil),
            @"actionNull": @(action == NULL),
            @"targetIsMenuClass": @(target && self.menuClass && object_getClass(target) == self.menuClass),
            @"actionDeclared": @(declared),
            @"actionArgs": @(argumentCount),
            @"resultNull": @(result == nil)}];
    }
}

- (NSString *)stateName {
    switch (_state) {
        case SRMenuCallObserverIdle: return @"idle";
        case SRMenuCallObserverInstalled: return @"installed";
        case SRMenuCallObserverSampling: return @"sampling";
        case SRMenuCallObserverStopped: return @"stopped";
    }
    return @"idle";
}

- (NSDictionary *)diagnostics {
    BOOL sampling = self.sampling;
    @synchronized(self.lock) {
        return @{@"state": [self stateName],
                 @"installed": @(_installed),
                 @"sampling": @(sampling),
                 @"restoreRefused": @(_restoreRefused),
                 @"stopReason": _stopReason ?: @"",
                 @"events": [self eventsCopyLocked],
                 @"counts": @{@"init": @(self.initCount), @"build": @(self.buildCount),
                              @"select": @(self.selectCount), @"dropped": @(self.droppedCount),
                              @"buildRefs": @(self.buildItems.count)},
                 @"budget": @{@"events": @(self.budget), @"used": @(self.events.count)},
                 @"menuCallMetadata": @{@"entries": [self.metadata copy] ?: @[],
                                        @"dropped": @(self.metadataDropped),
                                        @"linksTruncated": @(self.initLinksTruncated)}};
    }
}

- (NSArray<NSDictionary *> *)eventsCopyLocked {
    return [self.events copy] ?: @[];
}

@end
