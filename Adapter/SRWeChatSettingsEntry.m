#import "SRWeChatSettingsEntry.h"
#import "SRRuntime.h"
#import <objc/runtime.h>
#include <string.h>

static char SRSettingsRowKey, SRSettingsCellKey, SRSettingsRefreshKey, SRSettingsEmbeddedKey, SRSettingsFactoryKey;
static char SRSettingsActionKey, SRSettingsNeedsRefreshKey;

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
@property(nonatomic, strong) NSMutableArray<SRSettingsTap *> *taps;
@property(nonatomic, copy) NSString *tableSource;
@property(nonatomic, copy) NSString *tableClass;
@property(nonatomic, copy) NSString *cellFactory;
@property(nonatomic) NSUInteger refreshes;
- (BOOL)appendToController:(id)controller;
@end

@interface SRSettingsTap : NSObject
@property(nonatomic) IMP original;
@property(nonatomic, copy) NSString *name;
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
static BOOL SRSettingsHookSignature(NSMethodSignature *signature, BOOL animated) {
    if (!animated) return SRSettingsVoidSignature(signature, 0);
    if (!signature || strcmp(SRSettingsType(signature.methodReturnType), "v") || signature.numberOfArguments != 3) return NO;
    const char *type = SRSettingsType([signature getArgumentTypeAtIndex:2]);
    return !strcmp(type, "B") || !strcmp(type, "c");
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
static NSArray *SRSettingsCells(id section) {
    id cells = SRReadObject(section, @"getAllCells", @[], NULL) ?: SRReadObject(section, @"cells", @[], NULL);
    return [cells isKindOfClass:NSArray.class] ? cells : nil;
}
static BOOL SRSettingsRefreshTable(id section, id table) {
    BOOL refreshed = SRSettingsVoid(table, @"reloadData", @[]);
    objc_setAssociatedObject(section, &SRSettingsNeedsRefreshKey, @(!refreshed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return refreshed;
}
static BOOL SRSettingsIntegerType(const char *type) {
    return strlen(type) == 1 && strchr("iIlLqQ", type[0]) != NULL;
}
static void SRSettingsSetInteger(NSInvocation *invocation, const char *type, NSUInteger index, NSUInteger value) {
    if (strchr("iI", type[0])) { unsigned int number = (unsigned int)value; [invocation setArgument:&number atIndex:index]; }
    else if (strchr("lL", type[0])) { unsigned long number = value; [invocation setArgument:&number atIndex:index]; }
    else { unsigned long long number = value; [invocation setArgument:&number atIndex:index]; }
}
static BOOL SRSettingsCanInsert(id section) {
    NSMethodSignature *signature = SRSettingsSignature(section, @"insertCell:At:");
    if (!signature || strcmp(SRSettingsType(signature.methodReturnType), "v") || signature.numberOfArguments != 4) return NO;
    const char *object = SRSettingsType([signature getArgumentTypeAtIndex:2]);
    return object[0] == '@' && object[1] != '?' && SRSettingsIntegerType(SRSettingsType([signature getArgumentTypeAtIndex:3]));
}
static BOOL SRSettingsInsert(id section, id cell) {
    @try {
        if (!SRSettingsCanInsert(section)) return NO;
        NSMethodSignature *signature = SRSettingsSignature(section, @"insertCell:At:");
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = section; invocation.selector = NSSelectorFromString(@"insertCell:At:");
        __unsafe_unretained id value = cell; [invocation setArgument:&value atIndex:2];
        SRSettingsSetInteger(invocation, SRSettingsType([signature getArgumentTypeAtIndex:3]), 3, 0);
        [invocation invoke]; return YES;
    } @catch (__unused NSException *exception) { return NO; }
}
static id SRSettingsCell(Class cellClass, SRSettingsAction *action) {
    for (NSString *name in @[@"normalCellForSel:target:title:rightValue:accessoryType:", @"normalCellForSel:target:title:"]) {
        @try {
            BOOL extended = [name hasSuffix:@"accessoryType:"];
            NSMethodSignature *signature = SRSettingsSignature(cellClass, name);
            const char *result = signature ? SRSettingsType(signature.methodReturnType) : "";
            if (!signature || result[0] != '@' || result[1] == '?' || signature.numberOfArguments != (extended ? 7 : 5) ||
                strcmp(SRSettingsType([signature getArgumentTypeAtIndex:2]), ":")) continue;
            BOOL objects = YES;
            for (NSUInteger i = 3; i < (extended ? 6 : 5); i++) {
                const char *type = SRSettingsType([signature getArgumentTypeAtIndex:i]);
                if (type[0] != '@' || type[1] == '?') objects = NO;
            }
            if (!objects) continue;
            const char *integer = extended ? SRSettingsType([signature getArgumentTypeAtIndex:6]) : "";
            if (extended && !SRSettingsIntegerType(integer)) continue;
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            invocation.target = cellClass; invocation.selector = NSSelectorFromString(name);
            SEL selector = @selector(activate); __unsafe_unretained id target = action, title = @"SyncRelay 转发", rightValue = @"";
            [invocation setArgument:&selector atIndex:2]; [invocation setArgument:&target atIndex:3]; [invocation setArgument:&title atIndex:4];
            if (extended) {
                [invocation setArgument:&rightValue atIndex:5];
                SRSettingsSetInteger(invocation, integer, 6, 1);
            }
            [invocation invoke]; __unsafe_unretained id cell = nil; [invocation getReturnValue:&cell];
            if (cell) {
                objc_setAssociatedObject(cell, &SRSettingsActionKey, action, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return cell;
            }
        } @catch (__unused NSException *exception) { }
    }
    return nil;
}

@implementation SRWeChatSettingsEntry
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class (^)(NSString *))resolver open:(void (^)(id))open {
    self = [super init];
    if (self) {
        _version = [version copy]; _resolver = [resolver copy]; _open = [open copy]; _state = @"not_installed";
        _taps = [NSMutableArray array]; _tableSource = @"unavailable"; _tableClass = @"unavailable"; _cellFactory = @"unavailable";
    }
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
    // Diagnostic/settings access must not inherit the messaging adapter's version gate.
    Class controller = self.resolver(@"NewSettingViewController");
    if (!controller) return [self fail:@"settings_class_unavailable" error:error];
    BOOL wasInstalled = self.taps.count > 0;
    @synchronized(SRSettingsTaps()) {
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)controller];
        NSMutableDictionary *classTaps = SRSettingsTaps()[key];
        for (SRSettingsTap *existing in classTaps.allValues) {
            if (existing.listener && existing.listener != self) return [self fail:@"entry_already_owned" error:error];
        }
        if (!classTaps) { classTaps = [NSMutableDictionary dictionary]; SRSettingsTaps()[key] = classTaps; }
        for (NSString *name in @[@"reloadTableData", @"viewDidLoad", @"viewWillAppear:", @"viewDidAppear:", @"willAppear"]) {
            SEL selector = NSSelectorFromString(name); BOOL animated = [name hasSuffix:@":"];
            Method method = class_getInstanceMethod(controller, selector);
            NSMethodSignature *signature = method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
            if (!SRSettingsHookSignature(signature, animated)) continue;
            SRSettingsTap *tap = classTaps[name];
            if (!tap) {
                tap = [[SRSettingsTap alloc] init]; tap.original = method_getImplementation(method); tap.name = name;
                SRSettingsTap *installed = tap;
                IMP replacement;
                if (animated) replacement = imp_implementationWithBlock(^(id object, BOOL value) {
                    ((void (*)(id, SEL, BOOL))installed.original)(object, selector, value);
                    [installed.listener refreshController:object];
                });
                else replacement = imp_implementationWithBlock(^(id object) {
                    ((void (*)(id, SEL))installed.original)(object, selector);
                    [installed.listener refreshController:object];
                });
                if (!class_addMethod(controller, selector, replacement, method_getTypeEncoding(method)))
                    tap.original = method_setImplementation(class_getInstanceMethod(controller, selector), replacement);
                classTaps[name] = tap;
            }
            tap.listener = self;
            if (![self.taps containsObject:tap]) [self.taps addObject:tap];
        }
    }
    if (!self.taps.count) return [self fail:@"incompatible_settings_lifecycle" error:error];
    if (!wasInstalled) self.state = @"waiting_for_settings_page";
    return YES;
}
- (BOOL)refreshController:(id)controller {
    Class settings = self.resolver(@"NewSettingViewController");
    if (!NSThread.isMainThread || !settings || ![controller isKindOfClass:settings] ||
        objc_getAssociatedObject(controller, &SRSettingsRefreshKey)) return NO;
    BOOL present = NO;
    objc_setAssociatedObject(controller, &SRSettingsRefreshKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        self.refreshes++;
        present = [self appendToController:controller];
    } @catch (__unused NSException *exception) { self.state = @"optional_entry_exception"; }
    @try { if (self.updated) self.updated(controller, present); }
    @catch (__unused NSException *exception) { self.state = @"optional_recovery_entry_exception"; }
    @finally { objc_setAssociatedObject(controller, &SRSettingsRefreshKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return present;
}
- (BOOL)appendToController:(id)controller {
    id tableInfo = nil;
    self.tableSource = @"unavailable"; self.tableClass = @"unavailable"; self.cellFactory = @"unavailable";
    for (NSString *name in @[@"m_tableViewMgr", @"m_tableViewInfo"]) {
        tableInfo = SRReadObject(controller, name, @[], NULL);
        if (!tableInfo) tableInfo = SRSettingsObjectIvar(controller, name);
        if (!tableInfo) tableInfo = SRSettingsObjectIvar(controller, [@"_" stringByAppendingString:name]);
        if (tableInfo) { self.tableSource = name; self.tableClass = NSStringFromClass(object_getClass(tableInfo)); break; }
    }
    if (!tableInfo) { self.state = @"table_info_unavailable"; return NO; }
    NSArray *sections = SRSettingsSections(tableInfo);
    if (!sections) { self.state = @"section_list_unavailable"; return NO; }
    id table = SRReadObject(tableInfo, @"getTableView", @[], NULL);
    if (!SRSettingsVoidSignature(SRSettingsSignature(table, @"reloadData"), 0)) {
        self.state = @"incompatible_table_methods"; return NO;
    }
    for (id section in sections) {
        SRSettingsAction *action = objc_getAssociatedObject(section, &SRSettingsRowKey);
        if (![action isKindOfClass:SRSettingsAction.class]) continue;
        action.controller = controller; action.open = self.open;
        NSArray *cells = SRSettingsCells(section);
        id cell = objc_getAssociatedObject(section, &SRSettingsCellKey);
        if (cells && ![cells containsObject:cell]) {
            BOOL restored = cell && ([objc_getAssociatedObject(section, &SRSettingsEmbeddedKey) boolValue] ?
                SRSettingsInsert(section, cell) : SRSettingsVoid(section, @"addCell:", @[cell]));
            if (!restored || ![SRSettingsCells(section) containsObject:cell] || !SRSettingsRefreshTable(section, table)) {
                self.state = @"row_restore_failed"; return NO;
            }
        } else if ([objc_getAssociatedObject(section, &SRSettingsNeedsRefreshKey) boolValue] && !SRSettingsRefreshTable(section, table)) {
            self.state = @"table_refresh_failed"; return NO;
        }
        self.cellFactory = objc_getAssociatedObject(section, &SRSettingsFactoryKey) ?: @"unavailable";
        self.state = @"row_present"; return YES;
    }
    BOOL manager = [self.tableSource isEqual:@"m_tableViewMgr"];
    SRSettingsAction *action = [[SRSettingsAction alloc] init]; action.controller = controller; action.open = self.open;
    NSString *factoryName = manager ? @"WCTableViewNormalCellManager" : @"MMTableViewCellInfo";
    id cell = SRSettingsCell(self.resolver(factoryName), action);
    id firstSection = sections.firstObject;
    NSArray *firstCells = SRSettingsCells(firstSection);
    // Mikoto's native-settings path inserts into an existing section, not its own MM table.
    if (manager && cell && firstCells && SRSettingsCanInsert(firstSection)) {
        objc_setAssociatedObject(firstSection, &SRSettingsRowKey, action, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(firstSection, &SRSettingsCellKey, cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(firstSection, &SRSettingsEmbeddedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(firstSection, &SRSettingsFactoryKey, factoryName, OBJC_ASSOCIATION_COPY_NONATOMIC);
        if (!SRSettingsInsert(firstSection, cell) || ![SRSettingsCells(firstSection) containsObject:cell]) {
            self.state = @"insert_not_confirmed"; return NO;
        }
        self.cellFactory = factoryName;
        BOOL refreshed = SRSettingsRefreshTable(firstSection, table);
        self.state = refreshed ? @"row_present" : @"table_refresh_failed";
        return refreshed;
    }
    if (!SRSettingsVoidSignature(SRSettingsSignature(tableInfo, @"addSection:"), 1)) {
        self.state = @"incompatible_table_methods"; return NO;
    }
    Class sectionClass = self.resolver(manager ? @"WCTableViewSectionManager" : @"MMTableViewSectionInfo");
    id section = SRReadObject(sectionClass, manager ? @"defaultSection" : @"sectionInfoDefaut", @[], NULL);
    if (!section && sections.count) {
        Class existingClass = object_getClass(sections.firstObject);
        section = SRReadObject(existingClass, @"defaultSection", @[], NULL) ?: SRReadObject(existingClass, @"sectionInfoDefaut", @[], NULL);
    }
    if (!section || !cell || !SRSettingsVoid(section, @"addCell:", @[cell])) { self.state = @"cell_factory_unavailable"; return NO; }
    self.cellFactory = factoryName;
    // Retain our target separately: native cell factories may store it weakly.
    objc_setAssociatedObject(section, &SRSettingsRowKey, action, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(section, &SRSettingsCellKey, cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(section, &SRSettingsFactoryKey, factoryName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (!SRSettingsVoid(tableInfo, @"addSection:", @[section])) { self.state = @"append_failed"; return NO; }
    if (![SRSettingsSections(tableInfo) containsObject:section]) { self.state = @"append_not_confirmed"; return NO; }
    NSArray *cells = SRSettingsCells(section);
    if (cells && ![cells containsObject:cell]) { self.state = @"cell_not_confirmed"; return NO; }
    BOOL refreshed = SRSettingsRefreshTable(section, table);
    self.state = refreshed ? @"row_present" : @"table_refresh_failed";
    return refreshed;
}
- (NSDictionary *)diagnostics {
    NSMutableArray *hooks = [NSMutableArray array];
    for (SRSettingsTap *tap in self.taps) [hooks addObject:tap.name];
    return @{ @"installed": @(self.taps.count > 0), @"state": self.state, @"floatingFallbackForced": @NO,
        @"hooks": hooks, @"refreshCount": @(self.refreshes), @"tableSource": self.tableSource,
        @"tableClass": self.tableClass, @"cellFactory": self.cellFactory,
        @"messagingVersionAllowlisted": @([@[@"8.0.76", @"8.0.79"] containsObject:self.version]),
        @"methods": @[SRDescribeInstanceMethod(self.resolver(@"NewSettingViewController"), @"reloadTableData"),
            SRDescribeInstanceMethod(self.resolver(@"NewSettingViewController"), @"m_tableViewMgr"),
            SRDescribeInstanceMethod(self.resolver(@"NewSettingViewController"), @"viewDidAppear:"),
            SRDescribeMethod(self.resolver(@"WCTableViewSectionManager"), @"defaultSection"),
            SRDescribeMethod(self.resolver(@"WCTableViewNormalCellManager"), @"normalCellForSel:target:title:rightValue:accessoryType:")] };
}
@end
