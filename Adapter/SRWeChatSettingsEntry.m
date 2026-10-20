#import "SRWeChatSettingsEntry.h"
#import "SRRuntime.h"
#import <objc/runtime.h>
#include <string.h>

static char SRSettingsRowKey;

@interface SRSettingsAction : NSObject
@property(nonatomic, weak) id controller;
@property(nonatomic, copy) void (^open)(id);
- (void)activate;
@end
@implementation SRSettingsAction
- (void)activate {
    id controller = self.controller;
    if (NSThread.isMainThread && controller) self.open(controller);
}
@end

@class SRSettingsTap;
@interface SRWeChatSettingsEntry ()
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) Class (^resolver)(NSString *);
@property(nonatomic, copy) void (^open)(id);
@property(nonatomic, copy) NSString *state;
@property(nonatomic, strong) SRSettingsTap *tap;
- (void)appendToController:(id)controller;
@end

@interface SRSettingsTap : NSObject
@property(nonatomic) IMP original;
@property(nonatomic, weak) SRWeChatSettingsEntry *listener;
@end
@implementation SRSettingsTap
@end

static NSMutableDictionary *SRSettingsTaps(void) {
    static NSMutableDictionary *taps; static dispatch_once_t once;
    dispatch_once(&once, ^{ taps = [NSMutableDictionary dictionary]; }); return taps;
}
static const char *SRSettingsType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}
static NSMethodSignature *SRSettingsSignature(id target, NSString *name) {
    @try {
        SEL selector = NSSelectorFromString(name);
        return [target respondsToSelector:selector] ? [target methodSignatureForSelector:selector] : nil;
    } @catch (__unused NSException *exception) { return nil; }
}
static BOOL SRSettingsVoidSignature(NSMethodSignature *signature, NSUInteger objects) {
    if (!signature || strcmp(SRSettingsType(signature.methodReturnType), "v") || signature.numberOfArguments != objects + 2) return NO;
    for (NSUInteger i = 2; i < signature.numberOfArguments; i++) {
        const char *type = SRSettingsType([signature getArgumentTypeAtIndex:i]);
        if (type[0] != '@' || type[1] == '?') return NO;
    }
    return YES;
}
static BOOL SRSettingsVoid(id target, NSString *name, NSArray *objects) {
    @try {
        NSMethodSignature *signature = SRSettingsSignature(target, name);
        if (!SRSettingsVoidSignature(signature, objects.count)) return NO;
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target; invocation.selector = NSSelectorFromString(name);
        for (NSUInteger i = 0; i < objects.count; i++) {
            __unsafe_unretained id value = objects[i]; [invocation setArgument:&value atIndex:i + 2];
        }
        [invocation invoke]; return YES;
    } @catch (__unused NSException *exception) { return NO; }
}
static id SRSettingsObjectIvar(id object, NSString *name) {
    Ivar ivar = object ? class_getInstanceVariable(object_getClass(object), name.UTF8String) : NULL;
    const char *type = ivar ? SRSettingsType(ivar_getTypeEncoding(ivar)) : "";
    if (type[0] != '@' || type[1] == '?') return nil;
    return object_getIvar(object, ivar);
}
static NSArray *SRSettingsSections(id tableInfo) {
    id sections = SRReadObject(tableInfo, @"sections", @[], NULL);
    if (![sections isKindOfClass:NSArray.class]) sections = SRSettingsObjectIvar(tableInfo, @"_sections");
    if (![sections isKindOfClass:NSArray.class]) sections = SRSettingsObjectIvar(tableInfo, @"m_arrSections");
    return [sections isKindOfClass:NSArray.class] ? sections : nil;
}
static id SRSettingsCell(Class cellClass, SRSettingsAction *action) {
    @try {
        NSString *name = @"normalCellForSel:target:title:";
        NSMethodSignature *signature = SRSettingsSignature(cellClass, name);
        const char *result = signature ? SRSettingsType(signature.methodReturnType) : "";
        if (!signature || result[0] != '@' || result[1] == '?' || signature.numberOfArguments != 5 ||
            strcmp(SRSettingsType([signature getArgumentTypeAtIndex:2]), ":")) return nil;
        for (NSUInteger i = 3; i < 5; i++) {
            const char *type = SRSettingsType([signature getArgumentTypeAtIndex:i]);
            if (type[0] != '@' || type[1] == '?') return nil;
        }
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = cellClass; invocation.selector = NSSelectorFromString(name);
        SEL selector = @selector(activate); __unsafe_unretained id target = action, title = @"SyncRelay 转发";
        [invocation setArgument:&selector atIndex:2]; [invocation setArgument:&target atIndex:3]; [invocation setArgument:&title atIndex:4];
        [invocation invoke]; __unsafe_unretained id cell = nil; [invocation getReturnValue:&cell]; return cell;
    } @catch (__unused NSException *exception) { return nil; }
}

@implementation SRWeChatSettingsEntry
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class (^)(NSString *))resolver open:(void (^)(id))open {
    self = [super init];
    if (self) { _version = [version copy]; _resolver = [resolver copy]; _open = [open copy]; _state = @"not_installed"; }
    return self;
}
- (BOOL)fail:(NSString *)state error:(NSError **)error {
    self.state = state;
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.SettingsEntry" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"微信设置入口尚不可用，请记录微信版本和构建号"}];
    return NO;
}
- (BOOL)install:(NSError **)error {
    if (!NSThread.isMainThread) return [self fail:@"not_main_thread" error:error];
    if (![@[@"8.0.76", @"8.0.79"] containsObject:self.version]) return [self fail:@"unsupported_version" error:error];
    Class controller = self.resolver(@"NewSettingViewController");
    SEL selector = NSSelectorFromString(@"reloadTableData");
    Method method = controller ? class_getInstanceMethod(controller, selector) : NULL;
    NSMethodSignature *signature = method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
    if (!SRSettingsVoidSignature(signature, 0)) return [self fail:@"incompatible_settings_reload" error:error];
    BOOL wasInstalled = self.tap != nil;
    @synchronized(SRSettingsTaps()) {
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)controller];
        SRSettingsTap *tap = SRSettingsTaps()[key];
        if (tap.listener && tap.listener != self) return [self fail:@"entry_already_owned" error:error];
        if (!tap) {
            tap = [[SRSettingsTap alloc] init]; tap.original = method_getImplementation(method);
            SRSettingsTap *installed = tap;
            IMP replacement = imp_implementationWithBlock(^(id object) {
                ((void (*)(id, SEL))installed.original)(object, selector);
                @try {
                    if (NSThread.isMainThread) [installed.listener appendToController:object];
                } @catch (__unused NSException *exception) { installed.listener.state = @"optional_entry_exception"; }
            });
            if (!class_addMethod(controller, selector, replacement, method_getTypeEncoding(method)))
                tap.original = method_setImplementation(class_getInstanceMethod(controller, selector), replacement);
            SRSettingsTaps()[key] = tap;
        }
        self.tap = tap; tap.listener = self;
    }
    if (!wasInstalled) self.state = @"waiting_for_settings_reload";
    return YES;
}
- (void)appendToController:(id)controller {
    id tableInfo = SRReadObject(controller, @"m_tableViewInfo", @[], NULL);
    if (!tableInfo) tableInfo = SRSettingsObjectIvar(controller, @"m_tableViewInfo");
    if (!tableInfo) tableInfo = SRSettingsObjectIvar(controller, @"_m_tableViewInfo");
    NSArray *sections = SRSettingsSections(tableInfo);
    if (!sections) { self.state = @"section_list_unavailable"; return; }
    for (id section in sections) {
        SRSettingsAction *action = objc_getAssociatedObject(section, &SRSettingsRowKey);
        if ([action isKindOfClass:SRSettingsAction.class]) {
            action.controller = controller; action.open = self.open; self.state = @"row_present"; return;
        }
    }
    id table = SRReadObject(tableInfo, @"getTableView", @[], NULL);
    if (!SRSettingsVoidSignature(SRSettingsSignature(table, @"reloadData"), 0) ||
        !SRSettingsVoidSignature(SRSettingsSignature(tableInfo, @"addSection:"), 1)) {
        self.state = @"incompatible_table_methods"; return;
    }
    id section = SRReadObject(self.resolver(@"MMTableViewSectionInfo"), @"sectionInfoDefaut", @[], NULL);
    SRSettingsAction *action = [[SRSettingsAction alloc] init]; action.controller = controller; action.open = self.open;
    id cell = SRSettingsCell(self.resolver(@"MMTableViewCellInfo"), action);
    if (!section || !cell || !SRSettingsVoid(section, @"addCell:", @[cell])) { self.state = @"cell_factory_unavailable"; return; }
    // The section retains the action even if the host's cell stores a non-retaining target.
    objc_setAssociatedObject(section, &SRSettingsRowKey, action, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!SRSettingsVoid(tableInfo, @"addSection:", @[section])) { self.state = @"append_failed"; return; }
    self.state = SRSettingsVoid(table, @"reloadData", @[]) ? @"row_present" : @"table_refresh_failed";
}
- (NSDictionary *)diagnostics {
    return @{ @"installed": @(self.tap != nil), @"state": self.state, @"floatingFallbackForced": @NO,
        @"methods": @[SRDescribeInstanceMethod(self.resolver(@"NewSettingViewController"), @"reloadTableData"),
            SRDescribeInstanceMethod(self.resolver(@"NewSettingViewController"), @"m_tableViewInfo"),
            SRDescribeMethod(self.resolver(@"MMTableViewSectionInfo"), @"sectionInfoDefaut"),
            SRDescribeMethod(self.resolver(@"MMTableViewCellInfo"), @"normalCellForSel:target:title:")] };
}
@end
