/* UIKit test app: link with the production UI and dependencies (no Tweak entry),
 * plus SRFloatingProgressTests.m. These cases are not macOS Foundation tests. */
#import "UI/SRNavigationController.h"
#import "UI/SRNativeStyle.h"
#import "UI/SRLibraryScreens.h"
#import "UI/SRPlanScreens.h"
#import "UI/SRLocalImagePreviews.h"
#include <assert.h>
#include <stdio.h>
#include <math.h>

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

@interface SRImageStoreFixture : SRMessageStoreFixture
@property(nonatomic, strong) NSData *bytes;
@property(nonatomic) NSUInteger imageReads;
@property(nonatomic, strong) dispatch_semaphore_t gate;
@end
@implementation SRImageStoreFixture
- (NSDictionary *)libraryItem:(__unused NSString *)item account:(__unused NSString *)account error:(__unused NSError **)error {
    return @{@"id": @"fixture-item", @"kind": @"image", @"current_version_id": @"fixture-version",
        @"versions": @[@{@"id": @"fixture-version", @"kind": @"image", @"captured_at": @100, @"media_token": @"fixture-token",
            @"payload": @{@"pixelWidth": @600, @"pixelHeight": @300, @"byteCount": @100}}]};
}
- (NSData *)libraryImageDataForItem:(NSString *)item version:(NSString *)version account:(NSString *)account error:(__unused NSError **)error {
    assert([item isEqual:@"fixture-item"] && [version isEqual:@"fixture-version"] && [account isEqual:@"fixture-account"]);
    @synchronized (self) { self.imageReads++; }
    if (self.gate) dispatch_semaphore_wait(self.gate, DISPATCH_TIME_FOREVER);
    return self.bytes;
}
@end
static void SRPumpPreviews(void) {
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static void SRRunLocalImagePreviewTests(UIWindow *window) {
    for (NSValue *value in @[[NSValue valueWithCGSize:CGSizeMake(600, 300)], [NSValue valueWithCGSize:CGSizeMake(300, 600)],
                            [NSValue valueWithCGSize:CGSizeMake(12, 8)]]) {
        CGSize size = value.CGSizeValue;
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat]; format.scale = 1;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
        SRImageStoreFixture *store = [[SRImageStoreFixture alloc] init];
        store.bytes = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
            [UIColor.systemBlueColor setFill]; [context fillRect:CGRectMake(0, 0, size.width, size.height)];
        }];
        __block BOOL allowed = YES;
        UITableViewController *page = (id)SRCreateLibraryItem((id)store, @"fixture-account", ^{ return allowed; }, @"fixture-item", nil, nil);
        window.rootViewController = [[SRNavigationController alloc] initWithRootViewController:page];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
        UIImageView *image = nil;
        do { [page.tableView layoutIfNeeded]; image = (id)SRFindMessageElement(page.view, @"SyncRelay.LibraryImagePreview");
            if (!image) SRPumpPreviews();
        } while (!image && deadline.timeIntervalSinceNow > 0);
        assert(image && image.image && store.imageReads >= 1);
        [page.tableView layoutIfNeeded];
        assert(image.contentMode == UIViewContentModeScaleAspectFit);
        assert(CGRectGetHeight(image.frame) <= 240.5);
        assert(CGRectGetWidth(image.frame) <= CGRectGetWidth(image.superview.bounds) * 0.7 + 0.5);
        assert(fabs(CGRectGetWidth(image.frame) / CGRectGetHeight(image.frame) - size.width / size.height) < 0.02);
        assert(CGRectGetWidth(image.frame) <= size.width / UIScreen.mainScreen.scale + 0.5);
        allowed = NO;
        [page.refreshControl sendActionsForControlEvents:UIControlEventValueChanged]; [page.tableView layoutIfNeeded];
        assert(!SRFindMessageElement(page.view, @"SyncRelay.LibraryImagePreview"));
    }
    // Reject a late image after foreground/account invalidation.
    SRImageStoreFixture *slow = [[SRImageStoreFixture alloc] init]; slow.gate = dispatch_semaphore_create(0);
    UITableViewController *page = (id)SRCreateLibraryItem((id)slow, @"fixture-account", ^{ return YES; }, @"fixture-item", nil, nil);
    window.rootViewController = [[SRNavigationController alloc] initWithRootViewController:page]; [page.tableView layoutIfNeeded];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    BOOL reading = NO;
    do { @synchronized (slow) { reading = slow.imageReads > 0; } if (!reading) SRPumpPreviews(); }
    while (!reading && deadline.timeIntervalSinceNow > 0);
    assert(reading);
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
    dispatch_semaphore_signal(slow.gate);
    for (NSUInteger i = 0; i < 10; i++) SRPumpPreviews();
    [page.tableView layoutIfNeeded];
    assert(!SRFindMessageElement(page.view, @"SyncRelay.LibraryImagePreview"));
    puts("PASS: bounded local image preview preserves aspect ratio, does not upscale and rejects inactive/foreign-account results");
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
    do {
        [navigation.view.window layoutIfNeeded];
        [navigation.view layoutIfNeeded];
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    } while (navigation.transitionCoordinator && deadline.timeIntervalSinceNow > 0);
    assert(navigation.transitionCoordinator == nil);
}

@interface SRForwardingRecordsFixture : NSObject
@property(nonatomic) NSUInteger reads;
@property(nonatomic, strong) NSData *imageBytes;
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
    return @{@"id": run, @"sourceKind": @"message_library", @"messageType": self.imageBytes ? @"image" : @"text", @"excerpt": @"会议通知",
        @"state": @"completed", @"started_at": @100, @"ended_at": @150,
        @"counts": @{@"confirmed": @1, @"uncertain": @1}};
}
- (NSData *)forwardingImageDataForRun:(NSString *)run account:(NSString *)account error:(__unused NSError **)error {
    assert([run isEqual:@"record-1"] && [account isEqual:@"fixture-account"]);
    return self.imageBytes;
}
- (NSArray *)forwardingTargetGroupsForRun:(NSString *)run account:(NSString *)account error:(__unused NSError **)error {
    assert([run isEqual:@"record-1"] && [account isEqual:@"fixture-account"]);
    self.reads++;
    return @[@{@"name": @"本次转发目标", @"count": @2, @"legacy": @YES}];
}
- (NSArray *)forwardingTargetsForRun:(NSString *)run account:(NSString *)account group:(NSUInteger)group limit:(NSUInteger)limit
                             offset:(NSUInteger)offset error:(__unused NSError **)error {
    assert([run isEqual:@"record-1"] && [account isEqual:@"fixture-account"] && group == 0 && limit == 30 && offset == 0);
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
    NSIndexPath *summary = [NSIndexPath indexPathForRow:0 inSection:1];
    UITableViewCell *result = [list.tableView.dataSource tableView:list.tableView cellForRowAtIndexPath:summary];
    assert([list.title isEqual:@"转发记录"] && list.tableView.style == UITableViewStyleInsetGrouped);
    printf("forwarding labels: record=%s result=%s\n", record.textLabel.text.UTF8String ?: "<nil>", result.textLabel.text.UTF8String ?: "<nil>");
    assert([record.textLabel.text isEqual:@"会议通知"]);
    assert([result.textLabel.text containsString:@"2"]);
    [list.tableView.delegate tableView:list.tableView didSelectRowAtIndexPath:first];
    SRSettleNavigation(navigation);
    UITableViewController *detail = (id)navigation.topViewController;
    assert([detail.title isEqual:@"转发详情"] && detail.tableView.numberOfSections == 3);
    NSIndexPath *group = [NSIndexPath indexPathForRow:0 inSection:2];
    UITableViewCell *groupCell = [detail.tableView.dataSource tableView:detail.tableView cellForRowAtIndexPath:group];
    assert([groupCell.textLabel.text isEqual:@"本次转发目标"] && groupCell.accessoryType == UITableViewCellAccessoryDisclosureIndicator);
    assert([[detail.tableView.dataSource tableView:detail.tableView titleForFooterInSection:2] containsString:@"旧记录"]);
    [detail.tableView.delegate tableView:detail.tableView didSelectRowAtIndexPath:group];
    SRSettleNavigation(navigation);
    detail = (id)navigation.topViewController;
    assert([detail.title isEqual:@"本次转发目标"] && detail.tableView.numberOfSections == 1);
    NSIndexPath *unknown = [NSIndexPath indexPathForRow:1 inSection:0];
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

@interface SRDelayedForwardingFixture : SRForwardingRecordsFixture
@property(nonatomic, strong) dispatch_semaphore_t gate;
@property(nonatomic) NSUInteger imageReads;
@property(nonatomic) BOOL snapshotInvalid;
@end
@implementation SRDelayedForwardingFixture
- (NSData *)forwardingImageDataForRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    @synchronized (self) { self.imageReads++; }
    dispatch_semaphore_wait(self.gate, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return [super forwardingImageDataForRun:run account:account error:error];
}
- (NSArray *)forwardingTargetGroupsForRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    if (self.snapshotInvalid) return nil;
    return [super forwardingTargetGroupsForRun:run account:account error:error];
}
- (NSArray *)historyForRule:(NSString *)rule account:(NSString *)account limit:(NSUInteger)limit
                    offset:(NSUInteger)offset error:(__unused NSError **)error {
    assert([rule isEqual:@"fixture-rule"] && [account isEqual:@"fixture-account"] && limit == 50 && offset == 0);
    return @[@{@"id": @"record-1", @"state": @"completed", @"started_at": @100,
        @"counts": @{@"confirmed": @1, @"uncertain": @1}}];
}
@end

static void SRRunLegacyHistoryRouteTests(UIWindow *window) {
    SRDelayedForwardingFixture *store = [[SRDelayedForwardingFixture alloc] init];
    UITableViewController *history = [(UITableViewController *)[NSClassFromString(@"SRRecordScreen") alloc] initWithStyle:UITableViewStyleGrouped];
    [history setValue:@3 forKey:@"kind"]; [history setValue:store forKey:@"store"];
    [history setValue:@"fixture-account" forKey:@"account"]; [history setValue:@"fixture-rule" forKey:@"identifier"];
    [history setValue:[^{ return YES; } copy] forKey:@"verifyAccount"];
    SRNavigationController *navigation = [[SRNavigationController alloc] initWithRootViewController:history];
    window.rootViewController = navigation; [history.view layoutIfNeeded];
    [history.tableView.delegate tableView:history.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    SRSettleNavigation(navigation);
    UITableViewController *detail = (id)navigation.topViewController;
    assert([detail.title isEqual:@"转发详情"] && detail.tableView.numberOfSections == 3);
    assert([[detail valueForKey:@"run"] isEqual:@"record-1"] && [[detail valueForKey:@"account"] isEqual:@"fixture-account"]);
    [detail.tableView.delegate tableView:detail.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2]];
    SRSettleNavigation(navigation);
    UITableViewController *targets = (id)navigation.topViewController;
    assert([targets.tableView numberOfRowsInSection:0] == 2);
    UITableViewCell *confirmed = [targets.tableView.dataSource tableView:targets.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    assert([confirmed.detailTextLabel.text isEqual:@"已确认送达"]);
    puts("PASS: legacy rule history opens exact account/run grouped history including confirmed targets");
}

static void SRRunLateForwardingPreviewTests(UIWindow *window) {
    for (NSString *change in @[@"run", @"account", @"snapshot", @"rejected-account"]) {
        SRDelayedForwardingFixture *store = [[SRDelayedForwardingFixture alloc] init];
        store.gate = dispatch_semaphore_create(0);
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(10, 10)];
        store.imageBytes = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
            [UIColor.systemBlueColor setFill]; [context fillRect:CGRectMake(0, 0, 10, 10)];
        }];
        __block BOOL allowed = YES;
        UITableViewController *page = (id)SRCreateForwardingRecord((id)store, @"fixture-account", ^{ return allowed; }, @"record-1");
        window.rootViewController = [[SRNavigationController alloc] initWithRootViewController:page];
        [page.view layoutIfNeeded];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3]; BOOL reading = NO;
        do { @synchronized (store) { reading = store.imageReads > 0; } if (!reading) SRPumpPreviews(); }
        while (!reading && deadline.timeIntervalSinceNow > 0);
        assert(reading);
        if ([change isEqual:@"run"]) [page setValue:@"record-2" forKey:@"run"];
        else if ([change isEqual:@"account"]) [page setValue:@"other-account" forKey:@"account"];
        else if ([change isEqual:@"snapshot"]) store.snapshotInvalid = YES;
        else allowed = NO;
        dispatch_semaphore_signal(store.gate);
        SRLocalImagePreviews *loader = [page valueForKey:@"thumbnails"];
        NSOperationQueue *queue = [loader valueForKey:@"queue"]; [queue waitUntilAllOperationsAreFinished];
        for (NSUInteger i = 0; i < 10; i++) SRPumpPreviews();
        if ([change isEqual:@"snapshot"] || [change isEqual:@"rejected-account"]) {
            assert([page valueForKey:@"record"] == nil && [[page valueForKey:@"rows"] count] == 0);
            assert(!SRFindMessageElement(page.view, @"SyncRelay.ForwardingImageThumbnail"));
        } else {
            assert([[page valueForKey:@"problem"] length] == 0);
            UITableViewCell *cell = [page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
            UIListContentConfiguration *content = (id)cell.contentConfiguration;
            assert(!content.image || content.image.isSymbolImage);
        }
    }
    puts("PASS: late forwarding images reject changed run/account, failed account verification and invalid snapshots");
}

static void SRRunForwardingThumbnailTests(UIWindow *window) {
    SRForwardingRecordsFixture *store = [[SRForwardingRecordsFixture alloc] init];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(300, 200)];
    store.imageBytes = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.systemGreenColor setFill]; [context fillRect:CGRectMake(0, 0, 300, 200)];
    }];
    UITableViewController *list = (id)SRCreateForwardingRecords((id)store, @"fixture-account", ^{ return YES; });
    SRNavigationController *navigation = [[SRNavigationController alloc] initWithRootViewController:list]; window.rootViewController = navigation;
    [list.view layoutIfNeeded];
    [list.tableView.delegate tableView:list.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    SRSettleNavigation(navigation);
    UITableViewController *detail = (id)navigation.topViewController;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    UIListContentConfiguration *content = nil;
    do {
        [detail.tableView layoutIfNeeded];
        UITableViewCell *cell = [detail.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        content = [cell.contentConfiguration isKindOfClass:UIListContentConfiguration.class] ? (id)cell.contentConfiguration : nil;
        if (!content.image || content.image.isSymbolImage) SRPumpPreviews();
    } while ((!content.image || content.image.isSymbolImage) && deadline.timeIntervalSinceNow > 0);
    assert(content.image && !content.image.isSymbolImage);
    assert(CGSizeEqualToSize(content.imageProperties.maximumSize, CGSizeMake(48, 48)));
    assert(CGSizeEqualToSize(content.imageProperties.reservedLayoutSize, CGSizeMake(48, 48)) && content.imageProperties.cornerRadius == 6);
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil]; [detail.tableView layoutIfNeeded];
    assert(!SRFindMessageElement(detail.view, @"SyncRelay.ForwardingImageThumbnail"));
    puts("PASS: frozen forwarding detail uses a 48pt rounded local thumbnail and masks on resign");
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
    SRSettleNavigation(navigation);
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
    SRSettleNavigation(navigation);
    assert(opens == 1 && navigation.topViewController != picker && !picked);

    store.rules = @[@{@"name": @"第一组", @"targets": @[@{@"id": @"a@chatroom"}]},
                    @{@"name": @"第二组", @"targets": @[@{@"id": @"b@chatroom"}]}];
    NSUInteger readsBeforeReturn = store.reads;
    UIViewController *groupsPage = navigation.topViewController;
    assert([navigation popViewControllerAnimated:NO] == groupsPage);
    SRSettleNavigation(navigation);
    NSDate *returnDeadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (store.reads == readsBeforeReturn && returnDeadline.timeIntervalSinceNow > 0) {
        [window layoutIfNeeded];
        SRPumpPreviews();
    }
    assert(store.reads > readsBeforeReturn && picker.viewIfLoaded.window == window);
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
    assert(homeTable.numberOfSections == 1 && [homeTable numberOfRowsInSection:0] == 5);
    NSIndexPath *records = [NSIndexPath indexPathForRow:3 inSection:0];
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
    SRRunLocalImagePreviewTests(window);
    SRRunLibraryGroupPickerTests(window);
    SRRunForwardingRecordsTests(window);
    SRRunForwardingThumbnailTests(window);
    SRRunLegacyHistoryRouteTests(window);
    SRRunLateForwardingPreviewTests(window);
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
