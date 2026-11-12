/* UIKit test app: link with the production UI and dependencies (no Tweak entry),
 * plus SRFloatingProgressTests.m. These cases are not macOS Foundation tests. */
#import "UI/SRNavigationController.h"
#import "UI/SRNativeStyle.h"
#import "UI/SRLibraryScreens.h"
#import "UI/SRPlanScreens.h"
#include <assert.h>
#include <stdio.h>

@interface SRNavigationDraftFixture : UIViewController <SRNavigationBackGuard>
@property(nonatomic) BOOL dirty;
@property(nonatomic) NSUInteger closeRequests;
@end
@implementation SRNavigationDraftFixture
- (BOOL)sr_hasUnsavedChanges { return self.dirty; }
- (void)sr_requestClose {
    self.closeRequests++;
    if (!self.dirty) SRPopPluginPage(self, NO);
}
@end

/* Stored fixtures only: any accidental task creation/start would be an
 * unrecognized selector, rather than performing real work. */
@interface SRMessageStoreFixture : NSObject
@property(nonatomic) NSUInteger reads;
@end
@implementation SRMessageStoreFixture
- (NSDictionary *)libraryItem:(__unused NSString *)item account:(__unused NSString *)account error:(__unused NSError **)error {
    self.reads++;
    return @{@"id": @"fixture-item", @"kind": @"text", @"current_version_id": @"fixture-version",
        @"versions": @[@{@"id": @"fixture-version", @"kind": @"text", @"captured_at": @100,
            @"payload": @{@"text": @"周五会议提前到下午三点，新的安排我整理后发群里。"}}]};
}
- (NSArray *)libraryTasksForItem:(__unused NSString *)item account:(__unused NSString *)account
                          limit:(__unused NSUInteger)limit error:(__unused NSError **)error { return @[]; }
@end

static UIView *SRFindMessageElement(UIView *view, NSString *identifier) {
    if ([view.accessibilityIdentifier isEqual:identifier]) return view;
    for (UIView *child in view.subviews) {
        UIView *match = SRFindMessageElement(child, identifier);
        if (match) return match;
    }
    return nil;
}

static void SRRunMessageDetailTests(UIWindow *window) {
    SRMessageStoreFixture *store = [[SRMessageStoreFixture alloc] init];
    __block BOOL allowed = YES;
    UIViewController *detail = SRCreateLibraryItem((id)store, @"fixture-account", ^{ return allowed; },
        @"fixture-item", (id)[[NSObject alloc] init], nil);
    window.rootViewController = [[SRNavigationController alloc] initWithRootViewController:detail];
    [detail.view layoutIfNeeded];
    UITableView *table = [detail valueForKey:@"tableView"];
    [table.refreshControl sendActionsForControlEvents:UIControlEventValueChanged]; [table layoutIfNeeded];
    assert([detail.title isEqual:@"消息详情"]);
    assert(table.numberOfSections == 2 && [table numberOfRowsInSection:0] == 1);
    assert([table numberOfRowsInSection:1] == 3);
    UILabel *body = (id)SRFindMessageElement(detail.view, @"SyncRelay.LibraryMessageBody");
    assert([body.text containsString:@"周五会议"]);
    UIButton *button = (id)SRFindMessageElement(detail.view, @"SyncRelay.LibraryChooseGroups");
    assert(button && !button.hidden && button.enabled);
    assert(CGRectGetMaxY(table.frame) <= CGRectGetMinY(button.frame));
    assert(CGRectGetMaxY(button.frame) <= CGRectGetMaxY(detail.view.bounds));
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
    [table layoutIfNeeded];
    assert(button.hidden && !button.enabled);
    assert(!SRFindMessageElement(detail.view, @"SyncRelay.LibraryMessageBody"));
    NSUInteger reads = store.reads; allowed = NO;
    [table.refreshControl sendActionsForControlEvents:UIControlEventValueChanged]; [table layoutIfNeeded];
    assert(store.reads == reads && button.hidden && table.numberOfSections == 1);
    puts("PASS: content-first detail, fixed CTA, inactive masking and account rejection without dispatch");
}

@interface SRFooterLayoutFixture : UITableViewController
@end
@implementation SRFooterLayoutFixture
- (void)viewDidLoad { [super viewDidLoad]; SRStyleSettingsTable(self); }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section { return 4; }
- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(__unused NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    SRStyleSettingsCell(cell); cell.textLabel.text = @"目标分组";
    return cell;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"母群自动排除。分组规格和实际发送上限分别管理；先预览，再保存分组。";
}
@end

static void SRRunFooterLayoutTests(UIWindow *window) {
    for (NSUInteger pass = 0; pass < 2; pass++) {
        SRFooterLayoutFixture *page = [[SRFooterLayoutFixture alloc] initWithStyle:UITableViewStyleInsetGrouped];
        window.rootViewController = page;
        UITableView *table = page.tableView;
        table.frame = CGRectMake(0, 0, pass ? 430 : 320, 844);
        [table reloadData]; [table layoutIfNeeded];
        UITableViewHeaderFooterView *footer = [table footerViewForSection:0];
        assert(footer != nil && footer.textLabel.text.length > 0);
        [footer layoutIfNeeded];
        CGRect row = [table rectForRowAtIndexPath:[NSIndexPath indexPathForRow:3 inSection:0]];
        CGRect text = [footer.textLabel convertRect:footer.textLabel.bounds toView:table];
        CGRect footerRect = [table rectForFooterInSection:0];
        assert(CGRectGetMinY(text) >= CGRectGetMaxY(row));
        assert(CGRectGetMaxY(text) <= CGRectGetMaxY(footerRect) + 0.5);
        CGSize needed = [footer.textLabel sizeThatFits:CGSizeMake(CGRectGetWidth(text), CGFLOAT_MAX)];
        assert(needed.height <= CGRectGetHeight(text) + 0.5);
    }
    puts("PASS: multiline grouped footer stays below the last row at narrow and wide widths");
}

static void SRSettleNavigation(SRNavigationController *navigation) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (navigation.transitionCoordinator && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(navigation.transitionCoordinator == nil);
}

@interface SRForwardingRecordsFixture : NSObject
@property(nonatomic) NSUInteger reads;
@end
@implementation SRForwardingRecordsFixture
- (NSArray *)forwardingRecordsForAccount:(NSString *)account beforeRun:(NSString *)beforeRun
                                  limit:(NSUInteger)limit error:(__unused NSError **)error {
    assert([account isEqual:@"fixture-account"] && !beforeRun && limit == 30);
    self.reads++;
    return @[[self forwardingRecordForRun:@"record-1" account:account error:NULL]];
}
- (NSDictionary *)forwardingRecordForRun:(NSString *)run account:(NSString *)account error:(__unused NSError **)error {
    assert([run isEqual:@"record-1"] && [account isEqual:@"fixture-account"]);
    self.reads++;
    return @{@"id": run, @"sourceKind": @"message_library", @"excerpt": @"会议通知",
        @"state": @"completed", @"started_at": @100, @"ended_at": @150,
        @"counts": @{@"confirmed": @1, @"uncertain": @1}};
}
- (NSArray *)forwardingTargetsForRun:(NSString *)run account:(NSString *)account limit:(NSUInteger)limit
                             offset:(NSUInteger)offset error:(__unused NSError **)error {
    assert([run isEqual:@"record-1"] && [account isEqual:@"fixture-account"] && limit == 30 && offset == 0);
    self.reads++;
    return @[@{@"target": @"one@chatroom", @"state": @"confirmed"}, @{@"target": @"two@chatroom", @"state": @"uncertain"}];
}
@end

static void SRRunForwardingRecordsTests(UIWindow *window) {
    SRForwardingRecordsFixture *store = [[SRForwardingRecordsFixture alloc] init];
    __block BOOL allowed = YES;
    UITableViewController *list = (id)SRCreateForwardingRecords((id)store, @"fixture-account", ^{ return allowed; });
    SRNavigationController *navigation = [[SRNavigationController alloc] initWithRootViewController:list];
    window.rootViewController = navigation;
    [list.view layoutIfNeeded];
    NSIndexPath *first = [NSIndexPath indexPathForRow:0 inSection:0];
    UITableViewCell *record = [list.tableView.dataSource tableView:list.tableView cellForRowAtIndexPath:first];
    assert([list.title isEqual:@"转发记录"] && list.tableView.style == UITableViewStyleInsetGrouped);
    assert([record.textLabel.text isEqual:@"会议通知"] && [record.detailTextLabel.text containsString:@"2 个群"]);
    [list.tableView.delegate tableView:list.tableView didSelectRowAtIndexPath:first];
    SRSettleNavigation(navigation);
    UITableViewController *detail = (id)navigation.topViewController;
    assert([detail.title isEqual:@"转发详情"] && detail.tableView.numberOfSections == 3);
    NSIndexPath *unknown = [NSIndexPath indexPathForRow:1 inSection:2];
    UITableViewCell *target = [detail.tableView.dataSource tableView:detail.tableView cellForRowAtIndexPath:unknown];
    assert([target.detailTextLabel.text isEqual:@"待核对"] && !detail.navigationItem.rightBarButtonItem);
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
    assert(detail.tableView.numberOfSections == 1);
    allowed = NO;
    NSUInteger reads = store.reads;
    [detail.refreshControl sendActionsForControlEvents:UIControlEventValueChanged];
    assert(store.reads == reads && detail.tableView.numberOfSections == 1);
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    assert(store.reads == reads && detail.tableView.numberOfSections == 1);
    UITableViewCell *blocked = [detail.tableView.dataSource tableView:detail.tableView cellForRowAtIndexPath:first];
    assert([blocked.textLabel.text containsString:@"账号无法核对"]);
    puts("PASS: forwarding records use the native list, show one bound run and mask on account rejection");
}

@interface SRGroupPickerStoreFixture : NSObject
@property(nonatomic, copy) NSArray *rules;
@property(nonatomic) NSUInteger reads;
@end
@implementation SRGroupPickerStoreFixture
- (NSDictionary *)configurationForAccount:(NSString *)account error:(__unused NSError **)error {
    assert([account isEqualToString:@"fixture-account"]);
    self.reads++;
    return self.rules ? @{@"rules": self.rules} : nil;
}
- (NSUInteger)forwardingTargetLimit { return 10; }
@end

static void SRRunLibraryGroupPickerTests(UIWindow *window) {
    // The store implements only saved groups, not history or sending.
    SRGroupPickerStoreFixture *store = [[SRGroupPickerStoreFixture alloc] init];
    store.rules = @[];
    UIViewController *detail = [[UIViewController alloc] init];
    SRNavigationController *navigation = [[SRNavigationController alloc] initWithRootViewController:detail];
    window.rootViewController = navigation;
    __block BOOL allowed = YES;
    __block NSUInteger opens = 0;
    __block NSArray *picked = nil;
    UITableViewController *picker = (id)SRCreateTargetPicker((id)store, @"fixture-account", ^{ return allowed; },
        ^(UIViewController *source) {
            opens++;
            [source.navigationController pushViewController:[[UIViewController alloc] init] animated:NO];
        }, ^(NSArray<NSString *> *targets) { picked = targets; });
    [navigation pushViewController:picker animated:NO];
    SRSettleNavigation(navigation);
    UITableView *table = picker.tableView;
    id<UITableViewDataSource> data = table.dataSource;
    id<UITableViewDelegate> delegate = table.delegate;
    NSIndexPath *first = [NSIndexPath indexPathForRow:0 inSection:0];
    NSIndexPath *second = [NSIndexPath indexPathForRow:1 inSection:0];
    UIBarButtonItem *done = picker.navigationItem.rightBarButtonItem;
    assert(table.numberOfSections == 1 && [table numberOfRowsInSection:0] == 2 && !done.enabled);
    assert([[data tableView:table cellForRowAtIndexPath:first].textLabel.text isEqual:@"还没有可用的目标分组"]);
    assert([[data tableView:table cellForRowAtIndexPath:second].textLabel.text isEqual:@"去群分组"]);
    [delegate tableView:table didSelectRowAtIndexPath:second];
    assert(opens == 1 && navigation.topViewController != picker && !picked);

    store.rules = @[@{@"name": @"第一组", @"targets": @[@{@"id": @"a@chatroom"}]},
                    @{@"name": @"第二组", @"targets": @[@{@"id": @"b@chatroom"}]}];
    [navigation popViewControllerAnimated:NO];
    SRSettleNavigation(navigation);
    assert(navigation.topViewController == picker && !picked && !done.enabled);
    assert(table.numberOfSections == 1 && [table numberOfRowsInSection:0] == 2);
    assert([[data tableView:table cellForRowAtIndexPath:first].textLabel.text isEqual:@"第一组"]);

    allowed = NO;
    NSUInteger reads = store.reads;
    [delegate tableView:table didSelectRowAtIndexPath:first];
    assert(store.reads == reads && !done.enabled && [table numberOfRowsInSection:0] == 1);
    allowed = YES;
    store.rules = nil;
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    assert([[data tableView:table cellForRowAtIndexPath:first].textLabel.text containsString:@"无法读取"]);
    assert([table numberOfRowsInSection:0] == 1 && !done.enabled);

    store.rules = @[@{@"name": @"新分组", @"targets": @[@{@"id": @"new@chatroom"}]}];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    [delegate tableView:table didSelectRowAtIndexPath:first];
    assert(done.enabled);
    BOOL handled = [UIApplication.sharedApplication sendAction:done.action to:done.target from:done forEvent:nil];
    assert(handled);
    SRSettleNavigation(navigation);
    assert(navigation.topViewController == detail && [picked isEqualToArray:@[@"new@chatroom"]]);
    puts("PASS: saved groups only, empty-state routing, reload, account rejection and target delivery");
}

static UIBarButtonItem *SRAssertHomeClose(SRNavigationController *navigation, UIViewController *home) {
    assert(navigation.topViewController == home && navigation.viewControllers.count == 1);
    UINavigationItem *item = navigation.navigationBar.topItem;
    assert(item == home.navigationItem && item.hidesBackButton && !item.leftItemsSupplementBackButton);
    UIBarButtonItem *close = item.leftBarButtonItem;
    assert(item.leftBarButtonItems.count == 1 && [close.title isEqualToString:@"关闭"]);
    assert(close.target == home && close.action != NULL);
    return close;
}

static void SRRunHomeCloseTests(UIWindow *window) {
    UIViewController *host = [[UIViewController alloc] init];
    window.rootViewController = host;
    // Reject account verification so the real home never reads the store.
    UIViewController *home = SRCreateNavigationHome((id)[[NSObject alloc] init], @"fixture-account", ^BOOL { return NO; },
        ^(__unused NSUInteger destination) {});
    SRNavigationController *navigation = [[SRNavigationController alloc] initWithRootViewController:home];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [host presentViewController:navigation animated:NO completion:nil];
    SRSettleNavigation(navigation);
    assert(host.presentedViewController == navigation);
    SRAssertHomeClose(navigation, home);
    UITableView *homeTable = ((UITableViewController *)home).tableView;
    assert(homeTable.numberOfSections == 2 && [homeTable numberOfRowsInSection:0] == 4);
    NSIndexPath *records = [NSIndexPath indexPathForRow:0 inSection:1];
    UITableViewCell *entry = [homeTable.dataSource tableView:homeTable cellForRowAtIndexPath:records];
    assert([entry.accessibilityIdentifier isEqual:@"SyncRelay.HomeForwardingRecords"]);

    for (NSUInteger pass = 0; pass < 3; pass++) {
        UIViewController *secondary = [[UIViewController alloc] init];
        UIViewController *tertiary = [[UIViewController alloc] init];
        [navigation pushViewController:secondary animated:YES];
        SRSettleNavigation(navigation);
        [navigation pushViewController:tertiary animated:YES];
        SRSettleNavigation(navigation);
        assert([tertiary.navigationItem.leftBarButtonItem.accessibilityLabel isEqualToString:@"返回"]);
        [navigation requestBack];
        SRSettleNavigation(navigation);
        assert(navigation.topViewController == secondary);
        assert([secondary.navigationItem.leftBarButtonItem.accessibilityLabel isEqualToString:@"返回"]);
        if (pass == 1) {
            // Reproduce a stale Back item on the covered home; returning must repair it.
            home.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回"
                style:UIBarButtonItemStylePlain target:nil action:NULL];
        }
        [navigation requestBack];
        SRSettleNavigation(navigation);
        SRAssertHomeClose(navigation, home);
    }

    UIBarButtonItem *close = SRAssertHomeClose(navigation, home);
    BOOL handled = [UIApplication.sharedApplication sendAction:close.action to:close.target from:close forEvent:nil];
    assert(handled);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (host.presentedViewController && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(host.presentedViewController == nil && navigation.presentingViewController == nil);
    puts("PASS: repeated nested returns restore the real home Close item and dismiss the plugin");
}

void SRRunNavigationTests(UIWindow *window) {
    SRRunFooterLayoutTests(window);
    SRRunMessageDetailTests(window);
    SRRunLibraryGroupPickerTests(window);
    SRRunForwardingRecordsTests(window);
    SRRunHomeCloseTests(window);
    UIViewController *home = [[UIViewController alloc] init];
    SRNavigationController *navigation = [[SRNavigationController alloc] initWithRootViewController:home];
    window.rootViewController = navigation; [navigation view];
    assert(!SRPopPluginPage(home, NO));
    assert(![navigation gestureRecognizerShouldBegin:navigation.interactivePopGestureRecognizer]);
    for (NSUInteger destination = 0; destination < 4; destination++) {
        SRNavigationDraftFixture *page = [[SRNavigationDraftFixture alloc] init];
        [navigation pushViewController:page animated:NO];
        assert(page.navigationItem.leftBarButtonItem != nil);
        assert([navigation gestureRecognizerShouldBegin:navigation.interactivePopGestureRecognizer]);
        [navigation requestBack];
        SRSettleNavigation(navigation);
        assert(navigation.topViewController == home && navigation.viewControllers.count == 1);
    }
    SRNavigationDraftFixture *settings = [[SRNavigationDraftFixture alloc] init];
    [navigation pushViewController:settings animated:NO];
    UIViewController *detail = [[UIViewController alloc] init];
    [navigation pushViewController:detail animated:NO];
    assert(!SRPopPluginPage(settings, NO)); /* A stale callback cannot pop a newer page. */
    [navigation requestBack];
    SRSettleNavigation(navigation);
    assert(navigation.topViewController == settings && navigation.viewControllers.count == 2);
    settings.dirty = YES;
    [navigation requestBack];
    assert(settings.closeRequests == 1 && navigation.topViewController == settings);
    assert(![navigation gestureRecognizerShouldBegin:navigation.interactivePopGestureRecognizer]);
    assert(settings.closeRequests == 2 && navigation.topViewController == settings);
    /* Cancel leaves the stack intact; explicit discard uses the same bound page. */
    assert(navigation.viewControllers.count == 2);
    settings.dirty = NO; assert(SRPopPluginPage(settings, NO));
    assert(navigation.topViewController == home);
    [navigation requestBack]; assert(navigation.topViewController == home);
    puts("PASS: four destinations, nested return, dirty back/swipe guard, stale page and root preservation");
}
