#import "SRMenuABIProbe.h"
#import <objc/runtime.h>
#include <stdlib.h>

/* Fixed ceiling: beyond this the probe stops and reports over_limit instead of
 * copying or walking further arguments. */
static const unsigned int SRMenuProbeArgumentLimit = 8;

static NSString *const SRMenuTokenUnknown = @"unknown";

@interface SRMenuABIProbe ()
@property(nonatomic, copy, nullable) SRMenuABIResolver resolver;
/* Only the latest collection is kept; -collect replaces it and nothing else
 * writes it. Reading it is a plain property read with no scan behind it. */
@property(nonatomic, copy, nullable) NSArray<NSDictionary *> *lastSnapshot;
@end

@implementation SRMenuABIProbe

- (instancetype)initWithResolver:(nullable SRMenuABIResolver)resolver {
    self = [super init];
    if (self) {
        _resolver = [resolver copy];
    }
    return self;
}

- (void)collect {
    self.lastSnapshot = [self snapshot];
}

/* Skips leading type qualifiers only. Nothing else is ignored. */
static const char *SRMenuTypeStart(const char *type) {
    if (!type) return NULL;
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' || *type == 'O' ||
           *type == 'R' || *type == 'V') type++;
    return type;
}

/* Closed whitelist following Apple's encoding meanings. `c` is a char, not a
 * BOOL; `l`/`L` stay distinct from `q`/`Q`. An unrecognised type becomes
 * `unknown` and the original description is never echoed back. */
static NSString *SRMenuTokenForType(const char *type) {
    const char *start = SRMenuTypeStart(type);
    if (!start || !*start) return SRMenuTokenUnknown;
    switch (*start) {
        case 'v': return @"void";
        case '@': return start[1] == '?' ? @"block" : @"object";
        case ':': return @"SEL";
        case 'B': return @"bool";
        case 'c': return @"char";
        case 'C': return @"uchar";
        case 's': return @"int16";
        case 'S': return @"uint16";
        case 'i': return @"int32";
        case 'I': return @"uint32";
        case 'l': return @"long";
        case 'L': return @"ulong";
        case 'q': return @"int64";
        case 'Q': return @"uint64";
        case '^': return @"pointer";
        default: return SRMenuTokenUnknown;
    }
}

/* Walks an existing method table chain and the method lists themselves.
 *
 * class_getInstanceMethod / class_getClassMethod are deliberately not used: on a
 * class that overrides +resolveInstanceMethod: / +resolveClassMethod: they may
 * trigger dynamic resolution, which would run host code. class_copyMethodList
 * only reads what is already there. */
static Method SRMenuLookupMethod(Class start, SEL selector, BOOL *declaredOnStart) {
    if (!start) return NULL;
    if (declaredOnStart) *declaredOnStart = NO;
    for (Class current = start; current != Nil; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        if (!methods) continue;
        Method found = NULL;
        for (unsigned int index = 0; index < count; index++) {
            if (method_getName(methods[index]) == selector) { found = methods[index]; break; }
        }
        free(methods);
        if (found) {
            if (declaredOnStart) *declaredOnStart = (current == start);
            return found;
        }
    }
    return NULL;
}

- (NSDictionary *)entryForClassName:(NSString *)className selector:(NSString *)selectorName {
    NSString *label = [NSString stringWithFormat:@"%@ / %@", className, selectorName];
    // The resolver writes through a non-owning out-parameter; no Class crosses a
    // function or block return here. The local starts Nil, so a resolver that
    // writes nothing reports `missing` and never falls back to the runtime.
    __unsafe_unretained Class cls = Nil;
    if (self.resolver) {
        self.resolver(className, &cls);
    } else {
        cls = NSClassFromString(className);
    }
    if (!cls) {
        return @{@"candidate": label, @"classStatus": @"missing", @"methodStatus": @"missing",
                 @"argumentCount": @"0", @"returnToken": SRMenuTokenUnknown, @"argumentTokens": @[]};
    }
    SEL selector = NSSelectorFromString(selectorName);
    BOOL direct = NO;
    Method method = SRMenuLookupMethod(cls, selector, &direct);
    if (!method) {
        // A class method with the same name is still not the candidate we need.
        BOOL declaredOnMeta = NO;
        Method classMethod = SRMenuLookupMethod(object_getClass(cls), selector, &declaredOnMeta);
        return @{@"candidate": label, @"classStatus": @"present",
                 @"methodStatus": classMethod ? @"class_only" : @"missing",
                 @"argumentCount": @"0", @"returnToken": SRMenuTokenUnknown, @"argumentTokens": @[]};
    }
    NSString *methodStatus = direct ? @"direct" : @"inherited";

    char *returnType = method_copyReturnType(method);
    NSString *returnToken = SRMenuTokenForType(returnType);
    free(returnType);

    unsigned int total = method_getNumberOfArguments(method);
    if (total > SRMenuProbeArgumentLimit) {
        return @{@"candidate": label, @"classStatus": @"present", @"methodStatus": methodStatus,
                 @"argumentCount": @"over_limit", @"returnToken": returnToken, @"argumentTokens": @[]};
    }
    NSMutableArray *tokens = [NSMutableArray arrayWithCapacity:total];
    for (unsigned int index = 0; index < total; index++) {
        char *argumentType = method_copyArgumentType(method, index);
        [tokens addObject:SRMenuTokenForType(argumentType)];
        free(argumentType);
    }
    return @{@"candidate": label, @"classStatus": @"present", @"methodStatus": methodStatus,
             @"argumentCount": [NSString stringWithFormat:@"%u", total],
             @"returnToken": returnToken, @"argumentTokens": tokens};
}

- (NSArray<NSDictionary *> *)snapshot {
    return @[
        [self entryForClassName:@"MMMenuController" selector:@"setMenuItems:"],
        [self entryForClassName:@"MMMenuController" selector:@"onMenuItemSelected:itemView:"],
        [self entryForClassName:@"MMMenuItem" selector:@"initWithTitle:icon:target:action:"],
    ];
}

@end
