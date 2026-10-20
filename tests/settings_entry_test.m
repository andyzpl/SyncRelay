#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Adapter/SRWeChatSettingsEntry.h"
#import "Core/SREntryPreferences.h"
#include <assert.h>
#define CHECK(...) assert((__VA_ARGS__))

@interface NativeTable : NSObject
@property(nonatomic) NSUInteger reloads;
- (void)reloadData;
@end
@implementation NativeTable
- (void)reloadData { self.reloads++; }
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
- (void)reloadTableData;
@end
@implementation NativeSettings
- (instancetype)init { self = [super init]; if (self) { _m_tableViewInfo = [[NativeTableInfo alloc] init]; _rebuild = YES; } return self; }
- (void)reloadTableData {
    self.originalCalls++;
    if (self.throws) @throw [NSException exceptionWithName:@"HostError" reason:@"Private host content" userInfo:nil];
    if (self.rebuild) [self.m_tableViewInfo.sections setArray:@[[NativeSection sectionInfoDefaut]]];
}
@end
@interface InheritedSettings : NativeSettings
@end
@implementation InheritedSettings
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

static SRWeChatSettingsEntry *entry(NSString *version, Class controller, Class cell, void (^open)(id)) {
    return [[SRWeChatSettingsEntry alloc] initWithVersion:version classResolver:^Class(NSString *name) {
        if ([name isEqual:@"NewSettingViewController"]) return controller;
        if ([name isEqual:@"MMTableViewCellInfo"]) return cell;
        if ([name isEqual:@"MMTableViewSectionInfo"]) return NativeSection.class;
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
        CHECK(![entry(@"8.0.80", NativeSettings.class, NativeCellFactory.class, open) install:NULL]);
        CHECK(![entry(@"8.0.79", WrongSettings.class, NativeCellFactory.class, open) install:NULL]);
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
        CHECK([settings.diagnostics[@"state"] isEqual:@"row_present"] && ![settings.diagnostics.description containsString:@"Private host"]);
        CHECK(![entry(@"8.0.79", NativeSettings.class, NativeCellFactory.class, open) install:NULL]);

        // An inherited override must not replace the superclass's original implementation.
        SRWeChatSettingsEntry *inherited = entry(@"8.0.76", InheritedSettings.class, NativeCellFactory.class, open);
        IMP originalBase = method_getImplementation(class_getInstanceMethod(NativeSettings.class, @selector(reloadTableData)));
        CHECK([inherited install:NULL]);
        CHECK(method_getImplementation(class_getInstanceMethod(NativeSettings.class, @selector(reloadTableData))) == originalBase);
        InheritedSettings *child = [[InheritedSettings alloc] init]; [child reloadTableData];
        CHECK(child.originalCalls == 1 && child.m_tableViewInfo.sections.count == 2);

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
        ivars = nil;
        SRWeChatSettingsEntry *badCell = entry(@"8.0.79", IvarSettings.class, WrongCellFactory.class, open); CHECK([badCell install:NULL]);
        ivarHost->_m_tableViewInfo = [[NativeTableInfo alloc] init]; [ivarHost reloadTableData];
        CHECK([badCell.diagnostics[@"state"] isEqual:@"cell_factory_unavailable"]);
        CHECK([ivarHost->_m_tableViewInfo sections].count == 0);
        WrongMutationTable *wrongMutation = [[WrongMutationTable alloc] init]; wrongMutation.sections = @[]; wrongMutation.table = [[NativeTable alloc] init];
        ivarHost->_m_tableViewInfo = wrongMutation; [ivarHost reloadTableData];
        CHECK([badCell.diagnostics[@"state"] isEqual:@"incompatible_table_methods"] && wrongMutation.sections.count == 0);
        ivarHost->_m_tableViewInfo = [[PointerSections alloc] init]; [ivarHost reloadTableData];
        CHECK([badCell.diagnostics[@"state"] isEqual:@"section_list_unavailable"]);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ CHECK(!NSThread.isMainThread && ![settings install:NULL]); dispatch_semaphore_signal(done); });
        CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
        puts("PASS: native settings entry, original-chain preservation, dedup/ivar guards, weak actions and default-off preferences");
    }
    return 0;
}
