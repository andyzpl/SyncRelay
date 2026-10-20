#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Adapter/SRWeChatSettingsEntry.h"
#import "Core/SREntryPreferences.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

@interface NativeTable : NSObject
@property(nonatomic) NSUInteger reloads;
@property(nonatomic) BOOL throws;
- (void)reloadData;
@end
@implementation NativeTable
- (void)reloadData { self.reloads++; if (self.throws) @throw @"TableRefreshError"; }
@end

@interface NativeCell : NSObject
@property(nonatomic, weak) id target;
@property(nonatomic) SEL action;
@property(nonatomic, copy) NSString *title;
- (void)tap;
@end
@implementation NativeCell
- (void)tap { id target = self.target; ((void (*)(id, SEL))[target methodForSelector:self.action])(target, self.action); }
@end
@interface NativeCellFactory : NSObject
+ (id)normalCellForSel:(SEL)action target:(id)target title:(NSString *)title;
@end
@implementation NativeCellFactory
+ (id)normalCellForSel:(SEL)action target:(id)target title:(NSString *)title {
    NativeCell *cell = [[NativeCell alloc] init]; cell.target = target; cell.action = action; cell.title = title; return cell;
}
@end
@interface WrongCellFactory : NSObject
+ (id)normalCellForSel:(id)action target:(id)target title:(id)title;
@end
@implementation WrongCellFactory
+ (id)normalCellForSel:(__unused id)action target:(__unused id)target title:(__unused id)title { abort(); }
@end
@interface NativeSection : NSObject
@property(nonatomic, strong) NSMutableArray *cells;
+ (id)sectionInfoDefaut;
- (void)addCell:(id)cell;
@end
@implementation NativeSection
+ (id)sectionInfoDefaut { NativeSection *value = [[self alloc] init]; value.cells = [NSMutableArray array]; return value; }
- (void)addCell:(id)cell { [self.cells addObject:cell]; }
@end
@interface NativeTableInfo : NSObject
@property(nonatomic, strong) NSMutableArray *sections;
@property(nonatomic, strong) NativeTable *table;
- (void)addSection:(id)section;
- (id)getTableView;
@end
@implementation NativeTableInfo
- (instancetype)init { self = [super init]; if (self) { _sections = [NSMutableArray array]; _table = [[NativeTable alloc] init]; } return self; }
- (void)addSection:(id)section { [self.sections addObject:section]; }
- (id)getTableView { return self.table; }
@end
@interface NativeSettings : NSObject
@property(nonatomic, strong) NativeTableInfo *m_tableViewInfo;
@property(nonatomic) NSUInteger originalCalls;
@property(nonatomic) BOOL rebuild;
@property(nonatomic) BOOL throws;
@property(nonatomic) BOOL throwsObject;
- (void)reloadTableData;
@end
@implementation NativeSettings
- (instancetype)init { self = [super init]; if (self) { _m_tableViewInfo = [[NativeTableInfo alloc] init]; _rebuild = YES; } return self; }
- (void)reloadTableData {
    self.originalCalls++;
    if (self.throws) @throw [NSException exceptionWithName:@"HostError" reason:@"Private host content" userInfo:nil];
    if (self.throwsObject) @throw @"HostObjectError";
    if (self.rebuild) [self.m_tableViewInfo.sections setArray:@[[NativeSection sectionInfoDefaut]]];
}
@end
@interface InheritedSettings : NativeSettings
@end
@implementation InheritedSettings
@end
@interface FutureSettings : NativeSettings
@end
@implementation FutureSettings
- (void)reloadTableData { [super reloadTableData]; }
@end
@interface WrongSettings : NSObject
- (id)reloadTableData;
@end
@implementation WrongSettings
- (id)reloadTableData { abort(); }
@end
@interface IvarTableInfo : NSObject {
@public NSMutableArray *m_arrSections;
}
@property(nonatomic, strong) NativeTable *table;
- (void)addSection:(id)section;
- (id)getTableView;
@end
@implementation IvarTableInfo
- (instancetype)init { self = [super init]; if (self) { m_arrSections = [NSMutableArray array]; _table = [[NativeTable alloc] init]; } return self; }
- (void)addSection:(id)section { [m_arrSections addObject:section]; }
- (id)getTableView { return self.table; }
@end
@interface IvarSettings : NSObject {
@public id _m_tableViewInfo;
}
- (void)reloadTableData;
@end
@implementation IvarSettings
- (void)reloadTableData { }
@end
@interface FactorySettings : IvarSettings
@end
@implementation FactorySettings
- (void)reloadTableData { }
@end
@interface WrongMutationTable : NSObject
@property(nonatomic, strong) NSArray *sections;
@property(nonatomic, strong) NativeTable *table;
- (id)addSection:(id)section;
- (id)getTableView;
@end
@implementation WrongMutationTable
- (id)addSection:(__unused id)section { abort(); }
- (id)getTableView { return self.table; }
@end
@interface PointerSections : NSObject {
    void *_sections;
}
- (void *)sections;
@end
@implementation PointerSections
- (void *)sections { abort(); }
@end

@interface ManagerCellFactory : NSObject
+ (id)normalCellForSel:(SEL)action target:(id)target title:(NSString *)title rightValue:(NSString *)value accessoryType:(NSInteger)accessory;
@end
@implementation ManagerCellFactory
+ (id)normalCellForSel:(SEL)action target:(id)target title:(NSString *)title rightValue:(NSString *)value accessoryType:(NSInteger)accessory {
    CHECK(accessory == 1 && [value isEqual:@""]);
    return [NativeCellFactory normalCellForSel:action target:target title:title];
}
@end
@interface ManagerSection : NativeSection
+ (id)defaultSection;
- (id)getAllCells;
- (void)insertCell:(id)cell At:(int)index;
@end
@implementation ManagerSection
+ (id)defaultSection { return [self sectionInfoDefaut]; }
- (id)getAllCells { return self.cells; }
- (void)insertCell:(id)cell At:(int)index { CHECK(index == 0); [self.cells insertObject:cell atIndex:0]; }
@end
@interface ManagerSettings : NSObject
@property(nonatomic, strong) NativeTableInfo *m_tableViewMgr;
@property(nonatomic) NSUInteger loads;
@property(nonatomic) NSUInteger appearances;
@property(nonatomic) BOOL animated;
@property(nonatomic) BOOL throws;
- (void)viewDidLoad;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewDidAppear:(BOOL)animated;
@end
@implementation ManagerSettings
- (void)viewDidLoad {
    self.loads++; self.m_tableViewMgr = [[NativeTableInfo alloc] init];
    ManagerSection *section = [ManagerSection defaultSection]; [section addCell:[[NativeCell alloc] init]];
    [self.m_tableViewMgr.sections addObject:section];
}
- (void)viewWillAppear:(BOOL)animated { self.appearances++; self.animated = animated; }
- (void)viewDidAppear:(BOOL)animated {
    self.appearances++; self.animated = animated;
    if (self.throws) @throw [NSException exceptionWithName:@"AppearanceError" reason:@"Private host data" userInfo:nil];
}
@end
@interface ManagerIvarSettings : NSObject { @public id m_tableViewMgr; }
- (void)reloadTableData;
@end
@implementation ManagerIvarSettings
- (void)reloadTableData { }
@end
@interface WrongAppearanceSettings : NSObject
- (void)viewDidAppear:(void *)argument;
@end
@implementation WrongAppearanceSettings
- (void)viewDidAppear:(__unused void *)argument { abort(); }
@end
@interface WrongExtendedCellFactory : NSObject
+ (id)normalCellForSel:(SEL)action target:(id)target title:(id)title rightValue:(id)value accessoryType:(NSInteger *)accessory;
@end
@implementation WrongExtendedCellFactory
+ (id)normalCellForSel:(__unused SEL)action target:(__unused id)target title:(__unused id)title rightValue:(__unused id)value accessoryType:(__unused NSInteger *)accessory { abort(); }
@end
@interface NoopSection : ManagerSection
@end
@implementation NoopSection
- (void)insertCell:(__unused id)cell At:(__unused int)index { }
@end
@interface NoopTableInfo : NativeTableInfo
@end
@implementation NoopTableInfo
- (void)addSection:(__unused id)section { }
@end
@interface NoopSettings : NSObject
@property(nonatomic, strong) NativeTableInfo *m_tableViewMgr;
- (void)reloadTableData;
@end
@implementation NoopSettings
- (void)reloadTableData { }
@end

static SRWeChatSettingsEntry *entry(NSString *version, Class controller, Class cell, void (^open)(id)) {
    return [[SRWeChatSettingsEntry alloc] initWithVersion:version classResolver:^Class(NSString *name) {
        if ([name isEqual:@"NewSettingViewController"]) return controller;
        if ([name isEqual:@"MMTableViewCellInfo"]) return cell;
        if ([name isEqual:@"MMTableViewSectionInfo"]) return NativeSection.class;
        return Nil;
    } open:open];
}
static SRWeChatSettingsEntry *managerEntry(Class controller, Class cell, void (^open)(id)) {
    return [[SRWeChatSettingsEntry alloc] initWithVersion:@"8.0.79" classResolver:^Class(NSString *name) {
        if ([name isEqual:@"NewSettingViewController"]) return controller;
        if ([name isEqual:@"WCTableViewNormalCellManager"]) return cell;
        if ([name isEqual:@"WCTableViewSectionManager"]) return ManagerSection.class;
        return Nil;
    } open:open];
}
static void testPreferences(void) {
    NSString *suite = [@"SyncRelay-test-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    SREntryPreferences *preferences = [[SREntryPreferences alloc] initWithDefaults:defaults];
    CHECK(!preferences.floatingEntryEnabled);
    __block NSUInteger changes = 0;
    id observation = [NSNotificationCenter.defaultCenter addObserverForName:SREntryPreferencesChangedNotification object:preferences queue:nil usingBlock:^(__unused NSNotification *notification) { changes++; }];
    preferences.floatingEntryEnabled = YES; CHECK(changes == 1);
    preferences.floatingEntryEnabled = YES; CHECK(changes == 1);
    SREntryPreferences *reopened = [[SREntryPreferences alloc] initWithDefaults:[[NSUserDefaults alloc] initWithSuiteName:suite]];
    CHECK(reopened.floatingEntryEnabled);
    preferences.floatingEntryEnabled = NO; CHECK(changes == 2);
    CHECK(![[[SREntryPreferences alloc] initWithDefaults:[[NSUserDefaults alloc] initWithSuiteName:suite]] floatingEntryEnabled]);
    [defaults setObject:@"invalid" forKey:@"andyz.syncrelay.floatingEntryEnabled"]; CHECK(!preferences.floatingEntryEnabled);
    [NSNotificationCenter.defaultCenter removeObserver:observation]; [defaults removePersistentDomainForName:suite];
}
int main(void) {
    @autoreleasepool {
        testPreferences();
        __block NSUInteger opens = 0; __block __weak id opened;
        void (^open)(id) = ^(id controller) { opens++; opened = controller; };
        SRWeChatSettingsEntry *future = entry(@"8.0.80", FutureSettings.class, NativeCellFactory.class, open);
        CHECK([future install:NULL] && ![future.diagnostics[@"messagingVersionAllowlisted"] boolValue]);
        FutureSettings *futureHost = [[FutureSettings alloc] init]; [futureHost reloadTableData];
        CHECK(futureHost.m_tableViewInfo.sections.count == 2);
        CHECK(![entry(@"8.0.79", WrongSettings.class, NativeCellFactory.class, open) install:NULL]);
        CHECK(![managerEntry(WrongAppearanceSettings.class, ManagerCellFactory.class, open) install:NULL]);
        CHECK(![entry(@"8.0.79", Nil, NativeCellFactory.class, open) install:NULL]);

        SRWeChatSettingsEntry *settings = entry(@"8.0.79", NativeSettings.class, NativeCellFactory.class, open);
        NativeSettings *host = [[NativeSettings alloc] init]; CHECK([settings install:NULL]); CHECK([settings install:NULL]);
        [host reloadTableData]; CHECK(host.originalCalls == 1 && host.m_tableViewInfo.sections.count == 2);
        CHECK(host.m_tableViewInfo.table.reloads == 1 && opens == 0);
        NativeCell *cell = [host.m_tableViewInfo.sections.lastObject cells][0];
        CHECK([cell.title isEqual:@"SyncRelay 转发"] && cell.target); [cell tap]; CHECK(opens == 1 && opened == host);
        [host reloadTableData]; CHECK(host.originalCalls == 2 && host.m_tableViewInfo.sections.count == 2);
        host.rebuild = NO;
        for (int i = 0; i < 20; i++) [host reloadTableData];
        CHECK(host.originalCalls == 22 && host.m_tableViewInfo.sections.count == 2 && host.m_tableViewInfo.table.reloads == 2);
        host.m_tableViewInfo = [[NativeTableInfo alloc] init]; [host reloadTableData]; CHECK(host.m_tableViewInfo.sections.count == 1);
        host.throws = YES; BOOL threw = NO;
        @try { [host reloadTableData]; } @catch (NSException *exception) { threw = [exception.name isEqual:@"HostError"]; }
        CHECK(threw && host.m_tableViewInfo.sections.count == 1); host.throws = NO;
        host.throwsObject = YES; BOOL objectThrew = NO;
        @try { [host reloadTableData]; } @catch (id exception) { objectThrew = [exception isEqual:@"HostObjectError"]; }
        CHECK(objectThrew && host.m_tableViewInfo.sections.count == 1); host.throwsObject = NO;
        CHECK([settings.diagnostics[@"state"] isEqual:@"row_present"] && ![settings.diagnostics.description containsString:@"Private host"]);
        CHECK(![entry(@"8.0.79", NativeSettings.class, NativeCellFactory.class, open) install:NULL]);

        // An inherited override must not replace the superclass's original implementation.
        SRWeChatSettingsEntry *inherited = entry(@"8.0.76", InheritedSettings.class, NativeCellFactory.class, open);
        IMP originalBase = method_getImplementation(class_getInstanceMethod(NativeSettings.class, @selector(reloadTableData)));
        CHECK([inherited install:NULL]);
        CHECK(method_getImplementation(class_getInstanceMethod(NativeSettings.class, @selector(reloadTableData))) == originalBase);
        InheritedSettings *child = [[InheritedSettings alloc] init]; [child reloadTableData];
        CHECK(child.originalCalls == 1 && child.m_tableViewInfo.sections.count == 2);

        // NewSettingViewController's modern manager has no legacy table getter or reload hook.
        SRWeChatSettingsEntry *manager = managerEntry(ManagerSettings.class, ManagerCellFactory.class, open);
        __block NSUInteger updates = 0; __block BOOL nativePresent = NO;
        manager.updated = ^(id controller, BOOL present) { CHECK([controller isKindOfClass:ManagerSettings.class]); updates++; nativePresent = present; };
        CHECK([manager install:NULL]);
        ManagerSettings *modern = [[ManagerSettings alloc] init]; [modern viewDidLoad];
        CHECK(modern.loads == 1 && modern.m_tableViewMgr.sections.count == 1 && nativePresent && updates == 1);
        [modern viewWillAppear:YES]; [modern viewDidAppear:NO];
        CHECK(modern.appearances == 2 && !modern.animated && modern.m_tableViewMgr.sections.count == 1 && updates == 3);
        NativeCell *modernCell = [modern.m_tableViewMgr.sections.lastObject cells][0];
        CHECK([modern.m_tableViewMgr.sections.lastObject cells].count == 2);
        NSUInteger modernBefore = opens; [modernCell tap]; CHECK(opens == modernBefore + 1 && opened == modern);
        CHECK([manager.diagnostics[@"tableSource"] isEqual:@"m_tableViewMgr"]);
        CHECK([manager.diagnostics[@"hooks"] containsObject:@"viewDidAppear:"]);
        [[modern.m_tableViewMgr.sections.lastObject cells] removeObjectAtIndex:0];
        [modern viewDidAppear:YES]; CHECK([modern.m_tableViewMgr.sections.lastObject cells].count == 2);
        CHECK(modern.m_tableViewMgr.table.reloads == 2);
        [[modern.m_tableViewMgr.sections.lastObject cells] removeObjectAtIndex:0]; modern.m_tableViewMgr.table.throws = YES;
        [modern viewDidAppear:NO]; CHECK([manager.diagnostics[@"state"] isEqual:@"row_restore_failed"]);
        modern.m_tableViewMgr.table.throws = NO; [modern viewDidAppear:NO];
        CHECK(nativePresent && [manager.diagnostics[@"state"] isEqual:@"row_present"] && modern.m_tableViewMgr.table.reloads == 4);
        modern.throws = YES; NSUInteger beforeException = updates; BOOL appearanceThrew = NO;
        @try { [modern viewDidAppear:YES]; } @catch (NSException *exception) { appearanceThrew = [exception.name isEqual:@"AppearanceError"]; }
        CHECK(appearanceThrew && updates == beforeException && ![manager.diagnostics.description containsString:@"Private host"]);
        modern.throws = NO;
        // A UIKit recovery callback can run on failure, but cannot recursively append or escape exceptions.
        __weak SRWeChatSettingsEntry *weakManager = manager;
        manager.updated = ^(id controller, BOOL present) { nativePresent = present; CHECK(![weakManager refreshController:controller]); @throw @"RecoveryError"; };
        modern.m_tableViewMgr = nil; [modern viewDidAppear:NO];
        CHECK(!nativePresent && [manager.diagnostics[@"state"] isEqual:@"optional_recovery_entry_exception"]);
        manager.updated = nil;
        modern.m_tableViewMgr = [[NativeTableInfo alloc] init]; CHECK([manager refreshController:modern]);
        CHECK(![manager refreshController:host] && modern.m_tableViewMgr.sections.count == 1);

        // Install after a settings page has already loaded; explicitly refresh the visible instance.
        __block BOOL classLoaded = NO;
        SRWeChatSettingsEntry *late = [[SRWeChatSettingsEntry alloc] initWithVersion:@"unknown" classResolver:^Class(NSString *name) {
            if ([name isEqual:@"NewSettingViewController"]) return classLoaded ? ManagerIvarSettings.class : Nil;
            if ([name isEqual:@"WCTableViewNormalCellManager"]) return ManagerCellFactory.class;
            if ([name isEqual:@"WCTableViewSectionManager"]) return ManagerSection.class;
            return Nil;
        } open:open];
        ManagerIvarSettings *lateHost = [[ManagerIvarSettings alloc] init]; lateHost->m_tableViewMgr = [[NativeTableInfo alloc] init];
        [lateHost reloadTableData]; CHECK(![late install:NULL]);
        classLoaded = YES; CHECK([late install:NULL] && [late refreshController:lateHost]);
        CHECK([lateHost->m_tableViewMgr sections].count == 1);
        for (int i = 0; i < 20; i++) { CHECK([late install:NULL]); [lateHost reloadTableData]; }
        CHECK([lateHost->m_tableViewMgr sections].count == 1 && [late.diagnostics[@"refreshCount"] unsignedIntegerValue] == 21);

        SRWeChatSettingsEntry *ivars = entry(@"8.0.79", IvarSettings.class, NativeCellFactory.class, open);
        CHECK([ivars install:NULL]);
        IvarSettings *ivarHost = [[IvarSettings alloc] init]; IvarTableInfo *tableInfo = [[IvarTableInfo alloc] init]; ivarHost->_m_tableViewInfo = tableInfo;
        [ivarHost reloadTableData]; [ivarHost reloadTableData]; CHECK(tableInfo->m_arrSections.count == 1);
        CHECK(tableInfo.table.reloads == 1);
        @autoreleasepool { IvarSettings *temporary = [[IvarSettings alloc] init]; temporary->_m_tableViewInfo = tableInfo; [temporary reloadTableData]; }
        CHECK(tableInfo->m_arrSections.count == 1); NSUInteger before = opens;
        NativeCell *orphaned = [tableInfo->m_arrSections.lastObject cells][0];
        // The weak controller prevents keeping a dismissed settings screen alive.
        [orphaned tap]; CHECK(opens == before);

        ivarHost->_m_tableViewInfo = @"not a table"; [ivarHost reloadTableData]; CHECK([ivars.diagnostics[@"state"] isEqual:@"section_list_unavailable"]);
        SRWeChatSettingsEntry *badCell = entry(@"8.0.79", FactorySettings.class, WrongCellFactory.class, open); CHECK([badCell install:NULL]);
        FactorySettings *factoryHost = [[FactorySettings alloc] init];
        factoryHost->_m_tableViewInfo = [[NativeTableInfo alloc] init]; [factoryHost reloadTableData];
        CHECK([badCell.diagnostics[@"state"] isEqual:@"cell_factory_unavailable"]);
        CHECK([factoryHost->_m_tableViewInfo sections].count == 0);
        WrongMutationTable *wrongMutation = [[WrongMutationTable alloc] init]; wrongMutation.sections = @[]; wrongMutation.table = [[NativeTable alloc] init];
        factoryHost->_m_tableViewInfo = wrongMutation; [factoryHost reloadTableData];
        CHECK([badCell.diagnostics[@"state"] isEqual:@"incompatible_table_methods"] && wrongMutation.sections.count == 0);
        factoryHost->_m_tableViewInfo = [[PointerSections alloc] init]; [factoryHost reloadTableData];
        CHECK([badCell.diagnostics[@"state"] isEqual:@"section_list_unavailable"]);
        // Reuse the retired hook only after releasing its owner; the wrong integer ABI is never invoked.
        late = nil;
        SRWeChatSettingsEntry *badExtended = managerEntry(ManagerIvarSettings.class, WrongExtendedCellFactory.class, open);
        CHECK([badExtended install:NULL]); lateHost->m_tableViewMgr = [[NativeTableInfo alloc] init];
        [lateHost reloadTableData]; CHECK([badExtended.diagnostics[@"state"] isEqual:@"cell_factory_unavailable"]);
        SRWeChatSettingsEntry *noop = managerEntry(NoopSettings.class, ManagerCellFactory.class, open);
        CHECK([noop install:NULL]); NoopSettings *noopHost = [[NoopSettings alloc] init];
        noopHost.m_tableViewMgr = [[NativeTableInfo alloc] init];
        NoopSection *noopSection = [NoopSection defaultSection]; [noopHost.m_tableViewMgr.sections addObject:noopSection];
        CHECK(![noop refreshController:noopHost] && [noop.diagnostics[@"state"] isEqual:@"insert_not_confirmed"]);
        CHECK(![noop refreshController:noopHost] && [noop.diagnostics[@"state"] isEqual:@"row_restore_failed"] && noopSection.cells.count == 0);
        noopHost.m_tableViewMgr = [[NoopTableInfo alloc] init];
        CHECK(![noop refreshController:noopHost] && [noop.diagnostics[@"state"] isEqual:@"append_not_confirmed"]);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ CHECK(!NSThread.isMainThread && ![settings install:NULL]); dispatch_semaphore_signal(done); });
        CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
        puts("PASS: modern/legacy settings rows, lifecycle/late installation, recovery callbacks, ABI/original-chain guards and opt-in floating entry");
    }
    return 0;
}
