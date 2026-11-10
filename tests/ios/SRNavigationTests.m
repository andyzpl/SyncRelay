/* UIKit test app: link with the production UI and dependencies (no Tweak entry),
 * plus SRFloatingProgressTests.m. These cases are not macOS Foundation tests. */
#import "UI/SRNavigationController.h"
#import "UI/SRNativeStyle.h"
#import "UI/SRLibraryScreens.h"
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
        @"fixture-item", (id)[[NSObject alloc] init]);
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

void SRRunNavigationTests(UIWindow *window) {
    SRRunFooterLayoutTests(window);
    SRRunMessageDetailTests(window);
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
