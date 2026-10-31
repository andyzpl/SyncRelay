#import "SRMessageMenuHook.h"
#import "Core/SRLibraryIntake.h"
#import "SRRuntime.h"
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
    NSString *_session;
    NSString *_messageType;
    NSString *_createdAt;
    NSString *_epoch;
    NSString *_operationKey;
}
- (instancetype)initWithAccount:(NSString *)account body:(NSString *)body generation:(NSString *)generation
                     ownerToken:(NSString *)ownerToken messageIdentity:(NSString *)messageIdentity
                        session:(NSString *)session messageType:(NSString *)messageType
                      createdAt:(NSString *)createdAt epoch:(NSString *)epoch operationKey:(NSString *)operationKey {
    self = [super init];
    if (self) {
        _account = [account copy];
        _body = [body copy];
        _generation = [generation copy];
        _ownerToken = [ownerToken copy];
        _messageIdentity = [messageIdentity copy];
        _session = [session copy];
        _messageType = [messageType copy];
        _createdAt = [createdAt copy];
        _epoch = [epoch copy];
        _operationKey = [operationKey copy];
    }
    return self;
}
- (NSString *)account { return _account; }
- (NSString *)body { return _body; }
- (NSString *)generation { return _generation; }
- (NSString *)ownerToken { return _ownerToken; }
- (NSString *)messageIdentity { return _messageIdentity; }
- (NSString *)session { return _session; }
- (NSString *)messageType { return _messageType; }
- (NSString *)createdAt { return _createdAt; }
- (NSString *)epoch { return _epoch; }
- (NSString *)operationKey { return _operationKey; }
@end

@implementation SRMenuCurrentIdentity {
    NSString *_account;
    NSString *_ownerToken;
    NSString *_generation;
    NSString *_messageIdentity;
    NSString *_session;
    NSString *_messageType;
    NSString *_createdAt;
    NSString *_epoch;
    NSString *_body;
}
- (instancetype)initWithAccount:(NSString *)account ownerToken:(NSString *)ownerToken
                     generation:(NSString *)generation messageIdentity:(NSString *)messageIdentity
                        session:(NSString *)session messageType:(NSString *)messageType
                      createdAt:(NSString *)createdAt epoch:(NSString *)epoch body:(NSString *)body {
    self = [super init];
    if (self) {
        _account = [account copy];
        _ownerToken = [ownerToken copy];
        _generation = [generation copy];
        _messageIdentity = [messageIdentity copy];
        _session = [session copy];
        _messageType = [messageType copy];
        _createdAt = [createdAt copy];
        _epoch = [epoch copy];
        _body = [body copy];
    }
    return self;
}
- (NSString *)account { return _account; }
- (NSString *)ownerToken { return _ownerToken; }
- (NSString *)generation { return _generation; }
- (NSString *)messageIdentity { return _messageIdentity; }
- (NSString *)session { return _session; }
- (NSString *)messageType { return _messageType; }
- (NSString *)createdAt { return _createdAt; }
- (NSString *)epoch { return _epoch; }
- (NSString *)body { return _body; }
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
/* item -> menu (weak/weak): used to re-resolve the current source at click. */
@property(nonatomic, strong) NSMapTable *menus;
@property(nonatomic) Class hostMenuClass;
@property(nonatomic) Class hostCoverClass;
@property(nonatomic) Class hostCellClass;
/* menu -> generation, set when the menu was built; read again at click time so
 * the generation check does not rely on the hook's active item state. */
@property(nonatomic, strong) NSMapTable *menuGenerations;
/* Account-context manager instance and the receiver's generation token. */
@property(nonatomic, copy) id (^readbackProvider)(void);
@property(nonatomic, copy) unsigned long long (^epochProvider)(void);
@end

/* -------------------------------------------------------------------------
 * Host menu source resolution.
 *
 * Every hop is looked up in the real method list of the receiver's class and
 * validated against the expected ABI before it is sent. Nothing here reads an
 * ivar, uses a hard-coded offset, calls a pj* helper or touches Mikoto state.
 * ---------------------------------------------------------------------- */
static Method SRMenuHookMethod(Class cls, SEL selector) {
    if (!cls || !selector) return NULL;
    // A KVO subclass inherits the real declaration: walk the class chain, but
    // never leave the expected host hierarchy.
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        if (!methods) continue;
        for (unsigned int index = 0; index < count; index++) {
            if (method_getName(methods[index]) != selector) continue;
            Method found = methods[index];
            free(methods);
            return found;
        }
        free(methods);
    }
    return NULL;
}

static BOOL SRMenuHookArgumentsAreSelfAndSEL(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char *first = method_copyArgumentType(method, 0);
    char *second = method_copyArgumentType(method, 1);
    BOOL ok = first && second && first[0] == '@' && second[0] == ':';
    free(first); free(second);
    return ok;
}

static BOOL SRMenuHookObjectGetter(Method method) {
    if (!SRMenuHookArgumentsAreSelfAndSEL(method)) return NO;
    char *type = method_copyReturnType(method);
    BOOL ok = type && type[0] == '@' && type[1] != '?';
    free(type);
    return ok;
}

static BOOL SRMenuHookScalarGetter(Method method) {
    if (!SRMenuHookArgumentsAreSelfAndSEL(method)) return NO;
    char *type = method_copyReturnType(method);
    char kind = type ? type[0] : 0;
    free(type);
    return kind == 'Q' || kind == 'L' || kind == 'I' || kind == 'q' || kind == 'i';
}

static BOOL SRMenuHookInitializer(Method method) {
    if (!method || method_getNumberOfArguments(method) != 6) return NO;
    char *ret = method_copyReturnType(method);
    BOOL ok = ret && ret[0] == '@' && ret[1] != '?';
    free(ret);
    if (!ok) return NO;
    char *selfType = method_copyArgumentType(method, 0);
    char *cmdType = method_copyArgumentType(method, 1);
    ok = selfType && selfType[0] == '@' && cmdType && cmdType[0] == ':';
    free(selfType); free(cmdType);
    if (!ok) return NO;
    for (unsigned int index = 2; index <= 4; index++) {
        char *type = method_copyArgumentType(method, index);
        BOOL object = type && type[0] == '@';
        free(type);
        if (!object) return NO;
    }
    char *action = method_copyArgumentType(method, 5);
    BOOL sel = action && action[0] == ':';
    free(action);
    return sel;
}

static id SRMenuHookReadObject(id object, SEL selector) {
    if (!object) return nil;
    Method method = SRMenuHookMethod(object_getClass(object), selector);
    if (!SRMenuHookObjectGetter(method)) return nil;
    @try {
        return ((id (*)(id, SEL))method_getImplementation(method))(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/* The receiver is consumed by the init-family call and the result is owned. */
typedef id (*SRMenuHookInitIMP)(id __attribute__((ns_consumed)), SEL, id, id, id, SEL)
    __attribute__((ns_returns_retained));
typedef unsigned long long (*SRMenuHookULLGetter)(id, SEL);
typedef unsigned long (*SRMenuHookULGetter)(id, SEL);
typedef unsigned int (*SRMenuHookUIGetter)(id, SEL);
typedef long long (*SRMenuHookLLGetter)(id, SEL);
typedef int (*SRMenuHookIGetter)(id, SEL);

/* The call signature must match the declared return width; calling a 32-bit
 * getter through a 64-bit function pointer is undefined. */
static BOOL SRMenuHookReadUnsigned(id object, SEL selector, unsigned long long *value) {
    if (!object || !value) return NO;
    Method method = SRMenuHookMethod(object_getClass(object), selector);
    if (!SRMenuHookScalarGetter(method)) return NO;
    char *type = method_copyReturnType(method);
    char kind = type ? type[0] : 0;
    free(type);
    IMP imp = method_getImplementation(method);
    @try {
        switch (kind) {
            case 'Q': *value = ((SRMenuHookULLGetter)imp)(object, selector); return YES;
            case 'L': *value = ((SRMenuHookULGetter)imp)(object, selector); return YES;
            case 'I': *value = ((SRMenuHookUIGetter)imp)(object, selector); return YES;
            case 'q': {
                long long signedValue = ((SRMenuHookLLGetter)imp)(object, selector);
                if (signedValue < 0) return NO;
                *value = (unsigned long long)signedValue; return YES;
            }
            case 'i': {
                int signedValue = ((SRMenuHookIGetter)imp)(object, selector);
                if (signedValue < 0) return NO;
                *value = (unsigned long long)signedValue; return YES;
            }
            default: return NO;
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

/* Read-only lookup-service gate: a real object (never a class), the declared
 * lookup selector present through reflection/forwarding, object return, object
 * session and an unsigned-integer local id. Proxies pass through their own
 * signature; nothing is unwrapped or invoked here. */
/* Read-only lookup-service gate. It checks the declared ABI when the class
 * really declares the method, the reflected/forwarded signature otherwise, and
 * refuses a declaration that conflicts with the reflected one. Any exception
 * from a proxy is turned into a refusal; nothing is invoked. */
static BOOL SRMenuHookTypeIsInteger(const char *type) {
    return type && (type[0] == 'I' || type[0] == 'Q' || type[0] == 'L');
}

/* Full lookup shape, including the implicit self and _cmd types. */
static BOOL SRMenuHookLookupShape(const char *ret, const char *selfType, const char *cmdType,
                                  const char *sessionType, const char *idType) {
    return ret && ret[0] == '@' &&
        selfType && selfType[0] == '@' &&
        cmdType && cmdType[0] == ':' &&
        sessionType && sessionType[0] == '@' &&
        SRMenuHookTypeIsInteger(idType);
}

static BOOL SRMenuHookDeclaredLookupMatches(Method method) {
    if (!method || method_getNumberOfArguments(method) != 4) return NO;
    char *ret = method_copyReturnType(method);
    char *a0 = method_copyArgumentType(method, 0);
    char *a1 = method_copyArgumentType(method, 1);
    char *a2 = method_copyArgumentType(method, 2);
    char *a3 = method_copyArgumentType(method, 3);
    BOOL ok = SRMenuHookLookupShape(ret, a0, a1, a2, a3);
    free(ret); free(a0); free(a1); free(a2); free(a3);
    return ok;
}

static BOOL SRMenuHookSignatureMatches(NSMethodSignature *signature) {
    if (!signature || signature.numberOfArguments != 4) return NO;
    return SRMenuHookLookupShape(signature.methodReturnType,
                                 [signature getArgumentTypeAtIndex:0],
                                 [signature getArgumentTypeAtIndex:1],
                                 [signature getArgumentTypeAtIndex:2],
                                 [signature getArgumentTypeAtIndex:3]);
}

/* When the service does not declare the lookup itself, it may only be accepted
 * as a forwarding proxy whose metadata methods are themselves declared with the
 * expected ABI. */
static BOOL SRMenuHookProxyMetadataMatches(id service) {
    Method signatureMethod = SRMenuHookMethod(object_getClass(service), @selector(methodSignatureForSelector:));
    Method forwardMethod = SRMenuHookMethod(object_getClass(service), @selector(forwardInvocation:));
    if (!signatureMethod || method_getNumberOfArguments(signatureMethod) != 3) return NO;
    char *sigRet = method_copyReturnType(signatureMethod);
    char *sigArg = method_copyArgumentType(signatureMethod, 2);
    BOOL sigOK = sigRet && sigRet[0] == '@' && sigArg && sigArg[0] == ':';
    free(sigRet); free(sigArg);
    if (!sigOK || !forwardMethod || method_getNumberOfArguments(forwardMethod) != 3) return NO;
    char *fwdRet = method_copyReturnType(forwardMethod);
    char *fwdArg = method_copyArgumentType(forwardMethod, 2);
    BOOL fwdOK = fwdRet && fwdRet[0] == 'v' && fwdArg && fwdArg[0] == '@';
    free(fwdRet); free(fwdArg);
    return fwdOK;
}

static BOOL SRMenuHookValidLookupService(id service) {
    if (!service || object_isClass(service)) return NO;
    SEL selector = NSSelectorFromString(@"GetMsg:LocalID:");
    @try {
        Method declared = SRMenuHookMethod(object_getClass(service), selector);
        if (declared) {
            if (!SRMenuHookDeclaredLookupMatches(declared)) return NO;
        } else if (!SRMenuHookProxyMetadataMatches(service)) {
            return NO;
        }
        if (![service respondsToSelector:selector]) return NO;
        NSMethodSignature *signature = [service methodSignatureForSelector:selector];
        if (!SRMenuHookSignatureMatches(signature)) return NO;
        if (declared) {
            char *ret = method_copyReturnType(declared);
            char *a0 = method_copyArgumentType(declared, 0);
            char *a1 = method_copyArgumentType(declared, 1);
            char *a2 = method_copyArgumentType(declared, 2);
            char *a3 = method_copyArgumentType(declared, 3);
            BOOL same = ret && a0 && a1 && a2 && a3 &&
                strcmp(ret, signature.methodReturnType) == 0 &&
                strcmp(a0, [signature getArgumentTypeAtIndex:0]) == 0 &&
                strcmp(a1, [signature getArgumentTypeAtIndex:1]) == 0 &&
                strcmp(a2, [signature getArgumentTypeAtIndex:2]) == 0 &&
                strcmp(a3, [signature getArgumentTypeAtIndex:3]) == 0;
            free(ret); free(a0); free(a1); free(a2); free(a3);
            if (!same) return NO;
        }
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL SRMenuHookClassIsKindOf(Class candidate, Class base) {
    if (!candidate || !base) return NO;
    for (Class current = candidate; current; current = class_getSuperclass(current)) {
        if (current == base) return YES;
    }
    return NO;
}

@implementation SRMenuHostSource {
    NSString *_messageIdentity;
    NSString *_body;
    NSString *_session;
    NSString *_messageType;
    NSString *_createdAt;
    BOOL _isText;
}
+ (instancetype)sourceForMenu:(id)menu menuClass:(Class)menuClass
                   coverClass:(Class)coverClass cellClass:(Class)cellClass
                      account:(NSString *)account {
    if (!menu || !menuClass || !coverClass || !cellClass) return nil;
    // A KVO subclass (NSKVONotifying_<class>) is still the same host class.
    if (!SRMenuHookClassIsKindOf(object_getClass(menu), menuClass)) return nil;
    id responder = SRMenuHookReadObject(menu, NSSelectorFromString(@"responder"));
    if (!responder || !SRMenuHookClassIsKindOf(object_getClass(responder), coverClass)) return nil;
    id delegate = SRMenuHookReadObject(responder, NSSelectorFromString(@"delegate"));
    if (!delegate || !SRMenuHookClassIsKindOf(object_getClass(delegate), cellClass)) return nil;
    id wrap = SRMenuHookReadObject(delegate, NSSelectorFromString(@"getCurrentMessageWrap"));
    if (!wrap) return nil;
    unsigned long long localID = 0;
    if (!SRMenuHookReadUnsigned(wrap, NSSelectorFromString(@"m_uiMesLocalID"), &localID) || !localID) return nil;
    unsigned long long messageType = 0;
    if (!SRMenuHookReadUnsigned(wrap, NSSelectorFromString(@"m_uiMessageType"), &messageType)) return nil;
    unsigned long long createdAt = 0;
    if (!SRMenuHookReadUnsigned(wrap, NSSelectorFromString(@"m_uiCreateTime"), &createdAt) || !createdAt) return nil;
    // Session follows the receiver's direction rule, not a guessed field name:
    // outgoing (from == account) -> to; incoming (to == account) -> from.
    id fromObject = SRMenuHookReadObject(wrap, NSSelectorFromString(@"m_nsFromUsr"));
    id toObject = SRMenuHookReadObject(wrap, NSSelectorFromString(@"m_nsToUsr"));
    if (![fromObject isKindOfClass:NSString.class] || ![toObject isKindOfClass:NSString.class]) return nil;
    NSString *from = fromObject, *to = toObject;
    NSString *sessionObject = nil;
    if (account.length && [from isEqual:account]) sessionObject = to;
    else if (account.length && [to isEqual:account]) sessionObject = from;
    else return nil;
    if (!sessionObject.length) return nil;
    id bodyObject = SRMenuHookReadObject(wrap, NSSelectorFromString(@"m_nsContent"));
    if (![bodyObject isKindOfClass:NSString.class] || [bodyObject length] == 0) return nil;
    SRMenuHostSource *source = [SRMenuHostSource new];
    source->_messageIdentity = [[NSString alloc] initWithFormat:@"local:%llu", localID];
    source.localID = localID;
    source->_body = [bodyObject copy];
    source->_session = [sessionObject copy];
    source->_messageType = [[NSString alloc] initWithFormat:@"%llu", messageType];
    source->_createdAt = [[NSString alloc] initWithFormat:@"%llu", createdAt];
    source->_isText = (messageType == 1);
    return source;
}
- (NSString *)messageIdentity { return _messageIdentity; }
- (NSString *)body { return _body; }
- (NSString *)session { return _session; }
- (NSString *)messageType { return _messageType; }
- (NSString *)createdAt { return _createdAt; }
- (BOOL)isText { return _isText; }
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
        _menuGenerations = [[NSMapTable alloc] initWithKeyOptions:(NSPointerFunctionsWeakMemory | NSPointerFunctionsOpaquePersonality)
                                                     valueOptions:NSPointerFunctionsStrongMemory capacity:0];
        _menus = [[NSMapTable alloc] initWithKeyOptions:(NSPointerFunctionsWeakMemory | NSPointerFunctionsOpaquePersonality)
                                           valueOptions:(NSPointerFunctionsWeakMemory | NSPointerFunctionsOpaquePersonality)
                                               capacity:0];
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
            session:source.session messageType:source.messageType createdAt:source.createdAt
            epoch:source.epoch operationKey:source.operationKey];
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
        !current.messageIdentity.length || !current.session.length || !current.messageType.length ||
        !current.createdAt.length || !current.epoch.length || !current.body.length) return SRMenuIntentContextStale;
    if (![context.account isEqual:current.account] ||
        ![context.ownerToken isEqual:current.ownerToken] ||
        ![context.generation isEqual:current.generation] ||
        ![context.messageIdentity isEqual:current.messageIdentity] ||
        ![context.session isEqual:current.session] ||
        ![context.messageType isEqual:current.messageType] ||
        ![context.createdAt isEqual:current.createdAt] ||
        ![context.epoch isEqual:current.epoch] ||
        ![context.body isEqual:current.body]) {
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
    // Last external callbacks (account/liveness) may have changed the receiver:
    // re-read the authoritative token right before writing.
    if (!self.epochProvider) return SRMenuIntentContextStale;
    unsigned long long liveEpoch = self.epochProvider();
    if (liveEpoch == ULLONG_MAX || ![[NSString stringWithFormat:@"%llu", liveEpoch] isEqual:current.epoch]) {
        return SRMenuIntentContextStale;
    }
    // The callbacks above may have rebuilt the menu or flipped the switch.
    if (!self.enabled || !self.enabled()) return SRMenuIntentDisabled;
    @synchronized(self.lock) {
        if (self.activeItem != item || ![context.generation isEqual:self.activeGeneration]) {
            return SRMenuIntentContextStale;
        }
    }
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

- (void)configureReadbackProvider:(id (^)(void))provider {
    @synchronized(self.lock) { self.readbackProvider = [provider copy]; }
}

- (void)configureEpochProvider:(unsigned long long (^)(void))provider {
    @synchronized(self.lock) { self.epochProvider = [provider copy]; }
}

- (void)configureHostClasses:(Class)menuClass coverClass:(Class)coverClass cellClass:(Class)cellClass {
    @synchronized(self.lock) {
        self.hostMenuClass = menuClass;
        self.hostCoverClass = coverClass;
        self.hostCellClass = cellClass;
    }
}

- (NSString *)ownerTokenForMenu:(id)menu {
    return [[NSString alloc] initWithFormat:@"menu:%p", menu];
}

- (SRMenuMessageContext *)contextForMenu:(id)menu generation:(NSString *)generation {
    if (!menu || !generation.length) return nil;
    if (!self.currentAccount) return nil;
    NSString *account = self.currentAccount();
    if (!account.length) return nil;
    SRMenuHostSource *source = [SRMenuHostSource sourceForMenu:menu menuClass:self.hostMenuClass
                                                   coverClass:self.hostCoverClass cellClass:self.hostCellClass
                                                      account:account];
    if (!source || !source.isText || !source.body.length || !source.messageIdentity.length) return nil;
    NSString *owner = [self ownerTokenForMenu:menu];
    NSString *operationKey = [[NSString alloc] initWithFormat:@"menu:%@:%@:%@", owner, generation, source.messageIdentity];
    @synchronized(self.lock) { [self.menuGenerations setObject:[generation copy] forKey:menu]; }
    if (!self.epochProvider) return nil;
    unsigned long long epochValue = self.epochProvider();
    if (epochValue == ULLONG_MAX) return nil;
    NSString *epoch = [[NSString alloc] initWithFormat:@"%llu", epochValue];
    return [[SRMenuMessageContext alloc] initWithAccount:account body:source.body generation:generation
                                              ownerToken:owner messageIdentity:source.messageIdentity
                                                 session:source.session messageType:source.messageType
                                               createdAt:source.createdAt epoch:epoch operationKey:operationKey];
}

- (NSArray *)appendHostItemToItems:(NSArray *)items menu:(id)menu source:(SRMenuMessageContext *)source
                         itemClass:(Class)itemClass generation:(NSString *)generation {
    NSArray *original = [items isKindOfClass:NSArray.class] ? items : @[];
    if (!self.enabled || !self.enabled()) return original;
    if (!menu || !source || !itemClass || !generation.length) return original;
    Method initializer = SRMenuHookMethod(itemClass, NSSelectorFromString(@"initWithTitle:icon:target:action:"));
    if (!SRMenuHookInitializer(initializer)) return original;
    id item = nil;
    @try {
        item = ((SRMenuHookInitIMP)method_getImplementation(initializer))(
            [itemClass alloc], NSSelectorFromString(@"initWithTitle:icon:target:action:"),
            @"存入同步库", nil, self, NSSelectorFromString(@"srMenuAction:"));
    } @catch (__unused NSException *exception) {
        return original;
    }
    // A replacement object is only accepted when it is still a menu item of the
    // expected class (or a subclass); anything else would break the host menu.
    if (!item || !SRMenuHookClassIsKindOf(object_getClass(item), itemClass)) return original;
    @synchronized(self.lock) {
        SRMenuMessageContext *frozen = [[SRMenuMessageContext alloc]
            initWithAccount:source.account body:source.body generation:generation
                 ownerToken:source.ownerToken messageIdentity:source.messageIdentity
                    session:source.session messageType:source.messageType
                  createdAt:source.createdAt epoch:source.epoch operationKey:source.operationKey];
        [self.contexts setObject:frozen forKey:item];
        [self.menus setObject:menu forKey:item];
        self.activeGeneration = [generation copy];
        self.activeItem = item;
        NSMutableArray *published = [NSMutableArray arrayWithCapacity:original.count + 1];
        for (id existing in original) {
            if (![self.contexts objectForKey:existing]) [published addObject:existing];
        }
        [published addObject:item];
        return [published copy];
    }
}

- (SRMenuCurrentIdentity *)currentIdentityForMenu:(id)menu {
    if (!menu) return nil;
    NSString *account = self.currentAccount ? self.currentAccount() : nil;
    if (!account.length) return nil;
    SRMenuHostSource *source = [SRMenuHostSource sourceForMenu:menu menuClass:self.hostMenuClass
                                                   coverClass:self.hostCoverClass cellClass:self.hostCellClass
                                                      account:account];
    if (!source || !source.messageIdentity.length) return nil;
    // Independent second source: read the same message back through the declared
    // instance API of the account-context message manager.
    id manager = self.readbackProvider ? self.readbackProvider() : nil;
    if (!SRMenuHookValidLookupService(manager)) return nil;
    id stored = nil;
    @try {
        stored = SRReadObjectWithObjectAndUnsignedInteger(manager, @"GetMsg:LocalID:",
                                                         source.session, @(source.localID), NULL);
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (!stored) return nil;
    unsigned long long storedID = 0;
    if (!SRMenuHookReadUnsigned(stored, NSSelectorFromString(@"m_uiMesLocalID"), &storedID) ||
        storedID != source.localID) return nil;
    unsigned long long storedType = 0;
    if (!SRMenuHookReadUnsigned(stored, NSSelectorFromString(@"m_uiMessageType"), &storedType) ||
        ![[NSString stringWithFormat:@"%llu", storedType] isEqual:source.messageType]) return nil;
    unsigned long long storedCreated = 0;
    if (!SRMenuHookReadUnsigned(stored, NSSelectorFromString(@"m_uiCreateTime"), &storedCreated) ||
        ![[NSString stringWithFormat:@"%llu", storedCreated] isEqual:source.createdAt]) return nil;
    id storedBody = SRMenuHookReadObject(stored, NSSelectorFromString(@"m_nsContent"));
    if (![storedBody isKindOfClass:NSString.class] || ![storedBody isEqual:source.body]) return nil;
    id storedFrom = SRMenuHookReadObject(stored, NSSelectorFromString(@"m_nsFromUsr"));
    id storedTo = SRMenuHookReadObject(stored, NSSelectorFromString(@"m_nsToUsr"));
    NSString *storedSession = nil;
    if ([storedFrom isKindOfClass:NSString.class] && [storedFrom isEqual:account]) storedSession = storedTo;
    else if ([storedTo isKindOfClass:NSString.class] && [storedTo isEqual:account]) storedSession = storedFrom;
    if (![storedSession isKindOfClass:NSString.class] || ![storedSession isEqual:source.session]) return nil;
    NSString *generation = nil;
    @synchronized(self.lock) { generation = [self.menuGenerations objectForKey:menu]; }
    if (!generation.length) return nil;
    // The manager read may have taken time: confirm the live selection still
    // resolves to the same message before using the readback result.
    SRMenuHostSource *recheck = [SRMenuHostSource sourceForMenu:menu menuClass:self.hostMenuClass
                                                     coverClass:self.hostCoverClass cellClass:self.hostCellClass
                                                        account:account];
    if (!recheck ||
        ![recheck.messageIdentity isEqual:source.messageIdentity] ||
        ![recheck.session isEqual:source.session] ||
        ![recheck.messageType isEqual:source.messageType] ||
        ![recheck.createdAt isEqual:source.createdAt] ||
        ![recheck.body isEqual:source.body]) return nil;
    // The manager read may have taken time: capture the live epoch now; the
    // commit compares it with the frozen value.
    if (!self.epochProvider) return nil;
    unsigned long long epochValue = self.epochProvider();
    if (epochValue == ULLONG_MAX) return nil;
    NSString *epoch = [[NSString alloc] initWithFormat:@"%llu", epochValue];
    return [[SRMenuCurrentIdentity alloc] initWithAccount:account ownerToken:[self ownerTokenForMenu:menu]
                                              generation:generation messageIdentity:source.messageIdentity
                                                 session:source.session messageType:source.messageType
                                               createdAt:source.createdAt epoch:epoch body:source.body];
}

/* The host invokes item.target/item.action with the menu item view as the
 * sender, so the item is read back from the view through its declared getter. */
- (void)srMenuAction:(id)sender {
    // The menu action must never leak an exception into the host.
    @try {
        id item = SRMenuHookReadObject(sender, NSSelectorFromString(@"menuItem"));
        if (!item || ![self ownsItem:item]) return;
        id menu = nil;
        @synchronized(self.lock) { menu = [self.menus objectForKey:item]; }
        [self handleSelection:item current:[self currentIdentityForMenu:menu]];
    } @catch (__unused NSException *exception) {
    }
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
- (BOOL)observationStillValidForSession:(NSUInteger)session;
- (NSUInteger)acquireSelectGuardLocked;
- (void)releaseSelectGuardLocked:(NSUInteger)token;
- (void)releaseSelectReservationLocked:(NSUInteger)session;
- (NSDictionary *)handlerMetadataForItem:(id)item receiver:(id)receiver gate:(BOOL (^)(void))gate;
+ (NSDictionary *)inspectHandlerGettersForItem:(id)item receiver:(id)receiver;
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

/* Declared-method lookup is defined below; the getter helpers above the
 * trampolines only need its prototype. */
static Method SRMenuDeclaredMethodInfo(id target, SEL action, NSUInteger *argumentCount);
static BOOL SRMenuObserverArgumentIsObject(Method method, unsigned int index);
static BOOL SRMenuObserverArgumentIsSEL(Method method, unsigned int index);

/* Status of one declared zero-argument getter read on a host object. */
typedef NS_ENUM(NSInteger, SRMenuGetterStatus) {
    SRMenuGetterOK = 0,
    SRMenuGetterMissing = 1,
    SRMenuGetterFailed = 2,
};

/* A getter must really be (self, _cmd) -> value, checked on the declared method
 * found by the direct walk; nothing is sent before this passes. */
static BOOL SRMenuObserverZeroArgShape(Method method) {
    return method && method_getNumberOfArguments(method) == 2 &&
        SRMenuObserverArgumentIsObject(method, 0) && SRMenuObserverArgumentIsSEL(method, 1);
}

static BOOL SRMenuObserverValidateZeroArgObjectGetter(Method method) {
    if (!SRMenuObserverZeroArgShape(method)) return NO;
    char *type = method_copyReturnType(method);
    BOOL matches = type && type[0] == '@' && type[1] != '?';
    free(type);
    return matches;
}

static BOOL SRMenuObserverValidateZeroArgBlockGetter(Method method) {
    if (!SRMenuObserverZeroArgShape(method)) return NO;
    char *type = method_copyReturnType(method);
    BOOL matches = type && type[0] == '@' && type[1] == '?';
    free(type);
    return matches;
}

static BOOL SRMenuObserverValidateZeroArgSELGetter(Method method) {
    if (!SRMenuObserverZeroArgShape(method)) return NO;
    char *type = method_copyReturnType(method);
    BOOL matches = type && type[0] == ':';
    free(type);
    return matches;
}

/* Reads a declared, zero-argument getter only after its ABI matched. Nothing is
 * sent unless the method is really declared in the class or a superclass. */
static id SRMenuObserverReadObjectGetter(id target, SEL selector, SRMenuGetterStatus *status) {
    *status = SRMenuGetterMissing;
    Method method = SRMenuDeclaredMethodInfo(target, selector, NULL);
    if (!method || !SRMenuObserverValidateZeroArgObjectGetter(method)) return nil;
    *status = SRMenuGetterOK;
    @try {
        return ((id (*)(id, SEL))method_getImplementation(method))(target, selector);
    } @catch (__unused NSException *exception) {
        *status = SRMenuGetterFailed;
        return nil;
    }
}

static SEL SRMenuObserverReadSELGetter(id target, SEL selector, SRMenuGetterStatus *status) {
    *status = SRMenuGetterMissing;
    Method method = SRMenuDeclaredMethodInfo(target, selector, NULL);
    if (!method || !SRMenuObserverValidateZeroArgSELGetter(method)) return NULL;
    *status = SRMenuGetterOK;
    @try {
        return ((SEL (*)(id, SEL))method_getImplementation(method))(target, selector);
    } @catch (__unused NSException *exception) {
        *status = SRMenuGetterFailed;
        return NULL;
    }
}

/* Presence only: the getter is read after ABI validation, the block is never
 * called and never exported. */
static BOOL SRMenuObserverReadBlockGetter(id target, SEL selector, SRMenuGetterStatus *status) {
    *status = SRMenuGetterMissing;
    Method method = SRMenuDeclaredMethodInfo(target, selector, NULL);
    if (!method || !SRMenuObserverValidateZeroArgBlockGetter(method)) return NO;
    *status = SRMenuGetterOK;
    @try {
        id block = ((id (*)(id, SEL))method_getImplementation(method))(target, selector);
        return block != nil;
    } @catch (__unused NSException *exception) {
        *status = SRMenuGetterFailed;
        return NO;
    }
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
/* Reservation for one in-flight click: admission is charged before any getter
 * is read, so two overlapping clicks cannot exceed the select limit. */
@property(nonatomic) NSUInteger selectReserved;
/* Minimal reentrancy guard: a getter that re-enters select must not read
 * getters again or record a second observation. */
@property(nonatomic) BOOL selectGuardActive;
@property(nonatomic) NSUInteger selectGuardToken;
@property(nonatomic) NSUInteger selectGuardSeq;
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
            self.selectReserved = 0;
            self.selectGuardActive = NO;
            self.selectGuardToken = 0;
            self.selectGuardSeq += 1;
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

- (BOOL)observationStillValidForSession:(NSUInteger)session {
    @synchronized(self.lock) {
        if (session != self.session || !_sampling) return NO;
        NSTimeInterval now = self.clock();
        if (!isfinite(now) || now >= self.deadline) { [self stopLocked:@"timeout"]; return NO; }
        return YES;
    }
}

- (NSUInteger)acquireSelectGuardLocked {
    self.selectGuardActive = YES;
    self.selectGuardToken = ++self.selectGuardSeq;
    return self.selectGuardToken;
}

- (void)releaseSelectGuardLocked:(NSUInteger)token {
    // A stale owner must not clear a newer call's guard.
    if (!self.selectGuardActive || self.selectGuardToken != token) return;
    self.selectGuardActive = NO;
}

/* Candidate handler clues for the clicked item, read only from declared
 * zero-argument getters after their ABI matched. After every getter returns the
 * session, sampling state and deadline are re-checked; if any changed, no
 * further getter is read and no observation is committed. Never calls the
 * action, never runs the block, never reads extraInfo/userInfo or any message
 * content. */
- (void)releaseSelectReservationLocked:(NSUInteger)session {
    // Only the session that owns the reservation may release it; a new session
    // already discarded the old one when it started.
    if (session != self.session) return;
    if (self.selectReserved > 0) self.selectReserved -= 1;
}

/* Candidate handler clues for the clicked item, read only from declared
 * zero-argument getters after their ABI matched. `gate` is called after every
 * getter; returning NO stops the remaining reads and aborts the observation.
 * Never calls the action, never runs the block, never reads extraInfo/userInfo
 * or any message content. */
- (NSDictionary *)handlerMetadataForItem:(id)item receiver:(id)receiver gate:(BOOL (^)(void))gate {
    SRMenuGetterStatus targetStatus = SRMenuGetterMissing;
    SRMenuGetterStatus actionStatus = SRMenuGetterMissing;
    SRMenuGetterStatus blockStatus = SRMenuGetterMissing;
    SRMenuGetterStatus responderStatus = SRMenuGetterMissing;
    id target = nil; SEL action = NULL; BOOL blockPresent = NO;
    id responder = nil;
    if (item) {
        target = SRMenuObserverReadObjectGetter(item, NSSelectorFromString(@"target"), &targetStatus);
        if (!gate()) return nil;
        action = SRMenuObserverReadSELGetter(item, NSSelectorFromString(@"action"), &actionStatus);
        if (!gate()) return nil;
        blockPresent = SRMenuObserverReadBlockGetter(item, NSSelectorFromString(@"actionBlock"), &blockStatus);
        if (!gate()) return nil;
    }
    NSString *kind = @"none";
    NSString *targetToken = @"<missing>";
    NSString *actionToken = @"<missing>";
    NSString *signature = @"<missing>";
    NSString *responderToken = @"<nil>";
    NSString *responderSignature = @"<missing>";
    NSString *blockToken = blockStatus == SRMenuGetterOK ? (blockPresent ? @"yes" : @"no")
        : (blockStatus == SRMenuGetterFailed ? @"<error>" : @"<missing>");
    if (targetStatus == SRMenuGetterFailed) targetToken = @"<error>";
    else if (targetStatus == SRMenuGetterMissing) targetToken = @"<missing>";
    else targetToken = SRMenuMetadataToken(target ? NSStringFromClass(object_getClass(target)) : nil);
    if (actionStatus == SRMenuGetterFailed) actionToken = @"<error>";
    else if (actionStatus == SRMenuGetterMissing) actionToken = @"<missing>";
    else actionToken = action ? SRMenuMetadataToken(NSStringFromSelector(action)) : @"<nil>";
    if (targetStatus == SRMenuGetterOK && target) {
        kind = @"target";
        if (actionStatus == SRMenuGetterOK && action) {
            signature = SRMenuMetadataSignature(SRMenuDeclaredMethodInfo(target, action, NULL));
        }
    } else if (targetStatus == SRMenuGetterOK) {
        targetToken = @"<nil>";
        if (actionStatus == SRMenuGetterOK && action) {
            responder = SRMenuObserverReadObjectGetter(receiver, NSSelectorFromString(@"responder"), &responderStatus);
            if (!gate()) return nil;
            if (responderStatus == SRMenuGetterOK && responder) {
                kind = @"responder";
                responderToken = SRMenuMetadataToken(NSStringFromClass(object_getClass(responder)));
                responderSignature = SRMenuMetadataSignature(SRMenuDeclaredMethodInfo(responder, action, NULL));
            } else {
                responderToken = responderStatus == SRMenuGetterFailed ? @"<error>"
                    : (responderStatus == SRMenuGetterOK ? @"<nil>" : @"<missing>");
                if (blockPresent) kind = @"block";
            }
        } else if (blockPresent) {
            kind = @"block";
        }
    } else if (blockPresent) {
        kind = @"block";
    }
    return @{@"handlerKind": kind, @"handlerTarget": targetToken, @"handlerAction": actionToken,
             @"handlerSignature": signature, @"responder": responderToken,
             @"responderSignature": responderSignature, @"actionBlock": blockToken};
}

/* Private test seam: inspects the getter ABI of arbitrary objects without a
 * session. Not part of the public header and never used by production paths. */
+ (NSDictionary *)inspectHandlerGettersForItem:(id)item receiver:(id)receiver {
    SRMenuCallObserver *probe = [[SRMenuCallObserver alloc] initWithClock:^NSTimeInterval { return 0; }];
    return [probe handlerMetadataForItem:item receiver:receiver gate:^BOOL { return YES; }];
}

- (void)recordSelectionItem:(id)item itemView:(id)view receiver:(id)receiver {
    BOOL itemKnown = item && self.itemClass && object_getClass(item) == self.itemClass;
    NSUInteger session = 0, guard = 0;
    BOOL reserved = NO;
    @try {
        /* Phase 1: admission, reservation and guard before any host getter. */
        @synchronized(self.lock) {
            if (!_sampling) return;
            if (self.selectGuardActive) return;      // nested click: forward only
            guard = [self acquireSelectGuardLocked];
            NSTimeInterval now = self.clock();
            if (![self admitKind:@"select" limit:SRMenuObserverSelectLimit
                            used:self.selectCount + self.selectReserved now:now]) return;
            session = self.session;
            self.selectReserved += 1;
            reserved = YES;
        }
        /* Phase 2: outside the lock, with a check after every getter. */
        NSDictionary *handler = itemKnown
            ? [self handlerMetadataForItem:item receiver:receiver gate:^BOOL {
                return [self observationStillValidForSession:session];
            }]
            : nil;
        /* Phase 3: commit only for the session that admitted the click, and only
         * if the deadline still holds at commit time. */
        @synchronized(self.lock) {
            if (reserved) { [self releaseSelectReservationLocked:session]; reserved = NO; }
            if (session != self.session || !_sampling) return;
            NSTimeInterval commitNow = self.clock();
            if (!isfinite(commitNow) || commitNow >= self.deadline) { [self stopLocked:@"timeout"]; return; }
            if (self.events.count >= self.budget) { [self stopLocked:@"budget"]; return; }
            BOOL viewKnown = view && self.itemClass && object_getClass(view) == self.itemClass;
            id initValue = @"<none>";
            NSString *link = @"none";
            if (self.initCount > 0) {
                NSNumber *index = item ? [self.constructedIndex objectForKey:item] : nil;
                if (index) { initValue = index; link = @"matched"; }
                else if (item && [self.droppedConstructs containsObject:item]) { initValue = @"<overflow>"; link = @"unmatched"; }
                else { initValue = @"<unmatched>"; link = @"unmatched"; }
            }
            NSMutableDictionary *entry = [@{@"kind": @"select",
                @"receiver": SRMenuMetadataToken(NSStringFromClass(object_getClass(receiver))),
                @"view": SRMenuMetadataToken(NSStringFromClass(object_getClass(view))),
                @"link": link,
                @"init": initValue} mutableCopy];
            if (handler) [entry addEntriesFromDictionary:handler];
            [self appendMetadataLocked:entry];
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
    } @finally {
        @synchronized(self.lock) {
            if (reserved) { [self releaseSelectReservationLocked:session]; reserved = NO; }
            [self releaseSelectGuardLocked:guard];
        }
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

/* -------------------------------------------------------------------------
 * Production menu-build interposer.
 *
 * One owner per process. The host's setMenuItems: is replaced only after the
 * declared method passes the ABI gate; the original is invoked exactly once with
 * the array we publish, and an observation failure never blocks the host call.
 * ---------------------------------------------------------------------- */
static NSObject *SRMenuBuildGlobalLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static SRMenuBuildHook *SRMenuBuildOwner;
static IMP SRMenuBuildOriginalIMP;
static Method SRMenuBuildSetterMethod;
static Class SRMenuBuildInstalledClass;
static BOOL SRMenuBuildEverInstalled;

static BOOL SRMenuBuildSetterShape(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    char *ret = method_copyReturnType(method);
    BOOL ok = ret && ret[0] == 'v';
    free(ret);
    if (!ok) return NO;
    char *selfType = method_copyArgumentType(method, 0);
    char *cmdType = method_copyArgumentType(method, 1);
    char *itemsType = method_copyArgumentType(method, 2);
    ok = selfType && selfType[0] == '@' && cmdType && cmdType[0] == ':' &&
        itemsType && itemsType[0] == '@';
    free(selfType); free(cmdType); free(itemsType);
    return ok;
}

@interface SRMenuBuildHook (SRForward)
- (id)publishItems:(id)items menu:(id)menu;
@end

static void SRMenuBuildForward(id self, SEL command, id items) {
    IMP original = NULL;
    SRMenuBuildHook *hook = nil;
    @synchronized(SRMenuBuildGlobalLock()) {
        original = SRMenuBuildOriginalIMP;
        hook = SRMenuBuildOwner;
    }
    id published = items;
    if (hook) @try {
        published = [hook publishItems:items menu:self];
    } @catch (__unused NSException *exception) {
        published = items;
    }
    if (original) ((void (*)(id, SEL, id))original)(self, command, published);
}

@interface SRMenuBuildHook ()
@property(nonatomic, strong) SRMessageMenuHook *hook;
@property(nonatomic) Class menuClass;
@property(nonatomic) Class coverClass;
@property(nonatomic) Class cellClass;
@property(nonatomic) Class itemClass;
@property(nonatomic) BOOL installed;
@property(nonatomic) BOOL restoreRefused;
@property(nonatomic) NSUInteger buildCounter;
- (id)publishItems:(id)items menu:(id)menu;
@end

@implementation SRMenuBuildHook
- (instancetype)initWithHook:(SRMessageMenuHook *)hook menuClass:(Class)menuClass
                  coverClass:(Class)coverClass cellClass:(Class)cellClass itemClass:(Class)itemClass {
    self = [super init];
    if (self) {
        _hook = hook;
        _menuClass = menuClass;
        _coverClass = coverClass;
        _cellClass = cellClass;
        _itemClass = itemClass;
    }
    return self;
}
- (BOOL)installed { return _installed; }
- (id)publishItems:(id)items menu:(id)menu {
    if (!self.hook || !menu) return items;
    if (!self.hook.enabled || !self.hook.enabled()) return items;
    NSString *generation = [[NSString alloc] initWithFormat:@"build:%lu", (unsigned long)++self.buildCounter];
    SRMenuMessageContext *context = [self.hook contextForMenu:menu generation:generation];
    if (!context) return items;
    return [self.hook appendHostItemToItems:items menu:menu source:context
                                  itemClass:self.itemClass generation:generation];
}
- (BOOL)install:(NSError **)error {
    @synchronized(SRMenuBuildGlobalLock()) {
        if (self.installed) return NO;
        if (SRMenuBuildOwner) {
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.MenuBuild" code:1 userInfo:nil];
            return NO;
        }
        if (SRMenuBuildEverInstalled) {
            if (self.menuClass != SRMenuBuildInstalledClass) {
                if (error) *error = [NSError errorWithDomain:@"SyncRelay.MenuBuild" code:3 userInfo:nil];
                return NO;
            }
            // Re-installing on the same class would overwrite the predecessor the
            // existing trampoline is bound to. Only the untouched original chain
            // may be re-bound; a chain that now points back at our trampoline is
            // refused without modifying anything.
            if (!SRMenuBuildSetterMethod ||
                method_getImplementation(SRMenuBuildSetterMethod) != SRMenuBuildOriginalIMP ||
                SRMenuBuildOriginalIMP == (IMP)SRMenuBuildForward) {
                if (error) *error = [NSError errorWithDomain:@"SyncRelay.MenuBuild" code:4 userInfo:nil];
                return NO;
            }
        }
        Method setter = SRMenuHookMethod(self.menuClass, NSSelectorFromString(@"setMenuItems:"));
        if (!SRMenuBuildSetterShape(setter)) {
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.MenuBuild" code:2 userInfo:nil];
            return NO;
        }
        [self.hook configureHostClasses:self.menuClass coverClass:self.coverClass cellClass:self.cellClass];
        SRMenuBuildOriginalIMP = method_setImplementation(setter, (IMP)SRMenuBuildForward);
        SRMenuBuildSetterMethod = setter;
        SRMenuBuildInstalledClass = self.menuClass;
        SRMenuBuildEverInstalled = YES;
        SRMenuBuildOwner = self;
        _installed = YES;
        return YES;
    }
}
- (void)uninstall {
    @synchronized(SRMenuBuildGlobalLock()) {
        if (!_installed) return;
        BOOL ours = SRMenuBuildSetterMethod &&
            method_getImplementation(SRMenuBuildSetterMethod) == (IMP)SRMenuBuildForward;
        if (!ours) {
            // A later hook owns the method now. Restoring would overwrite it, and
            // clearing the forwarding state would strand the trampoline with no
            // original. Keep both and report the refusal honestly.
            _restoreRefused = YES;
            return;
        }
        method_setImplementation(SRMenuBuildSetterMethod, SRMenuBuildOriginalIMP);
        if (SRMenuBuildOwner == self) SRMenuBuildOwner = nil;
        // A call already inside the trampoline still needs the original this
        // installation captured; keep both until the next install replaces them.
        _installed = NO;
        _restoreRefused = NO;
    }
}
- (BOOL)restoreRefused { return _restoreRefused; }
@end
