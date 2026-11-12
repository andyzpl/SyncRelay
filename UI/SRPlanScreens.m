#import "SRPlanScreens.h"
#import "SRLibraryScreens.h"
#import "SRNativeStyle.h"
#import "Core/SRStore.h"
#import "Core/SRSourceCapture.h"
#import "Core/SRImageAssetStore.h"
#import "Core/SRRunProjection.h"
#import "Core/SREntryPreferences.h"
#import "Adapter/SRSmallGroupSession.h"
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>

NSString *const SRRelayStateChangedNotification = @"andyz.syncrelay.stateChanged";
typedef NS_ENUM(NSUInteger, SRRecordKind) { SRRecordPreview, SRRecordPlans, SRRecordPlan, SRRecordHistory, SRRecordExceptions };

/* Formatting lives in Core/SRRunProjection so the group list, the run detail
 * and the older record screens cannot drift into different date rules. */
static NSString *SRDate(id value) { return [SRRunProjection localDateTimeText:value]; }
/* Rows 5/6 are the two plugin-measured times; row 7 is the host's raw number.
 * They keep their distinct meaning: only the first two become a wall clock. */
static NSString *SRSourceTimeText(NSDictionary *source, NSInteger row) {
    NSDictionary *time = [source[@"sourceTime"] isKindOfClass:NSDictionary.class] ? source[@"sourceTime"] : nil;
    NSDictionary *envelope = time ? @{@"sourceTime": time} : @{};
    if (row == 7) return [SRRunProjection hostTimeTextForEnvelope:envelope];
    if (row == 6) return [SRRunProjection frozenTimeTextForEnvelope:envelope];
    return [SRRunProjection observedTimeTextForEnvelope:envelope];
}
static NSDictionary *SRDictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static NSString *SRRunDescription(NSDictionary *run) {
    NSDictionary *summary = [SRRunProjection runSummary:run];
    NSDictionary *counts = summary[@"counts"];
    NSString *head = summary[@"phaseText"];
    if (![SRRunProjection phaseIsActive:summary[@"phase"]])
        head = [NSString stringWithFormat:@"%@\n结束于 %@", head, summary[@"endedText"]];
    return [NSString stringWithFormat:@"%@\n已处理 %@/%@ · 已提交 %@ · 已确认送达 %@\n失败 %@ · 结果未知 %@\n未发 %@ · 在途 %@ · 已取消 %@", head,
        summary[@"processed"], summary[@"total"], counts[@"submitted"] ?: @0, counts[@"confirmed"] ?: @0,
        counts[@"failed"] ?: @0, counts[@"uncertain"] ?: @0, counts[@"pending"] ?: @0,
        counts[@"submitting"] ?: @0, counts[@"cancelled"] ?: @0];
}
static void SRScreenPresent(UIViewController *controller, UIAlertController *alert) {
    void (^show)(void) = ^{ [controller presentViewController:alert animated:YES completion:nil]; };
    UIViewController *presented = controller.presentedViewController;
    if ([presented isKindOfClass:UIAlertController.class]) {
        if (presented.isBeingDismissed && [presented.transitionCoordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) { show(); }]) return;
        [presented dismissViewControllerAnimated:YES completion:show];
    } else show();
}
static void SRScreenAlert(UIViewController *controller, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    SRScreenPresent(controller, alert);
}

UIViewController *SRCreateRunResultRecord(SRStore *store, NSString *account, BOOL (^verifyAccount)(void), NSString *run) {
    BOOL verified = NO;
    @try { verified = verifyAccount && verifyAccount(); } @catch (__unused id exception) { }
    NSDictionary *row = verified && run.length ? [store summaryForRun:run error:NULL] : nil;
    NSString *body = @"本次记录暂不可读取，请返回后重试。";
    if ([row[@"account"] isEqual:account] && [@[@"completed", @"ended"] containsObject:row[@"state"]]) {
        NSMutableDictionary *card = [row mutableCopy], *counts = [NSMutableDictionary dictionary];
        for (NSDictionary *count in row[@"counts"]) counts[count[@"state"]] = count[@"count"];
        card[@"counts"] = counts;
        body = [NSString stringWithFormat:@"本次执行结束\n%@\n\n执行结束不代表全部送达。", SRRunDescription(card)];
    }
    return SRCreateReadOnlyText(@"本次转发记录", body, verifyAccount);
}

/* The reference has one continuous four-row surface. Keep icon and text
 * columns explicit: UITableViewCell's built-in image sizing varies by symbol. */
@interface SRHomeNavigationCell : UITableViewCell
@property(nonatomic, strong) UIView *surface;
@property(nonatomic, strong) UIImageView *symbol;
@property(nonatomic, strong) UILabel *heading;
@property(nonatomic, strong) UILabel *summary;
@property(nonatomic, strong) UIView *divider;
@property(nonatomic, strong) NSLayoutConstraint *minimumHeight;
@property(nonatomic, strong) NSLayoutConstraint *textTop;
@property(nonatomic, strong) NSLayoutConstraint *textBottom;
- (void)configureTitle:(NSString *)title summary:(NSString * _Nullable)summary
                symbol:(NSString *)symbol first:(BOOL)first last:(BOOL)last hint:(BOOL)hint;
@end
@implementation SRHomeNavigationCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:style reuseIdentifier:identifier];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor; self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundView = [[UIView alloc] init]; self.backgroundView.backgroundColor = UIColor.clearColor;
    _surface = [[UIView alloc] init]; _surface.layer.cornerRadius = 12; _surface.clipsToBounds = YES;
    _symbol = [[UIImageView alloc] init]; _symbol.contentMode = UIViewContentModeScaleAspectFit;
    _heading = [[UILabel alloc] init]; _summary = [[UILabel alloc] init];
    _heading.numberOfLines = 0; _summary.numberOfLines = 0;
    _heading.adjustsFontForContentSizeCategory = YES; _summary.adjustsFontForContentSizeCategory = YES;
    _heading.textColor = UIColor.labelColor; _summary.textColor = UIColor.secondaryLabelColor;
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[_heading, _summary]];
    text.axis = UILayoutConstraintAxisVertical; text.spacing = 4;
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.contentMode = UIViewContentModeScaleAspectFit; chevron.tintColor = UIColor.tertiaryLabelColor;
    chevron.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightRegular];
    _divider = [[UIView alloc] init]; _divider.backgroundColor = UIColor.separatorColor;
    [self.contentView addSubview:_surface];
    for (UIView *view in @[_symbol, text, chevron, _divider]) [_surface addSubview:view];
    for (UIView *view in @[_surface, _symbol, text, chevron, _divider]) view.translatesAutoresizingMaskIntoConstraints = NO;
    _minimumHeight = [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:74];
    _textTop = [text.topAnchor constraintEqualToAnchor:_surface.topAnchor constant:14];
    _textBottom = [text.bottomAnchor constraintEqualToAnchor:_surface.bottomAnchor constant:-14];
    [NSLayoutConstraint activateConstraints:@[
        [_surface.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
        [_surface.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
        [_surface.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [_surface.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        _minimumHeight,
        [_symbol.leadingAnchor constraintEqualToAnchor:_surface.leadingAnchor constant:18],
        [_symbol.widthAnchor constraintEqualToConstant:30], [_symbol.heightAnchor constraintEqualToConstant:30],
        [_symbol.centerYAnchor constraintEqualToAnchor:_surface.centerYAnchor],
        [text.leadingAnchor constraintEqualToAnchor:_symbol.trailingAnchor constant:18],
        [text.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-12],
        _textTop, _textBottom,
        [chevron.trailingAnchor constraintEqualToAnchor:_surface.trailingAnchor constant:-16],
        [chevron.widthAnchor constraintEqualToConstant:9], [chevron.heightAnchor constraintEqualToConstant:16],
        [chevron.centerYAnchor constraintEqualToAnchor:_surface.centerYAnchor],
        [_divider.leadingAnchor constraintEqualToAnchor:_surface.leadingAnchor],
        [_divider.trailingAnchor constraintEqualToAnchor:_surface.trailingAnchor],
        [_divider.bottomAnchor constraintEqualToAnchor:_surface.bottomAnchor],
        [_divider.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale]]];
    self.isAccessibilityElement = YES;
    return self;
}
- (void)configureTitle:(NSString *)title summary:(NSString *)summary symbol:(NSString *)symbol
                 first:(BOOL)first last:(BOOL)last hint:(BOOL)hint {
    self.heading.text = title; self.summary.text = summary; self.summary.hidden = !summary.length;
    self.minimumHeight.constant = hint ? 44 : 74;
    self.textTop.constant = hint ? 10 : 14; self.textBottom.constant = hint ? -10 : -14;
    self.heading.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline]
        scaledFontForFont:[UIFont systemFontOfSize:18 weight:hint ? UIFontWeightRegular : UIFontWeightSemibold]];
    self.summary.font = SRSettingsFont(14, UIFontTextStyleSubheadline);
    self.symbol.image = [UIImage systemImageNamed:symbol];
    self.symbol.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:27 weight:UIImageSymbolWeightRegular];
    self.symbol.tintColor = first && !hint ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
    self.surface.backgroundColor = SRSettingsCellBackground();
    self.surface.layer.maskedCorners = (first ? kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner : 0) |
        (last ? kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner : 0);
    self.divider.hidden = last;
    self.accessibilityLabel = summary.length ? [NSString stringWithFormat:@"%@，%@", title, summary] : title;
    self.accessibilityTraits = UIAccessibilityTraitButton;
}
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    self.surface.backgroundColor = highlighted ? UIColor.tertiarySystemFillColor : SRSettingsCellBackground();
}
@end

@interface SRNavigationHomeScreen : UITableViewController
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
@property(nonatomic, copy) void (^openDestination)(NSUInteger);
@property(nonatomic, copy) NSDictionary *configuration;
@property(nonatomic, copy) NSString *problem;
@property(nonatomic) BOOL accountInvalid;
@property(nonatomic) NSInteger hintDestination;
@property(nonatomic, strong) UIBarButtonItem *closeItem;
@end
@implementation SRNavigationHomeScreen
- (void)viewDidLoad {
    [super viewDidLoad]; SRStyleSettingsTable(self);
    self.title = @"SyncRelay";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.estimatedRowHeight = 74;
    self.view.accessibilityIdentifier = @"SyncRelay.NavigationHome";
    self.closeItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
        style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    [self restoreCloseButton];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hideContent)
        name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload)
        name:SRRelayStateChangedNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self restoreCloseButton];
    [self reload];
}
- (void)restoreCloseButton {
    self.navigationItem.hidesBackButton = YES;
    self.navigationItem.leftItemsSupplementBackButton = NO;
    self.navigationItem.leftBarButtonItems = @[self.closeItem];
}
- (BOOL)verified {
    @try { return self.verifyAccount && self.verifyAccount(); }
    @catch (__unused id exception) { return NO; }
}
- (void)hideContent {
    self.configuration = nil; self.problem = @"返回前台后重新核对"; self.hintDestination = -1;
    [self.tableView reloadData];
}
- (void)reload {
    self.configuration = nil; self.problem = nil; self.hintDestination = -1;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) { [self hideContent]; return; }
    self.accountInvalid = ![self verified];
    if (self.accountInvalid) self.problem = @"账号无法核对，请关闭后重新打开";
    else {
        NSError *error = nil;
        self.configuration = [self.store configurationForAccount:self.account error:&error];
        if (!self.configuration) self.problem = @"设置暂时无法读取，可到设置查看诊断";
        else if (![self.configuration[@"sourceGroup"][@"id"] length]) self.hintDestination = 0;
        else if (![self.configuration[@"rules"] count]) self.hintDestination = 2;
    }
    [self.tableView reloadData];
}
- (NSInteger)recordsSection { return self.hintDestination >= 0 ? 2 : 1; }
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return self.recordsSection + 1; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == self.recordsSection) return 1;
    return self.hintDestination >= 0 && section == 0 ? 1 : 4;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    SRHomeNavigationCell *cell = [tableView dequeueReusableCellWithIdentifier:@"navigation-home"] ?:
        [[SRHomeNavigationCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"navigation-home"];
    if (path.section == self.recordsSection) {
        [cell configureTitle:@"转发记录" summary:nil symbol:@"clock.arrow.circlepath" first:YES last:YES hint:YES];
        cell.accessibilityIdentifier = @"SyncRelay.HomeForwardingRecords";
        return cell;
    }
    if (self.hintDestination >= 0 && path.section == 0) {
        [cell configureTitle:self.hintDestination == 0 ? @"先设置母群" : @"去群分组" summary:nil
            symbol:@"info.circle" first:YES last:YES hint:YES];
        cell.accessibilityIdentifier = @"SyncRelay.HomeHint"; return cell;
    }
    NSString *title = @[@"群同步", @"消息库转发", @"群分组", @"设置"][path.row];
    NSArray *summaries = @[@"母群与消息来源 · 未设置", @"选择消息并转发", @"目标分组与排除群 · 未配置", @"节奏、显示与诊断"];
    NSString *summary = summaries[path.row];
    if (self.problem && (path.row == 0 || path.row == 2)) summary = self.problem;
    else if (path.row == 0 && [self.configuration[@"sourceGroup"][@"name"] length])
        summary = [NSString stringWithFormat:@"母群与消息来源 · %@", self.configuration[@"sourceGroup"][@"name"]];
    else if (path.row == 2 && [self.configuration[@"rules"] count])
        summary = [NSString stringWithFormat:@"目标分组与排除群 · %lu 个分组", (unsigned long)[self.configuration[@"rules"] count]];
    [cell configureTitle:title summary:summary
        symbol:@[@"arrow.triangle.2.circlepath", @"paperplane", @"person.2", @"gearshape"][path.row]
        first:path.row == 0 last:path.row == 3 hint:NO];
    cell.accessibilityIdentifier = @[@"SyncRelay.HomeSource", @"SyncRelay.HomeLibrary", @"SyncRelay.HomeGroups", @"SyncRelay.HomeSettings"][path.row];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || ![self verified]) { [self reload]; return; }
    if (self.navigationController.topViewController != self || self.navigationController.transitionCoordinator) return;
    if (path.section == self.recordsSection) {
        if (self.openDestination) self.openDestination(SRHomeForwardingRecords);
        return;
    }
    NSUInteger destination = self.hintDestination >= 0 && path.section == 0 ? (NSUInteger)self.hintDestination : (NSUInteger)path.row;
    if (destination < 4 && self.openDestination) self.openDestination(destination);
}
- (void)close {
    UINavigationController *navigation = self.navigationController;
    if (navigation.topViewController != self || !navigation.presentingViewController || navigation.isBeingDismissed) return;
    [navigation dismissViewControllerAnimated:YES completion:nil];
}
@end

UIViewController *SRCreateNavigationHome(SRStore *store, NSString *account, BOOL (^verifyAccount)(void), void (^openDestination)(NSUInteger)) {
    SRNavigationHomeScreen *screen = [[SRNavigationHomeScreen alloc] initWithStyle:UITableViewStyleGrouped];
    screen.store = store; screen.account = account; screen.verifyAccount = verifyAccount; screen.openDestination = openDestination;
    screen.hintDestination = -1; return screen;
}

static NSString *SRForwardingExcerpt(NSDictionary *record) {
    if ([record[@"excerpt"] length]) return record[@"excerpt"];
    if ([record[@"messageType"] isEqual:@"image"]) return @"图片消息";
    return @"暂无消息摘要";
}

static NSString *SRForwardingSource(NSDictionary *record) {
    return [record[@"sourceKind"] isEqual:@"message_library"] ? @"消息库" : @"群同步";
}

@interface SRForwardingRecordsScreen : UITableViewController
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
@property(nonatomic, copy, nullable) NSString *run;
@property(nonatomic, copy, nullable) NSDictionary *record;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *rows;
@property(nonatomic, copy, nullable) NSString *problem;
@property(nonatomic) BOOL more;
@property(nonatomic) BOOL pageFailed;
@property(nonatomic) BOOL masked;
@end

@implementation SRForwardingRecordsScreen
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.run ? @"转发详情" : @"转发记录";
    SRStyleSettingsTable(self);
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resigningActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (void)resigningActive:(__unused NSNotification *)notification {
    self.masked = YES;
    [self hideWithMessage:@"返回前台后重新核对"];
}
- (void)becameActive:(__unused NSNotification *)notification {
    self.masked = NO;
    if (self.viewIfLoaded.window && self.navigationController.topViewController == self) [self reload];
}
- (void)hideWithMessage:(NSString *)message {
    self.record = nil; [self.rows removeAllObjects]; self.more = NO; self.pageFailed = NO;
    self.problem = message;
    [self.tableView reloadData];
}
- (BOOL)verifyVisibleAccount {
    @try { if (self.verifyAccount && self.verifyAccount()) return YES; }
    @catch (__unused NSException *exception) { }
    [self hideWithMessage:@"账号无法核对，请返回后重新打开"];
    return NO;
}
- (void)reload {
    if (self.masked) { [self.refreshControl endRefreshing]; return; }
    self.record = nil; self.rows = [NSMutableArray array]; self.more = NO; self.pageFailed = NO; self.problem = nil;
    if ([self verifyVisibleAccount]) {
        if (self.run) self.record = [self.store forwardingRecordForRun:self.run account:self.account error:NULL];
        if (self.run && !self.record) [self hideWithMessage:@"暂时无法读取这次转发，请下拉重试"];
        else [self loadPage];
    }
    [self.refreshControl endRefreshing];
}
- (void)loadPage {
    const NSUInteger limit = 30;
    NSArray *page = self.run ? [self.store forwardingTargetsForRun:self.run account:self.account limit:limit offset:self.rows.count error:NULL] :
        [self.store forwardingRecordsForAccount:self.account beforeRun:self.rows.lastObject[@"id"] limit:limit error:NULL];
    self.pageFailed = !page;
    self.more = !page || page.count == limit;
    if (page) [self.rows addObjectsFromArray:page];
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return self.record ? 3 : 1; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.problem || (self.record && section < 2)) return 1;
    return MAX((NSUInteger)1, self.rows.count + (self.more ? 1 : 0));
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.record ? @[@"消息摘要", @"执行结果", @"目标群明细"][section] : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"forwarding-record"] ?:
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"forwarding-record"];
    SRStyleSettingsCell(cell);
    cell.textLabel.text = nil; cell.detailTextLabel.text = nil;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryNone; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (self.problem) {
        cell.textLabel.text = self.problem;
    } else if (self.record && path.section == 0) {
        cell.textLabel.text = SRForwardingExcerpt(self.record);
        NSString *source = SRForwardingSource(self.record);
        if ([self.record[@"sourceKind"] isEqual:@"group_sync"] && [self.record[@"ruleName"] length])
            source = [source stringByAppendingFormat:@" · %@", self.record[@"ruleName"]];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n开始 %@", source, SRDate(self.record[@"started_at"])];
    } else if (self.record && path.section == 1) {
        cell.textLabel.text = [NSString stringWithFormat:@"共 %@ 个目标群", [SRRunProjection runSummary:self.record][@"total"]];
        cell.detailTextLabel.text = SRRunDescription(self.record);
    } else if (path.row == (NSInteger)self.rows.count) {
        cell.textLabel.text = self.pageFailed ? @"读取失败，点此重试" :
            (self.more ? @"加载更多" : (self.record ? @"没有目标群记录" : @"还没有转发记录"));
        if (self.more) cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (self.record) {
        NSDictionary *row = self.rows[(NSUInteger)path.row];
        cell.textLabel.text = row[@"target"];
        cell.detailTextLabel.text = @{@"pending": @"未发", @"submitting": @"在途", @"submitted": @"已提交 · 未确认送达",
            @"confirmed": @"已确认送达", @"failed": @"失败", @"uncertain": @"待核对", @"cancelled": @"已取消"}[row[@"state"]] ?: @"状态待核对";
    } else {
        NSDictionary *row = self.rows[(NSUInteger)path.row];
        NSDictionary *summary = [SRRunProjection runSummary:row];
        cell.textLabel.numberOfLines = 2;
        cell.textLabel.text = SRForwardingExcerpt(row);
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@\n%@ 个群 · %@",
            SRForwardingSource(row), summary[@"startedText"], summary[@"total"], summary[@"phaseText"]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    UINavigationController *navigation = self.navigationController;
    if (self.problem || navigation.topViewController != self || navigation.transitionCoordinator || ![self verifyVisibleAccount]) return;
    if (self.record && path.section != 2) return;
    if (path.row == (NSInteger)self.rows.count && self.more) { [self loadPage]; return; }
    if (self.record || path.row >= (NSInteger)self.rows.count) return;
    NSString *run = self.rows[(NSUInteger)path.row][@"id"];
    if (!run.length) return;
    SRForwardingRecordsScreen *detail = [[SRForwardingRecordsScreen alloc] initWithStyle:UITableViewStyleInsetGrouped];
    detail.store = self.store; detail.account = self.account; detail.verifyAccount = self.verifyAccount; detail.run = run;
    [navigation pushViewController:detail animated:YES];
}
@end

UIViewController *SRCreateForwardingRecords(SRStore *store, NSString *account, BOOL (^verifyAccount)(void)) {
    SRForwardingRecordsScreen *screen = [[SRForwardingRecordsScreen alloc] initWithStyle:UITableViewStyleInsetGrouped];
    screen.store = store; screen.account = account; screen.verifyAccount = verifyAccount;
    return screen;
}

@interface SRSourceTextScreen : UIViewController
@property(nonatomic, copy) NSString *body;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
@end
@implementation SRSourceTextScreen
- (void)loadView {
    UITextView *text = [[UITextView alloc] init]; text.editable = NO;
    text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; text.adjustsFontForContentSizeCategory = YES;
    text.textColor = UIColor.labelColor; text.textContainerInset = UIEdgeInsetsMake(16, 16, 24, 16);
    text.backgroundColor = SRSettingsCellBackground(); self.view = text;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    SRStyleSettingsController(self);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resigningActive:) name:UIApplicationWillResignActiveNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadText]; }
- (void)becameActive:(__unused NSNotification *)notification { if (self.viewIfLoaded.window) [self reloadText]; }
- (void)resigningActive:(__unused NSNotification *)notification { ((UITextView *)self.viewIfLoaded).text = @""; }
- (void)reloadText {
    BOOL verified = NO;
    @try { verified = self.verifyAccount && self.verifyAccount(); } @catch (__unused NSException *exception) { }
    if (!verified) self.body = nil;
    ((UITextView *)self.view).text = self.body ?: @"当前账号无法核对或已经改变，源消息内容已隐藏。请返回设置重新读取账号。";
}
@end

@interface SRSourceImageScreen : UIViewController
@property(nonatomic, strong) SRImageAssetStore *assets;
@property(nonatomic, copy) NSDictionary *source;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
@property(nonatomic, strong) UIImageView *imageView;
@property(nonatomic, strong) UILabel *message;
@end
@implementation SRSourceImageScreen
- (void)loadView {
    self.view = [[UIView alloc] init]; self.view.backgroundColor = SRSettingsCellBackground();
    self.imageView = [[UIImageView alloc] init]; self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.message = [[UILabel alloc] init]; self.message.numberOfLines = 0; self.message.textAlignment = NSTextAlignmentCenter;
    self.message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; self.message.textColor = UIColor.secondaryLabelColor;
    self.message.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.imageView]; [self.view addSubview:self.message];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.imageView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.imageView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.imageView.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [self.imageView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [self.message.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [self.message.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [self.message.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor]]];
}
- (void)viewDidLoad {
    [super viewDidLoad]; SRStyleSettingsController(self);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadImage) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hideImage) name:UIApplicationWillResignActiveNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadImage]; }
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self reloadImage]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self hideImage]; }
- (void)hideImage { self.imageView.image = nil; self.message.text = @"图片已隐藏。返回前台后重新核对账号与图片资源。"; }
- (void)reloadImage {
    if (!self.viewIfLoaded.window) return;
    BOOL verified = NO;
    @try { verified = self.verifyAccount && self.verifyAccount(); } @catch (__unused id exception) { }
    if (!verified) { self.source = nil; [self hideImage]; self.message.text = @"当前账号无法核对或已经改变，图片已隐藏。"; return; }
    NSData *data = [self.assets dataForPayload:self.source[@"payload"] source:self.source error:NULL];
    self.imageView.image = data ? [UIImage imageWithData:data] : nil;
    self.message.text = self.imageView.image ? nil : @"图片快照缺失或校验未通过，请返回重新捕获。不会使用其他图片替代。";
}
@end

@interface SRRecordScreen : UITableViewController
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, strong) SRSourceCapture *capture;
@property(nonatomic, copy) NSNumber *previewGeneration;
@property(nonatomic, strong) SRSmallGroupSession *execution;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
@property(nonatomic) SRRecordKind kind;
@property(nonatomic, strong) NSMutableArray *rows;
@property(nonatomic, copy) NSDictionary *content;
@property(nonatomic, copy) NSDictionary *configuration;
@property(nonatomic, copy) NSString *problem;
@property(nonatomic) BOOL more;
@property(nonatomic) NSUInteger offset;
@end

@implementation SRRecordScreen
- (void)viewDidLoad {
    [super viewDidLoad];
    SRStyleSettingsTable(self);
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(executionChanged:) name:@"andyz.syncrelay.smallGroupChanged" object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (void)becameActive:(__unused NSNotification *)notification { if (self.viewIfLoaded.window) [self reload]; }
- (void)executionChanged:(__unused NSNotification *)notification { if (self.viewIfLoaded.window) [self reload]; }
- (BOOL)verified {
    @try { if (self.verifyAccount && self.verifyAccount()) return YES; } @catch (__unused NSException *exception) { }
    self.problem = @"当前账号无法核对或已经改变，旧内容已隐藏。请返回设置重新读取账号。";
    self.content = nil; self.configuration = nil; [self.rows removeAllObjects]; self.more = NO;
    [self.tableView reloadData]; return NO;
}
- (void)reload {
    self.rows = [NSMutableArray array]; self.content = nil; self.configuration = nil; self.problem = nil; self.offset = 0; self.more = NO;
    if (![self verified]) { [self.refreshControl endRefreshing]; return; }
    NSError *error = nil;
    if (self.kind == SRRecordPreview) {
        NSDictionary *snapshot = [self.capture previewSnapshotForAccount:self.account generation:self.previewGeneration];
        if (snapshot) {
            self.content = snapshot[@"source"]; self.configuration = snapshot[@"configuration"];
        } else self.problem = @"没有该账号待确认的源消息。预览在退出进程前仅保存在内存中，请返回手动重新等待。";
    } else if (self.kind == SRRecordPlan) {
        self.content = [self.store plan:self.identifier account:self.account error:&error];
        NSArray *cards = self.content ? [self.store ruleCardsForPlan:self.identifier account:self.account error:&error] : nil;
        if (cards) [self.rows addObjectsFromArray:cards];
    } else [self loadPage];
    if (error) { self.problem = error.localizedDescription; self.content = nil; [self.rows removeAllObjects]; }
    [self.refreshControl endRefreshing]; [self.tableView reloadData];
}
- (void)loadPage {
    if (![self verified]) return;
    NSError *error = nil; NSArray *page = nil;
    if (self.kind == SRRecordPlans) page = [self.store plansForAccount:self.account limit:50 offset:self.offset error:&error];
    if (self.kind == SRRecordHistory) page = [self.store historyForRule:self.identifier account:self.account limit:50 offset:self.offset error:&error];
    if (self.kind == SRRecordExceptions) page = [self.store exceptionsForRun:self.identifier account:self.account limit:50 offset:self.offset error:&error];
    if (!page) { self.problem = error.localizedDescription ?: @"无法读取记录，请下拉重试。"; self.more = NO; }
    else { self.problem = nil; [self.rows addObjectsFromArray:page]; self.offset += page.count; self.more = page.count == 50; }
    [self.tableView reloadData];
}
- (NSDictionary *)source {
    id source = self.kind == SRRecordPreview ? self.content : self.content[@"snapshot"];
    return [source isKindOfClass:NSDictionary.class] ? source : @{};
}
- (NSString *)sourceText {
    id payload = [self source][@"payload"];
    id text = [payload isKindOfClass:NSDictionary.class] ? payload[@"text"] : nil;
    if ([[self source][@"type"] isEqual:@"image"]) {
        NSDictionary *image = [self source][@"payload"];
        return [NSString stringWithFormat:@"图片快照 · %@ × %@ · %.1f KB\n本页预览或确认计划均不发送。", image[@"pixelWidth"], image[@"pixelHeight"], [image[@"byteCount"] doubleValue] / 1024.0];
    }
    return [text isKindOfClass:NSString.class] ? text : @"没有可用的内容预览，请重新捕获。";
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    if (self.problem || !self.content) return 1;
    return self.kind == SRRecordPreview ? 3 : 2;
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.problem) return 1;
    if (self.kind == SRRecordPreview) return section == 0 ? 8 : (section == 1 ? MAX((NSUInteger)1, self.rows.count) : 2);
    if (self.kind == SRRecordPlan) return section == 0 ? 8 : MAX((NSUInteger)1, self.rows.count);
    return MAX((NSUInteger)1, self.rows.count + (self.more ? 1 : 0));
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.problem) return @"读取已停止";
    if (self.kind == SRRecordPreview) return @[@"锁定的一条源消息", @"捕获时冻结的配置", @"确认操作"][section];
    if (self.kind == SRRecordPlan) return section == 0 ? @"已确认内容" : @"分组与最近状态";
    return nil;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.problem) return @"本页不会创建、继续或重试发送任务。";
    if (self.kind == SRRecordPreview && section == 2) return @"确认只建立内容计划和目标分组，不发送。所有规则使用同一条已确认内容；之后修改设置不会改变此计划。";
    if (self.kind == SRRecordPlan && section == 1) return @"点击规则进入执行详情。新批次的目标上限由高级设置控制。开始后串行转发；切后台或锁屏会暂停，不自动接下一条。";
    if (self.kind == SRRecordHistory) return @"执行完成表示本条队列处理结束，不代表全部送达。已提交与确认送达分开统计；点击批次只查看失败、结果未知和未发项。";
    if (self.kind == SRRecordExceptions) return @"无需逐群人工复核。异常保留供按需查看；继续只处理尚未尝试的目标，不自动重发已提交或结果未知的群。";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"record"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"record"];
    SRStyleSettingsCell(cell);
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.text = nil; cell.detailTextLabel.text = nil; cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (self.problem) { cell.textLabel.text = self.problem; return cell; }
    if ((self.kind == SRRecordPreview || self.kind == SRRecordPlan) && path.section == 0) {
        NSDictionary *source = [self source];
        // Row 4 stays the content entry point that opens the text/image viewer.
        // The time rows are appended after it so no existing index shifts.
        cell.textLabel.text = @[@"母群 ID", @"实际发送者 wxid", @"源消息类型", @"源消息 ID", @"消息内容（点开完整查看）",
            @"插件首次观察时间", @"抓取完成时间", @"宿主来源时间原始值（未验证）"][path.row];
        NSArray *values = @[source[@"group"] ?: @"未记录", source[@"sender"] ?: @"未记录", source[@"type"] ?: @"未记录", source[@"messageID"] ?: @"未记录"];
        if (path.row < 4) cell.detailTextLabel.text = values[path.row];
        else if (path.row == 4) {
            NSString *text = [self sourceText];
            NSRange range = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, MIN((NSUInteger)600, text.length))];
            cell.detailTextLabel.text = [text substringWithRange:range];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else cell.detailTextLabel.text = SRSourceTimeText(source, path.row);
        return cell;
    }
    if (self.kind == SRRecordPreview) {
        if (path.section == 1) {
            NSUInteger targets = 0; for (NSDictionary *rule in self.configuration[@"rules"]) targets += [rule[@"targets"] count];
            cell.textLabel.text = [NSString stringWithFormat:@"%lu 条规则 · %lu 个目标群", (unsigned long)[self.configuration[@"rules"] count], (unsigned long)targets];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"间隔 %@–%@ 秒；来源 wxid 和类型均按捕获时配置筛选。", self.configuration[@"minimum"], self.configuration[@"maximum"]];
        } else {
            cell.textLabel.text = path.row == 0 ? @"确认内容，建立计划（不发送）" : @"放弃这条预览";
            cell.textLabel.textColor = path.row == 0 ? UIColor.systemBlueColor : UIColor.systemRedColor;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        return cell;
    }
    if (!self.rows.count) {
        cell.textLabel.text = self.kind == SRRecordPlans ? @"尚无已确认内容计划" : (self.kind == SRRecordHistory ? @"此规则尚未执行" : @"没有失败、待核对或取消的群");
        return cell;
    }
    if (path.row == (NSInteger)self.rows.count) { cell.textLabel.text = @"加载更多"; cell.selectionStyle = UITableViewCellSelectionStyleDefault; return cell; }
    NSDictionary *row = self.rows[path.row];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (self.kind == SRRecordPlans) {
        cell.textLabel.text = row[@"source_group"];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ 个分组 · %@ 个群", row[@"ruleCount"], row[@"targetCount"]];
    } else if (self.kind == SRRecordPlan) {
        cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@ 个群", row[@"name"], row[@"targetCount"]];
        NSDictionary *run = [row[@"latestRun"] isKindOfClass:NSDictionary.class] ? row[@"latestRun"] : nil;
        cell.detailTextLabel.text = run ? SRRunDescription(run) : ([row[@"initialUnlocked"] boolValue] ? @"未执行 · 顺序已解锁" : @"未执行 · 等待前序规则结束");
        NSUInteger count = [row[@"targetCount"] unsignedIntegerValue], limit = self.store.forwardingTargetLimit;
        if (!run && count > limit) cell.detailTextLabel.text = [cell.detailTextLabel.text stringByAppendingFormat:@"\n%@", SRTargetLimitMessage(count, limit)];
        if (!run && [row[@"accountOccupied"] boolValue]) cell.detailTextLabel.text = [cell.detailTextLabel.text stringByAppendingString:@"\n账号仍有活动批次，不能开始另一条。"];
    } else if (self.kind == SRRecordHistory) {
        cell.textLabel.text = SRRunDescription(row);
        cell.detailTextLabel.text = [NSString stringWithFormat:@"开始 %@\n批次 %@", SRDate(row[@"started_at"]), row[@"id"]];
    } else {
        cell.textLabel.text = row[@"target"];
        NSString *state = @{@"failed": @"明确失败", @"uncertain": @"待核对", @"cancelled": @"已取消 / 未继续发送"}[row[@"state"]] ?: row[@"state"];
        NSString *reason = [row[@"reason"] isKindOfClass:NSString.class] ? row[@"reason"] : @"未记录额外原因";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@", state, reason];
        cell.selectionStyle = UITableViewCellSelectionStyleNone; cell.accessoryType = UITableViewCellAccessoryNone;
    }
    return cell;
}
- (SRRecordScreen *)screen:(SRRecordKind)kind identifier:(NSString *)identifier title:(NSString *)title {
    SRRecordScreen *screen = [[SRRecordScreen alloc] initWithStyle:UITableViewStyleGrouped];
    screen.kind = kind; screen.store = self.store; screen.account = self.account; screen.verifyAccount = self.verifyAccount;
    screen.execution = self.execution;
    screen.identifier = identifier; screen.title = title; return screen;
}
/* B-2 closeout: the old rule menu and its start/pause/resume/cancel/end calls
 * are gone. A rule row opens the execution detail page instead, which is the
 * only place a run can be started and which re-checks the frozen card after a
 * late confirmation. Keeping the older page command-capable would route around
 * that re-check. */
- (void)openRule:(NSDictionary *)rule {
    id run = [rule[@"latestRun"] isKindOfClass:NSDictionary.class] ? rule[@"latestRun"][@"id"] : nil;
    [self.navigationController pushViewController:SRCreateRunDetail(self.store, self.execution, self.account,
        self.verifyAccount, self.identifier, rule[@"id"],
        [run isKindOfClass:NSString.class] ? run : nil) animated:YES];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (![self verified] || self.problem) return;
    if ((self.kind == SRRecordPreview || self.kind == SRRecordPlan) && path.section == 0) {
        if (path.row == 4) {
            BOOL (^verifyContent)(void) = self.verifyAccount;
            if (self.kind == SRRecordPreview) {
                SRSourceCapture *capture = self.capture;
                NSString *account = self.account;
                NSNumber *generation = self.previewGeneration;
                BOOL (^verifyAccount)(void) = self.verifyAccount;
                verifyContent = ^BOOL {
                    return verifyAccount && verifyAccount() && [capture previewSnapshotForAccount:account generation:generation] != nil;
                };
                if (![capture previewSnapshotForAccount:account generation:generation]) { [self reload]; return; }
            }
            if ([[self source][@"type"] isEqual:@"image"]) {
                SRSourceImageScreen *viewer = [[SRSourceImageScreen alloc] init]; viewer.title = @"源图片预览（不发送）";
                viewer.source = [self source]; viewer.assets = self.store.imageAssets; viewer.verifyAccount = verifyContent;
                [self.navigationController pushViewController:viewer animated:YES]; return;
            }
            SRSourceTextScreen *viewer = [[SRSourceTextScreen alloc] init]; viewer.title = @"源消息内容";
            viewer.body = [self sourceText]; viewer.verifyAccount = verifyContent;
            [self.navigationController pushViewController:viewer animated:YES];
        }
        return;
    }
    if (self.kind == SRRecordPreview) {
        if (path.section != 2) return;
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        if (path.row == 1) {
            if (![self.capture discardPreviewForAccount:self.account generation:self.previewGeneration]) { [self reload]; return; }
            [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
            [self.navigationController popViewControllerAnimated:YES]; return;
        }
        NSError *error = nil;
        NSString *plan = [self.capture confirmForCurrentAccount:self.account generation:self.previewGeneration error:&error];
        if (!plan) { SRScreenAlert(self, @"确认失败，未发送", error.localizedDescription); return; }
        [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
        UIViewController *next = [self screen:SRRecordPlan identifier:plan title:@"内容计划与规则"];
        NSMutableArray *stack = [self.navigationController.viewControllers mutableCopy]; stack[stack.count - 1] = next;
        [self.navigationController setViewControllers:stack animated:YES]; return;
    }
    if (path.row == (NSInteger)self.rows.count && self.more) { [self loadPage]; return; }
    if (path.row >= (NSInteger)self.rows.count) return;
    NSDictionary *row = self.rows[path.row]; SRRecordScreen *next = nil;
    if (self.kind == SRRecordPlans) next = [self screen:SRRecordPlan identifier:row[@"id"] title:@"历史内容与分组"];
    if (self.kind == SRRecordPlan) { [self openRule:row]; return; }
    if (self.kind == SRRecordHistory) next = [self screen:SRRecordExceptions identifier:row[@"id"] title:@"异常群与未发项"];
    if (next) [self.navigationController pushViewController:next animated:YES];
}
@end

UIViewController *SRCreateCapturePreview(SRStore *store, SRSourceCapture *capture, NSString *account, BOOL (^verifyAccount)(void), SRSmallGroupSession *execution) {
    SRRecordScreen *screen = [[SRRecordScreen alloc] initWithStyle:UITableViewStyleGrouped];
    screen.kind = SRRecordPreview; screen.store = store; screen.capture = capture; screen.account = account;
    screen.previewGeneration = capture.status[@"generation"];
    screen.verifyAccount = verifyAccount; screen.execution = execution; screen.title = @"单条源消息预览"; return screen;
}

/* The user-facing capture route is separate from the diagnostic record page.
 * Only the final explicit continue tap confirms content; opening, selecting a
 * group and inspecting targets are read-only. Run controls stay in run detail. */
@interface SRCapturedForwardingScreen : UITableViewController
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, strong) SRSourceCapture *capture;
@property(nonatomic, strong) SRSmallGroupSession *execution;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSNumber *generation;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
@property(nonatomic, copy) NSDictionary *source;
@property(nonatomic, copy) NSArray *groups;
@property(nonatomic) NSUInteger selectedIndex;
@property(nonatomic, copy) NSString *confirmedPlan;
@property(nonatomic, copy) NSString *problem;
@end

@implementation SRCapturedForwardingScreen
- (void)viewDidLoad {
    [super viewDidLoad]; SRStyleSettingsTable(self);
    self.title = @"转发分组";
    self.view.accessibilityIdentifier = @"SyncRelay.CapturedForwarding";
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hideContent)
        name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload)
        name:SRRelayStateChangedNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (BOOL)verified {
    @try { return self.verifyAccount && self.verifyAccount(); }
    @catch (__unused id exception) { return NO; }
}
- (BOOL)contentIsCurrent {
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive && [self verified] &&
        (self.confirmedPlan.length || [self.capture previewSnapshotForAccount:self.account generation:self.generation] != nil);
}
- (void)hideContent {
    self.source = nil; self.groups = @[];
    self.problem = @"内容已隐藏，返回前台后重新核对。";
    [self.tableView reloadData];
}
- (void)reload {
    self.source = nil; self.groups = @[]; self.problem = nil;
    if (![self verified]) self.problem = @"账号已改变或无法核对，请返回重新打开。";
    else if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self hideContent]; return;
    } else if (self.confirmedPlan.length) {
        NSError *error = nil;
        NSDictionary *plan = [self.store plan:self.confirmedPlan account:self.account error:&error];
        NSArray *cards = plan ? [self.store ruleCardsForPlan:self.confirmedPlan account:self.account error:&error] : nil;
        self.source = plan[@"snapshot"];
        self.groups = [SRRunProjection groupRowsForCards:cards targetLimit:self.store.forwardingTargetLimit];
        if (!plan || !cards) self.problem = error.localizedDescription ?: @"无法读取已确认内容，请返回重试。";
    } else {
        NSDictionary *snapshot = [self.capture previewSnapshotForAccount:self.account generation:self.generation];
        self.source = snapshot[@"source"];
        self.groups = [SRRunProjection groupRowsForConfiguration:snapshot[@"configuration"] targetLimit:self.store.forwardingTargetLimit];
        if (!snapshot) self.problem = @"这条待处理消息已失效，请返回查看当前内容。";
    }
    if (self.source && ![self.source[@"type"] isEqual:@"text"] && ![self.source[@"type"] isEqual:@"image"])
        self.problem = @"暂不支持转发这种消息类型。";
    if (self.problem) { self.source = nil; self.groups = @[]; }
    if (self.selectedIndex >= self.groups.count) self.selectedIndex = NSNotFound;
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return self.problem ? 1 : 3; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.problem || section == 0) return 1;
    if (section == 1) return MAX((NSUInteger)1, self.groups.count);
    return self.confirmedPlan.length ? 1 : 2;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.problem) return @"暂不可用";
    return @[@"1  核对内容", @"2  选择一个分组", @"3  核对后再转发"][section];
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.problem) return @"本页不会启动转发。";
    if (section == 1) return @"点选分组，点右侧 ⓘ 查看群名单。分组按顺序执行，不会自动接下一组。";
    if (section == 2) return @"下一步只确认内容并打开本组详情；仍需点击「开始转发本组」并确认才会发送。";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"capture-forward"] ?:
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"capture-forward"];
    SRStyleSettingsCell(cell); cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.text = nil; cell.detailTextLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryNone; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessibilityIdentifier = nil;
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    if (self.problem) { cell.textLabel.text = self.problem; return cell; }
    if (path.section == 0) {
        cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", [SRRunProjection typeTextForEnvelope:self.source],
            self.confirmedPlan.length ? @"已确认" : @"待转发"];
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        cell.detailTextLabel.text = [SRRunProjection excerptForEnvelope:self.source limit:280];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityIdentifier = @"SyncRelay.ForwardingContent";
    } else if (path.section == 1) {
        if (!self.groups.count) { cell.textLabel.text = @"还没有目标分组"; cell.detailTextLabel.text = @"到设置添加分组后，重新等待一条消息。"; return cell; }
        NSDictionary *row = self.groups[(NSUInteger)path.row];
        BOOL selected = self.selectedIndex == (NSUInteger)path.row;
        if (selected) cell.accessibilityTraits |= UIAccessibilityTraitSelected;
        cell.textLabel.text = [NSString stringWithFormat:@"%@%@", selected ? @"✓  " : @"", row[@"name"]];
        cell.textLabel.textColor = selected ? SRSettingsAccent() : UIColor.labelColor;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ 个群%@", row[@"targetCount"],
            [row[@"overTargetLimit"] boolValue] ? @" · 超过上限" : @""];
        if ([row[@"overTargetLimit"] boolValue]) cell.detailTextLabel.text = row[@"blockedText"];
        else if (!self.confirmedPlan.length && path.row > 0)
            cell.detailTextLabel.text = [cell.detailTextLabel.text stringByAppendingString:@" · 前序分组结束后可开始"];
        cell.accessoryType = UITableViewCellAccessoryDetailButton;
        cell.accessibilityIdentifier = @"SyncRelay.ForwardingGroup";
    } else if (path.row == 0) {
        BOOL selected = self.selectedIndex < self.groups.count;
        cell.textLabel.text = selected ? [NSString stringWithFormat:@"下一步 · 核对 %@", self.groups[self.selectedIndex][@"name"]] : @"请先选择一个分组";
        cell.textLabel.textColor = selected ? SRSettingsAccent() : UIColor.secondaryLabelColor;
        cell.selectionStyle = selected ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        cell.accessibilityIdentifier = @"SyncRelay.ForwardingContinue";
    } else { cell.textLabel.text = @"忽略这条"; cell.textLabel.textColor = UIColor.systemRedColor; }
    return cell;
}
- (void)tableView:(__unused UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)path {
    if (path.section != 1 || (NSUInteger)path.row >= self.groups.count || ![self contentIsCurrent]) return;
    NSDictionary *row = self.groups[(NSUInteger)path.row];
    NSMutableArray *lines = [NSMutableArray array];
    NSArray *targets = row[@"targets"], *names = row[@"targetNames"];
    for (NSUInteger i = 0; i < targets.count; i++) {
        NSString *name = i < names.count ? names[i] : nil;
        [lines addObject:name.length ? [NSString stringWithFormat:@"%lu. %@（%@）", (unsigned long)i + 1, name, targets[i]] :
            [NSString stringWithFormat:@"%lu. %@", (unsigned long)i + 1, targets[i]]];
    }
    __weak typeof(self) weakSelf = self;
    SRSourceTextScreen *viewer = [[SRSourceTextScreen alloc] init]; viewer.title = row[@"name"];
    viewer.body = [lines componentsJoinedByString:@"\n\n"];
    viewer.verifyAccount = ^BOOL { return [weakSelf contentIsCurrent]; };
    [self.navigationController pushViewController:viewer animated:YES];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (![self contentIsCurrent] || self.problem) { [self reload]; return; }
    if (path.section == 0) {
        __weak typeof(self) weakSelf = self;
        BOOL (^verify)(void) = ^BOOL { return [weakSelf contentIsCurrent]; };
        if ([self.source[@"type"] isEqual:@"image"]) {
            SRSourceImageScreen *viewer = [[SRSourceImageScreen alloc] init]; viewer.title = @"图片内容";
            viewer.source = self.source; viewer.assets = self.store.imageAssets; viewer.verifyAccount = verify;
            [self.navigationController pushViewController:viewer animated:YES];
        } else {
            SRSourceTextScreen *viewer = [[SRSourceTextScreen alloc] init]; viewer.title = @"文字内容";
            viewer.body = self.source[@"payload"][@"text"]; viewer.verifyAccount = verify;
            [self.navigationController pushViewController:viewer animated:YES];
        }
    } else if (path.section == 1 && (NSUInteger)path.row < self.groups.count) {
        self.selectedIndex = (NSUInteger)path.row;
        [tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)]
            withRowAnimation:UIAccessibilityIsReduceMotionEnabled() ? UITableViewRowAnimationNone : UITableViewRowAnimationFade];
    } else if (path.section == 2 && path.row == 1 && !self.confirmedPlan.length) {
        if (![self.capture discardPreviewForAccount:self.account generation:self.generation]) { [self reload]; return; }
        [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
        [self.navigationController popViewControllerAnimated:YES];
    } else if (path.section == 2 && path.row == 0) [self continuePressed];
}
- (void)continuePressed {
    if (self.navigationController.topViewController != self) return;
    if (![self contentIsCurrent] || self.selectedIndex >= self.groups.count) { [self reload]; return; }
    NSDictionary *selected = self.groups[self.selectedIndex];
    if ([selected[@"overTargetLimit"] boolValue]) { SRScreenAlert(self, @"分组超过上限", selected[@"blockedText"]); return; }
    NSError *error = nil;
    if (!self.confirmedPlan.length) {
        self.confirmedPlan = [self.capture confirmForCurrentAccount:self.account generation:self.generation error:&error];
        if (!self.confirmedPlan) { SRScreenAlert(self, @"确认失败，未发送", error.localizedDescription); return; }
    }
    /* Keep the exact plan ID even if readback fails. A retry cannot consume the
     * same preview again or accidentally confirm a newly captured message. */
    NSArray *cards = [self.store ruleCardsForPlan:self.confirmedPlan account:self.account error:&error];
    NSDictionary *card = [SRRunProjection confirmedCardForRow:selected atIndex:self.selectedIndex cards:cards];
    if (!card) {
        self.selectedIndex = NSNotFound;
        [self reload];
        SRScreenAlert(self, @"分组核对未完成", error.localizedDescription ?: @"所选分组与已保存内容不一致，请重新选择并核对。未开始发送。");
        return;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
    UIViewController *groups = SRCreateGroupList(self.store, self.execution, self.account, self.verifyAccount, self.confirmedPlan, nil);
    NSDictionary *run = SRDictionary(card[@"latestRun"]);
    UIViewController *detail = SRCreateRunDetail(self.store, self.execution, self.account, self.verifyAccount,
        self.confirmedPlan, card[@"id"], run[@"id"]);
    NSMutableArray *stack = [self.navigationController.viewControllers mutableCopy];
    [stack removeLastObject]; [stack addObject:groups]; [stack addObject:detail];
    [self.navigationController setViewControllers:stack animated:YES];
}
@end

UIViewController *SRCreateCapturedForwarding(SRStore *store, SRSourceCapture *capture, NSString *account, NSNumber *generation,
                                             BOOL (^verifyAccount)(void), SRSmallGroupSession *execution) {
    SRCapturedForwardingScreen *screen = [[SRCapturedForwardingScreen alloc] initWithStyle:UITableViewStyleInsetGrouped];
    screen.store = store; screen.capture = capture; screen.account = account; screen.generation = generation;
    screen.verifyAccount = verifyAccount; screen.execution = execution; screen.selectedIndex = NSNotFound;
    return screen;
}
UIViewController *SRCreatePlanList(SRStore *store, NSString *account, BOOL (^verifyAccount)(void), SRSmallGroupSession *execution) {
    SRRecordScreen *screen = [[SRRecordScreen alloc] initWithStyle:UITableViewStyleGrouped];
    screen.kind = SRRecordPlans; screen.store = store; screen.account = account;
    screen.verifyAccount = verifyAccount; screen.execution = execution; screen.title = @"历史内容"; return screen;
}

/* ------------------------------------------------------------------------ */
/* Phase B operations flow (B-2)                                            */
/*                                                                          */
/* 运营首页 → 分组列表 → 执行详情. All three pages project Core state plus the */
/* live SRSmallGroupSession. Only an explicit tap on an action row calls a   */
/* command, and every command re-verifies the account and the frozen         */
/* identity the page displayed. Opening, refreshing or leaving a page never  */
/* arms capture, creates a plan, resumes a run or sends anything.            */
/* ------------------------------------------------------------------------ */

static NSString *const SRHomeModePreview = @"preview";
static NSString *const SRHomeModeConfirmed = @"confirmed";
static NSString *const SRHomeModePrepared = @"prepared";
static NSString *const SRHomeModeNone = @"none";

/* The frozen envelope is the only content a viewer may show: no host re-read,
 * no media preparation, no send. */
static void SRPushContentViewer(UIViewController *controller, SRStore *store,
                                NSDictionary *envelope, BOOL (^verifyAccount)(void)) {
    if (![envelope isKindOfClass:NSDictionary.class] || !controller.navigationController) return;
    if ([envelope[@"type"] isEqual:@"image"]) {
        SRSourceImageScreen *viewer = [[SRSourceImageScreen alloc] init];
        viewer.title = @"源图片预览（不发送）";
        viewer.source = envelope; viewer.assets = store.imageAssets; viewer.verifyAccount = verifyAccount;
        [controller.navigationController pushViewController:viewer animated:YES];
        return;
    }
    SRSourceTextScreen *viewer = [[SRSourceTextScreen alloc] init];
    viewer.title = @"源消息内容（不发送）";
    viewer.body = [SRRunProjection excerptForEnvelope:envelope limit:0];
    viewer.verifyAccount = verifyAccount;
    [controller.navigationController pushViewController:viewer animated:YES];
}

static NSDictionary *SRCardForRule(NSArray *cards, NSString *rule) {
    if (![cards isKindOfClass:NSArray.class] || ![rule isKindOfClass:NSString.class] || !rule.length) return nil;
    for (id entry in cards)
        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"id"] isEqual:rule]) return entry;
    return nil;
}

/* `cancelled` is attached only when a cancellation row exists for this exact
 * run and account. An `ended` run without one stays "已结束", never "处理完成". */
static NSDictionary *SRRunWithCancellation(SRStore *store, NSString *account, NSDictionary *run) {
    if (![run isKindOfClass:NSDictionary.class]) return nil;
    if (![run[@"state"] isEqual:@"ended"]) return run;
    NSDictionary *cancellation = [store operationsCancellationForRun:run[@"id"] account:account error:NULL];
    if (![cancellation isKindOfClass:NSDictionary.class] || !cancellation.count) return run;
    NSMutableDictionary *tagged = [run mutableCopy]; tagged[@"cancelled"] = @YES;
    return tagged;
}

/* Runs are tagged before the group rows are built, in one pass per page, so a
 * cell never reads the database. */
static NSArray *SRCardsWithCancellation(SRStore *store, NSString *account, NSArray *cards) {
    if (![cards isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:cards.count];
    for (id entry in cards) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *card = [entry mutableCopy];
        NSDictionary *run = SRDictionary(card[@"latestRun"]);
        NSDictionary *tagged = run ? SRRunWithCancellation(store, account, run) : nil;
        card[@"latestRun"] = tagged ?: (id)NSNull.null;
        [result addObject:card];
    }
    return result;
}

/* Keep model section identities stable while placing content first visually. */
static NSInteger SRHomeModelSection(NSInteger section) { return section < 2 ? 1 - section : section; }

@interface SROperationsHomeScreen : UITableViewController
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, strong) SRSourceCapture *capture;
@property(nonatomic, strong) SRSmallGroupSession *execution;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
/* An explicit route to the existing settings panel. It is supplied by the
 * caller so the home never guesses a selector or builds a parallel copy of
 * the settings state. */
@property(nonatomic, copy, nullable) void (^openSettings)(void);
/* Resolved once per reload; a cell never re-queries the store. */
@property(nonatomic, copy, nullable) NSDictionary *operations;
@property(nonatomic, copy, nullable) NSDictionary *envelope;
@property(nonatomic, copy, nullable) NSString *planID;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic, copy, nullable) NSNumber *previewGeneration;
@property(nonatomic, copy, nullable) NSDictionary *sourceCaptureStatus;
@property(nonatomic, copy, nullable) id capturedAt;
/* The configuration frozen with the content this page shows: the one the
 * preview was captured with, or the one persisted with the prepared content.
 * The groups are projected from it, so a settings change made after the
 * capture cannot rewrite what this content displays or where it would go. */
@property(nonatomic, copy, nullable) NSDictionary *frozenConfiguration;
@property(nonatomic, copy) NSArray *cards;
@property(nonatomic, copy) NSArray *groupRows;
@property(nonatomic, copy) NSDictionary *overview;
@property(nonatomic, copy, nullable) NSDictionary *recentRun;
@property(nonatomic, copy, nullable) NSString *recentRunPlanID;
@property(nonatomic, copy) NSArray *runActions;
@property(nonatomic, copy, nullable) NSDictionary *problem;
@property(nonatomic) BOOL accountInvalid;
@end

@implementation SROperationsHomeScreen
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"群同步";
    self.view.accessibilityIdentifier = @"SyncRelay.GroupSyncHome";
    SRStyleSettingsTable(self);
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
        style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"设置"
        style:UIBarButtonItemStylePlain target:self action:@selector(settingsPressed)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged:)
        name:SRRelayStateChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged:)
        name:@"andyz.syncrelay.smallGroupChanged" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hideContent)
        name:UIApplicationWillResignActiveNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (void)stateChanged:(__unused NSNotification *)notification { if (self.viewIfLoaded.window) [self reload]; }
- (void)hideContent {
    self.envelope = nil; self.frozenConfiguration = nil; self.cards = @[]; self.groupRows = @[];
    self.runActions = @[]; self.accountInvalid = YES;
    [self.tableView reloadData];
}
- (BOOL)verified {
    @try { return self.verifyAccount && self.verifyAccount(); }
    @catch (__unused id exception) { return NO; }
}
- (void)reload {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) { [self hideContent]; return; }
    self.operations = nil; self.envelope = nil; self.planID = nil;
    self.mode = SRHomeModeNone; self.capturedAt = nil; self.frozenConfiguration = nil;
    self.previewGeneration = nil;
    self.sourceCaptureStatus = nil;
    self.cards = @[]; self.groupRows = @[];
    self.overview = nil; self.recentRun = nil; self.recentRunPlanID = nil;
    self.runActions = @[]; self.problem = nil;
    /* A changed account is its own state: it must not read as "已完成" or as
     * "暂无内容", and the old page is refused instead of switched. */
    self.accountInvalid = ![self verified];
    if (self.accountInvalid) { [self.tableView reloadData]; return; }
    NSDictionary *captureStatus = self.capture.status;
    if ([captureStatus[@"account"] isEqual:self.account]) self.sourceCaptureStatus = captureStatus;
    NSError *error = nil;
    NSDictionary *operations = [self.store operationsContentForAccount:self.account error:&error];
    if (!operations) {
        self.problem = @{@"title": @"状态读取失败", @"message": error.localizedDescription ?: @"无法读取运营状态，请稍后刷新。"};
        [self.tableView reloadData]; return;
    }
    self.operations = operations;
    if (![self resolveContent:&error] || ![self loadGroups:&error]) {
        self.problem = @{@"title": @"内容读取失败", @"message": error.localizedDescription ?: @"无法读取内容或分组，请稍后刷新。"};
        self.envelope = nil; self.cards = @[]; self.groupRows = @[]; self.overview = nil; self.recentRun = nil;
        [self.tableView reloadData]; return;
    }
    [self buildRunActions];
    [self.tableView reloadData];
}
/* The current content is, in order: the in-memory preview this account just
 * captured, the prepared operations content, or the newest confirmed plan.
 * A preview stays a preview; it is never promoted to confirmed content.
 * The content's own frozen configuration is resolved here as well, so the
 * groups below come from the same capture that produced the content. */
- (BOOL)resolveContent:(NSError **)error {
    self.frozenConfiguration = nil;
    NSDictionary *captureStatus = self.capture.status;
    BOOL captureBelongs = [captureStatus[@"account"] isEqual:self.account];
    NSNumber *generation = captureStatus[@"generation"];
    NSDictionary *preview = captureBelongs ? [self.capture previewSnapshotForAccount:self.account generation:generation] : nil;
    if (preview) {
        /* The preview's configuration is the one saved when it was captured;
         * settings edited afterwards belong to later captures only. */
        self.frozenConfiguration = SRDictionary(preview[@"configuration"]);
        self.previewGeneration = generation;
        self.mode = SRHomeModePreview; self.envelope = SRDictionary(preview[@"source"]); return YES;
    }
    NSDictionary *current = SRDictionary(self.operations[@"current"]);
    if (current) {
        /* Prepared content persists its own frozen configuration row. */
        self.frozenConfiguration = SRDictionary(current[@"configuration"]);
        self.envelope = SRDictionary(current[@"envelope"]);
        self.capturedAt = current[@"captured_at"];
        id plan = current[@"plan_id"];
        if ([plan isKindOfClass:NSString.class] && [plan length]) {
            self.planID = plan;
            /* The frozen plan holds the same snapshot; read it back so the page
             * shows the confirmed content rather than the preparation row. */
            NSDictionary *planRow = [self.store plan:plan account:self.account error:error];
            if (!planRow) return NO;
            self.envelope = SRDictionary(planRow[@"snapshot"]) ?: self.envelope;
            self.mode = SRHomeModeConfirmed;
        } else self.mode = SRHomeModePrepared;
        return YES;
    }
    NSArray *plans = [self.store plansForAccount:self.account limit:1 offset:0 error:error];
    if (!plans) return NO;
    id newest = plans.count ? plans[0][@"id"] : nil;
    if (![newest isKindOfClass:NSString.class] || ![newest length]) { self.mode = SRHomeModeNone; return YES; }
    NSDictionary *planRow = [self.store plan:newest account:self.account error:error];
    if (!planRow) return NO;
    /* A confirmed plan carries its own frozen rules; no configuration row is
     * read for it, so nothing here can be replaced by the current settings. */
    self.planID = newest;
    self.envelope = SRDictionary(planRow[@"snapshot"]);
    self.mode = SRHomeModeConfirmed;
    return YES;
}
/* Frozen groups come from the confirmed plan. Without a plan the configuration
 * frozen with the displayed content is projected; the currently saved settings
 * are only a fallback when the page has no content at all. Either way the page
 * stays read-only and nothing is executable. */
- (BOOL)loadGroups:(NSError **)error {
    if (self.planID.length) {
        NSArray *cards = [self.store ruleCardsForPlan:self.planID account:self.account error:error];
        if (!cards) return NO;
        self.cards = SRCardsWithCancellation(self.store, self.account, cards);
        self.groupRows = [SRRunProjection groupRowsForCards:self.cards targetLimit:self.store.forwardingTargetLimit];
    } else {
        /* The content's frozen configuration first; the saved settings must not
         * stand in for it after the user edits them. */
        NSDictionary *configuration = self.frozenConfiguration;
        if (!configuration) configuration = [self.store configurationForAccount:self.account error:error];
        if (!configuration) return NO;
        self.groupRows = [SRRunProjection groupRowsForConfiguration:configuration targetLimit:self.store.forwardingTargetLimit];
    }
    self.overview = [SRRunProjection overviewForGroupRows:self.groupRows];
    [self resolveRecentResult];
    return YES;
}
/* The recent result is the latest terminal run of the archived content's own
 * plan, or of the current plan when nothing was archived. Selection is by
 * durable creation order, so a newer task can never take this slot. */
- (void)resolveRecentResult {
    NSArray *cards = self.cards;
    NSString *owner = self.planID;
    NSDictionary *recent = SRDictionary(self.operations[@"recent"]);
    id plan = recent[@"plan_id"];
    if ([plan isKindOfClass:NSString.class] && [plan length]) {
        NSArray *recentCards = [self.store ruleCardsForPlan:plan account:self.account error:NULL];
        if (recentCards) {
            cards = SRCardsWithCancellation(self.store, self.account, recentCards);
            owner = plan;
        }
    }
    NSDictionary *run = [SRRunProjection latestRunInCards:cards];
    if (!run) return;
    self.recentRun = SRRunWithCancellation(self.store, self.account, run);
    self.recentRunPlanID = owner;
}
/* Live status is only a projection of the session that owns this account. */
- (NSDictionary *)liveSummary {
    if (![self.execution progressBelongsToCurrentAccount]) return nil;
    return [SRRunProjection runSummary:self.execution.status];
}
- (void)buildRunActions {
    NSMutableArray *actions = [NSMutableArray array];
    NSString *run = self.execution.currentRunID;
    NSDictionary *summary = [self liveSummary];
    if (!run.length || !summary) { self.runActions = actions; return; }
    NSDictionary *card = SRCardForRule(self.cards, [self ruleIDForRun:run]);
    if (card) [actions addObject:@{@"kind": @"detail", @"title": @"查看本组执行详情",
        @"planID": self.planID ?: @"", @"ruleID": card[@"id"], @"runID": run}];
    NSString *phase = summary[@"phase"];
    if ([phase isEqual:SRRunPhaseRunning]) [actions addObject:@{@"kind": @"pause", @"title": @"暂停", @"runID": run}];
    else if ([phase isEqual:SRRunPhasePaused]) [actions addObject:@{@"kind": @"resume", @"title": @"继续未发", @"runID": run}];
    else if ([phase isEqual:SRRunPhaseSettling]) [actions addObject:@{@"title": @"收尾中 · 等待在途结果", @"enabled": @NO}];
    else [actions addObject:@{@"title": [NSString stringWithFormat:@"%@ · 结束于 %@", summary[@"phaseText"], summary[@"endedText"]], @"enabled": @NO}];
    self.runActions = actions;
}
/* The live run's rule is read from its durable row, never guessed from the
 * page's current selection. */
- (NSString *)ruleIDForRun:(NSString *)run {
    NSDictionary *summary = [self.store smallGroupRun:run account:self.account error:NULL];
    id rule = summary[@"rule_id"];
    return [rule isKindOfClass:NSString.class] ? rule : nil;
}
- (NSString *)phaseText {
    if (self.accountInvalid) return @"账号无法核对或已经改变";
    if (self.problem) return @"读取已停止";
    NSDictionary *summary = [self liveSummary];
    if (summary) return summary[@"phaseText"];
    if ([self.mode isEqual:SRHomeModePreview]) return @"有 1 条消息待处理";
    if ([self.mode isEqual:SRHomeModeConfirmed]) return @"内容已确认，可选择分组";
    if ([self.mode isEqual:SRHomeModePrepared]) return @"内容已捕获，尚未确认";
    if (self.recentRun) return @"最近内容已归档";
    return @"尚未捕获内容";
}
- (NSString *)progressText {
    NSDictionary *summary = [self liveSummary];
    if (!summary) return @"没有活动运行";
    return [NSString stringWithFormat:@"已处理 %@/%@ · 在途 %@", summary[@"processed"], summary[@"total"], summary[@"inflight"]];
}
- (NSString *)sourceCaptureText {
    if ([self.sourceCaptureStatus[@"state"] isEqual:@"preview"]) return @"已抓到 1 条，请先处理当前内容";
    if ([self.sourceCaptureStatus[@"state"] isEqual:@"waiting"]) return @"正在手动等待一条母群消息 · 到设置取消";
    switch ([self.sourceCaptureStatus[@"stopReason"] integerValue]) {
        case SRSourceCaptureStopImageTimeout: return @"图片资源等待超时 · 到设置重新等待";
        case SRSourceCaptureStopImageRejected: return @"图片捕获已停止 · 到设置查看诊断";
        case SRSourceCaptureStopReceiver: return @"等待已停止 · 到设置重新等待";
        default: return @"当前不监听 · 到设置手动等待一条";
    }
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (self.accountInvalid || self.problem) ? 1 : 4;
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.accountInvalid || self.problem) return 1;
    section = SRHomeModelSection(section);
    if (section == 0) return 3 + (NSInteger)self.runActions.count;
    if (section == 1) return 1;
    return (section == 2) ? 3 : 1;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.accountInvalid) return @"账号";
    if (self.problem) return @"读取已停止";
    return @[@"当前内容", @"监听与进度", @"转发分组", @"最近一次结果"][section];
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.accountInvalid) return @"当前账号无法核对或已经改变，旧内容已隐藏。请关闭后重新打开群同步。";
    if (self.problem) return @"本页不会创建、继续或重试发送任务。";
    section = SRHomeModelSection(section);
    if (section == 0) return @"持续监听暂未开放；目前可到设置手动等待一条。切后台后不会自动重开。";
    if (section == 1) return [self.mode isEqual:SRHomeModePreview] ?
        @"先核对内容和分组，再确认转发。忽略不会删除历史。" :
        @"修改设置只影响之后捕获的内容。";
    if (section == 2) return @"按分组顺序执行；不会自动开始下一组。";
    return @"最近一次结果只指向这一次运行，不代表其他分组，也不代表全部送达。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"operations-home"] ?:
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"operations-home"];
    path = [NSIndexPath indexPathForRow:path.row inSection:SRHomeModelSection(path.section)];
    SRStyleSettingsCell(cell); cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.text = nil; cell.detailTextLabel.text = nil; cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (self.accountInvalid) { cell.textLabel.text = @"账号无法核对或已经改变"; cell.detailTextLabel.text = @"旧内容已隐藏，不会执行任何操作"; return cell; }
    if (self.problem) {
        cell.textLabel.text = self.problem[@"title"];
        cell.detailTextLabel.text = self.problem[@"message"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (path.section == 0) {
        if (path.row == 0) { cell.textLabel.text = @"当前状态"; cell.detailTextLabel.text = [self phaseText]; return cell; }
        if (path.row == 1) { cell.textLabel.text = @"执行进度"; cell.detailTextLabel.text = [self progressText]; return cell; }
        if (path.row == 2 + (NSInteger)self.runActions.count) {
            cell.textLabel.text = @"源消息"; cell.detailTextLabel.text = [self sourceCaptureText];
            if (self.openSettings && !self.previewGeneration) {
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            return cell;
        }
        NSDictionary *action = self.runActions[(NSUInteger)(path.row - 2)] ?: @{};
        cell.textLabel.text = action[@"title"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        if (![action[@"enabled"] isEqual:@NO]) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        else cell.textLabel.textColor = UIColor.secondaryLabelColor;
        return cell;
    }
    if (path.section == 1) {
        if (path.row == 0) {
            if (self.previewGeneration) {
                cell.textLabel.text = @"转发分组";
                cell.detailTextLabel.text = [SRRunProjection excerptForEnvelope:self.envelope limit:180];
                cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
                cell.textLabel.textColor = SRSettingsAccent();
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                return cell;
            }
            cell.textLabel.text = self.envelope ? @"当前内容摘要" : @"当前内容";
            cell.detailTextLabel.text = self.envelope ? [SRRunProjection excerptForEnvelope:self.envelope limit:140] : @"暂无内容";
            if (self.envelope) { cell.selectionStyle = UITableViewCellSelectionStyleDefault; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
            return cell;
        }
        return cell;
    }
    if (path.section == 2) {
        if (path.row == 2) {
            cell.textLabel.text = @"消息库"; cell.detailTextLabel.text = @"已保存的文字和图片";
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        if (path.row == 1) {
            cell.textLabel.text = @"历史内容";
            cell.detailTextLabel.text = @"查看之前的内容、分组和执行记录";
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        NSDictionary *overview = self.overview ?: @{};
        NSUInteger groups = [overview[@"groups"] unsignedIntegerValue];
        cell.textLabel.text = groups ? @"分组概览" : @"分组概览 · 尚未建立分组";
        cell.detailTextLabel.text = groups ?
            [NSString stringWithFormat:@"%@ 个分组 · %@ 个目标群\n已处理 %@/%@ · %@ 个分组未开始",
                overview[@"groups"], overview[@"targets"], overview[@"processed"], overview[@"total"], overview[@"unstarted"]] :
            @"当前还没有可用分组。可在设置里配置目标分组，确认内容后本页才会出现冻结分组。";
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    BOOL hasRecent = self.recentRun != nil;
    cell.textLabel.text = hasRecent ? @"最近一次结果" : @"最近一次结果 · 暂无记录";
    if (hasRecent) {
        NSDictionary *summary = [SRRunProjection runSummary:self.recentRun];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n结束于 %@ · 已处理 %@/%@",
            summary[@"phaseText"], summary[@"endedText"], summary[@"processed"], summary[@"total"]];
    } else cell.detailTextLabel.text = @"这次内容还没有结束的运行记录。";
    if (hasRecent) { cell.selectionStyle = UITableViewCellSelectionStyleDefault; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    path = [NSIndexPath indexPathForRow:path.row inSection:SRHomeModelSection(path.section)];
    if (![self verified]) return;
    if (self.problem) { [self reload]; return; }
    if (path.section == 0 && path.row >= 2) {
        if (path.row == 2 + (NSInteger)self.runActions.count) {
            if (!self.previewGeneration) [self settingsPressed];
            return;
        }
        NSDictionary *action = self.runActions[(NSUInteger)(path.row - 2)] ?: @{};
        if ([action[@"enabled"] isEqual:@NO]) return;
        if ([action[@"kind"] isEqual:@"detail"]) {
            [self.navigationController pushViewController:SRCreateRunDetail(self.store, self.execution, self.account,
                self.verifyAccount, action[@"planID"], action[@"ruleID"], action[@"runID"]) animated:YES];
            return;
        }
        /* The row's own run travels with the tap: read back from the session
         * here would let a newer batch receive this page's command. */
        [self performLiveAction:action[@"kind"] runID:action[@"runID"]];
        return;
    }
    if (path.section == 1 && path.row == 0) {
        if (self.previewGeneration) {
            NSNumber *generation = self.previewGeneration;
            if (![self.capture previewSnapshotForAccount:self.account generation:generation]) { [self reload]; return; }
            [self.navigationController pushViewController:SRCreateCapturedForwarding(self.store, self.capture, self.account,
                generation, self.verifyAccount, self.execution) animated:YES];
            return;
        }
        if (self.envelope) SRPushContentViewer(self, self.store, self.envelope, self.verifyAccount);
        return;
    }
    if (path.section == 2) {
        if (path.row == 2) {
            [self.navigationController pushViewController:SRCreateLibraryList(self.store, self.account,
                self.verifyAccount, self.execution, nil) animated:YES];
            return;
        }
        if (path.row == 1) {
            /* A secondary, explicitly labelled route to the full plan history.
             * The group entry above never falls back to it. */
            [self.navigationController pushViewController:SRCreatePlanList(self.store, self.account,
                self.verifyAccount, self.execution) animated:YES];
            return;
        }
        /* The group entry is bound to this content's frozen plan; it never opens
         * the 全部计划历史 list. Without a plan it opens the read-only view of the
         * configuration frozen with this content. */
        if (self.previewGeneration) {
            NSNumber *generation = self.previewGeneration;
            if (![self.capture previewSnapshotForAccount:self.account generation:generation]) { [self reload]; return; }
            [self.navigationController pushViewController:SRCreateCapturedForwarding(self.store, self.capture, self.account,
                generation, self.verifyAccount, self.execution) animated:YES];
            return;
        }
        [self.navigationController pushViewController:SRCreateGroupList(self.store, self.execution, self.account,
            self.verifyAccount, self.planID, self.frozenConfiguration) animated:YES];
        return;
    }
    if (path.section == 3 && self.recentRun) {
        [self.navigationController pushViewController:SRCreateRunDetail(self.store, self.execution, self.account,
            self.verifyAccount, self.recentRunPlanID, self.recentRun[@"rule_id"], self.recentRun[@"id"]) animated:YES];
    }
}
/* Live pause/continue belongs to the run the tapped row was built for. The
 * page saved that identity with the action, so it is carried here instead of
 * being read back from the session: a batch that appeared after the section
 * was drawn must not receive this command. Missing, changed or no-longer-owned
 * identities only alert and refresh; no command is called. */
- (void)performLiveAction:(NSString *)kind runID:(NSString *)bound {
    if (![self verified]) {
        SRScreenAlert(self, @"操作未执行", @"当前账号无法核对或已经改变。"); [self reload]; return;
    }
    if (![bound isKindOfClass:NSString.class] || !bound.length) {
        SRScreenAlert(self, @"操作未执行", @"这一行没有记录批次，请使用刷新后的按钮。"); [self reload]; return;
    }
    if (![self.execution progressBelongsToCurrentAccount]) {
        SRScreenAlert(self, @"操作未执行", @"没有属于当前账号的活动运行。"); [self reload]; return;
    }
    NSString *mounted = self.execution.currentRunID;
    if (!mounted.length || ![mounted isEqual:bound]) {
        SRScreenAlert(self, @"操作未执行", @"当前批次已经变化，请使用刷新后的按钮。"); [self reload]; return;
    }
    NSDictionary *counts = self.execution.status[@"counts"];
    if ([kind isEqual:@"resume"] && [counts[@"submitting"] unsignedIntegerValue] > 0) {
        SRScreenAlert(self, @"暂不能继续", @"在途消息仍在收尾，等结果回来后再继续未发项。"); return;
    }
    NSError *error = nil; BOOL done = NO;
    if ([kind isEqual:@"pause"]) done = [self.execution pauseForAccount:self.account error:&error];
    else if ([kind isEqual:@"resume"]) done = [self.execution resumeRun:bound account:self.account error:&error];
    if (!done) SRScreenAlert(self, @"操作未执行", error.localizedDescription ?: @"当前状态不允许此操作，请刷新后重试。");
    [self reload];
    [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
}
- (void)settingsPressed {
    if (![self verified]) { SRScreenAlert(self, @"账号无法核对", @"当前账号无法核对或已经改变，请关闭后重新打开群同步。"); return; }
    if (self.openSettings) self.openSettings();
}
- (void)close {
    [self dismissViewControllerAnimated:YES completion:^{
        [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
    }];
}
@end

/* ------------------------------------------------------------------------ */
/* 分组列表                                                                  */
/* ------------------------------------------------------------------------ */

/* Rows come from one content's frozen plan. Search and filter re-project the
 * same array; they never touch the freeze and never change business state.
 * Without confirmed content the configuration frozen with the content that was
 * handed in is shown read-only; the saved settings are a fallback only when the
 * page has no content at all. */
@interface SRGroupListScreen : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, strong) SRSmallGroupSession *execution;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
@property(nonatomic, copy, nullable) NSString *planID;
/* The configuration frozen with the content this page was opened for. It is
 * already a snapshot: the page never re-reads it from the settings row. */
@property(nonatomic, copy, nullable) NSDictionary *configuration;
@property(nonatomic, strong) NSMutableArray *allRows;
@property(nonatomic, strong) NSArray *rows;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic, copy) NSString *filter;
@property(nonatomic, copy, nullable) NSDictionary *envelope;
@property(nonatomic, copy, nullable) NSDictionary *problem;
@property(nonatomic) BOOL accountInvalid;
@property(nonatomic) BOOL readOnly;
@end

@implementation SRGroupListScreen
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"分组";
    SRStyleSettingsTable(self);
    self.filter = SRGroupFilterAll;
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchResultsUpdater = self;
    self.search.searchBar.placeholder = @"搜索分组或群";
    self.navigationItem.searchController = self.search;
    self.definesPresentationContext = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged:)
        name:SRRelayStateChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged:)
        name:@"andyz.syncrelay.smallGroupChanged" object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (void)stateChanged:(__unused NSNotification *)notification { if (self.viewIfLoaded.window) [self reload]; }
- (void)updateSearchResultsForSearchController:(__unused UISearchController *)searchController { [self applyFilter]; }
- (BOOL)verified {
    @try { return self.verifyAccount && self.verifyAccount(); }
    @catch (__unused id exception) { return NO; }
}
- (void)reload {
    self.allRows = [NSMutableArray array]; self.rows = @[]; self.problem = nil;
    self.envelope = nil; self.readOnly = NO;
    self.accountInvalid = ![self verified];
    if (self.accountInvalid) { [self.tableView reloadData]; return; }
    NSError *error = nil;
    if (self.planID.length) {
        NSDictionary *plan = [self.store plan:self.planID account:self.account error:&error];
        NSArray *cards = plan ? [self.store ruleCardsForPlan:self.planID account:self.account error:&error] : nil;
        if (!plan || !cards) {
            self.problem = @{@"title": @"读取失败", @"message": error.localizedDescription ?: @"无法读取该内容的分组。"};
            [self.tableView reloadData]; return;
        }
        self.envelope = SRDictionary(plan[@"snapshot"]);
        [self.allRows addObjectsFromArray:[SRRunProjection groupRowsForCards:
            SRCardsWithCancellation(self.store, self.account, cards) targetLimit:self.store.forwardingTargetLimit]];
    } else {
        /* No confirmed content: the content's frozen configuration can be
         * inspected, but every row stays non-executable. The saved settings are
         * read only when this page was opened without any content. */
        self.readOnly = YES;
        NSDictionary *configuration = self.configuration;
        if (!configuration) configuration = [self.store configurationForAccount:self.account error:&error];
        if (!configuration) {
            self.problem = @{@"title": @"读取失败", @"message": error.localizedDescription ?: @"无法读取已保存的分组配置。"};
            [self.tableView reloadData]; return;
        }
        [self.allRows addObjectsFromArray:[SRRunProjection groupRowsForConfiguration:configuration targetLimit:self.store.forwardingTargetLimit]];
    }
    [self applyFilter];
}
- (void)applyFilter {
    self.rows = [SRRunProjection rows:self.allRows matchingText:self.search.searchBar.text filter:self.filter];
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (self.accountInvalid || self.problem) ? 1 : 2;
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.accountInvalid || self.problem) return 1;
    if (section == 0) return 2;
    return self.rows.count ? (NSInteger)self.rows.count : 1;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.accountInvalid) return @"账号";
    if (self.problem) return @"读取已停止";
    return section == 1 ? (self.readOnly ? @"分组（只读）" : @"分组") : nil;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.accountInvalid) return @"当前账号无法核对或已经改变，旧分组已隐藏。请返回重新读取账号。";
    if (self.problem) return @"本页不会创建、继续或重试发送任务。";
    if (section == 0) return self.planID.length ?
        @"分组来自该内容的冻结计划；搜索和筛选只改变本页显示，不修改冻结数据。" :
        (self.configuration ? @"没有已确认内容：这里只显示该内容捕获时冻结的配置，之后修改设置不会改变它，也不能发送。" :
                              @"没有已确认内容：这里只显示已保存配置的分组和群名单，不能发送。");
    return self.readOnly ?
        @"点开分组只查看该内容冻结的目标群，不发送、不创建计划；搜索和筛选只改变本页显示。" :
        @"开始、暂停、继续和取消都在分组详情里；每次操作都会重新核对账号、分组和批次。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"group-list"] ?:
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"group-list"];
    SRStyleSettingsCell(cell); cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.text = nil; cell.detailTextLabel.text = nil; cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (self.accountInvalid) { cell.textLabel.text = @"账号无法核对或已经改变"; cell.detailTextLabel.text = @"旧分组已隐藏"; return cell; }
    if (self.problem) {
        cell.textLabel.text = self.problem[@"title"];
        cell.detailTextLabel.text = self.problem[@"message"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if (path.section == 0) {
        if (path.row == 0) {
            cell.textLabel.text = self.readOnly ? @"尚未确认内容" : @"当前内容";
            if (self.readOnly) {
                cell.detailTextLabel.text = self.configuration ?
                    @"该内容捕获时冻结的配置；确认内容后才会有可执行的冻结分组" :
                    @"已保存配置的分组与群名单；确认内容后才会有可执行的冻结分组";
                return cell;
            }
            NSString *group = [self.envelope[@"group"] isKindOfClass:NSString.class] ? self.envelope[@"group"] : @"未记录";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 母群 %@\n观察 %@ · 抓取完成 %@",
                [SRRunProjection typeTextForEnvelope:self.envelope], group,
                [SRRunProjection observedTimeTextForEnvelope:self.envelope],
                [SRRunProjection frozenTimeTextForEnvelope:self.envelope]];
            return cell;
        }
        cell.textLabel.text = @"筛选";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 显示 %lu / %lu 组",
            [SRRunProjection titleForFilter:self.filter], (unsigned long)self.rows.count, (unsigned long)self.allRows.count];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (!self.rows.count) {
        cell.textLabel.text = self.allRows.count ? @"当前筛选没有匹配的分组" : @"还没有分组";
        cell.detailTextLabel.text = self.allRows.count ? @"换一个筛选或清空搜索。" :
            (self.readOnly ? @"可返回设置页配置目标分组。" : @"该内容计划里没有分组。");
        return cell;
    }
    NSDictionary *row = self.rows[(NSUInteger)path.row];
    cell.textLabel.text = row[@"name"];
    NSMutableString *detail = [NSMutableString stringWithFormat:@"%lu 个群 · %@\n%@",
        (unsigned long)[row[@"targetCount"] unsignedIntegerValue], row[@"progressText"], row[@"statusText"]];
    if ([row[@"blockedText"] isKindOfClass:NSString.class]) [detail appendFormat:@"\n%@", row[@"blockedText"]];
    cell.detailTextLabel.text = detail;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (![self verified]) return;
    if (self.problem) { [self reload]; return; }
    if (path.section == 0) {
        if (path.row == 1) [self chooseFilter];
        return;
    }
    if (path.row >= (NSInteger)self.rows.count) return;
    NSDictionary *row = self.rows[(NSUInteger)path.row];
    /* Without a confirmed plan there is nothing to operate, but the group can
     * still be inspected. The row already carries the projected name, targets
     * and target names from the content's frozen configuration, so the viewer
     * is built from it directly: no plan is invented and the placeholder-only
     * nil-plan detail page is never opened. */
    if (self.readOnly) { [self showReadOnlyGroup:row]; return; }
    /* Carry the run this row actually displayed. Passing nil would make the
     * detail page believe it represented "no run" and immediately go stale for
     * a group that has already started. */
    id runID = [row[@"runID"] isKindOfClass:NSString.class] ? row[@"runID"] : nil;
    UIViewController *detail = SRCreateRunDetail(self.store, self.execution, self.account, self.verifyAccount,
        self.planID, row[@"identifier"], runID);
    [self.navigationController pushViewController:detail animated:YES];
}
/* Read-only target list of one group. It reuses the existing text viewer, so
 * the account is verified by the same callback as every other page, and it
 * displays only what this row was projected with: no store read, no host
 * lookup, no image access and no command. */
- (void)showReadOnlyGroup:(NSDictionary *)row {
    NSString *name = [row[@"name"] isKindOfClass:NSString.class] && [row[@"name"] length] ? row[@"name"] : @"未命名分组";
    NSArray *targets = [row[@"targets"] isKindOfClass:NSArray.class] ? row[@"targets"] : @[];
    NSArray *names = [row[@"targetNames"] isKindOfClass:NSArray.class] ? row[@"targetNames"] : @[];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSUInteger index = 0; index < targets.count; index++) {
        NSString *identifier = [targets[index] isKindOfClass:NSString.class] ? targets[index] : @"";
        NSString *label = (index < names.count && [names[index] isKindOfClass:NSString.class]) ? names[index] : nil;
        [lines addObject:label.length ? [NSString stringWithFormat:@"%lu. %@（%@）", (unsigned long)(index + 1), label, identifier]
                                      : [NSString stringWithFormat:@"%lu. %@", (unsigned long)(index + 1), identifier]];
    }
    NSString *body = [NSString stringWithFormat:@"%@\n\n本组共 %lu 个目标群，按冻结顺序：\n\n%@\n\n内容还没有确认：这里只显示该内容冻结的目标，不能发送。",
        name, (unsigned long)targets.count,
        lines.count ? [lines componentsJoinedByString:@"\n"] : @"（没有可显示的目标群）"];
    SRSourceTextScreen *viewer = [[SRSourceTextScreen alloc] init];
    viewer.title = @"分组目标（只读）";
    viewer.body = body;
    viewer.verifyAccount = self.verifyAccount;
    [self.navigationController pushViewController:viewer animated:YES];
}
/* Changing the filter only changes what this page shows. */
- (void)chooseFilter {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"筛选分组" message:@"只改变本页显示，不修改冻结计划。" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    for (NSString *identifier in [SRRunProjection filterIdentifiers]) {
        NSString *title = [SRRunProjection titleForFilter:identifier];
        if ([identifier isEqual:self.filter]) title = [title stringByAppendingString:@"（当前）"];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            weakSelf.filter = identifier; [weakSelf applyFilter];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    SRScreenPresent(self, menu);
}
@end

/* ------------------------------------------------------------------------ */
/* 执行详情                                                                  */
/* ------------------------------------------------------------------------ */

/* Bound to one account + one frozen plan + one rule + one run. The page keeps
 * the identity it displayed and re-reads the durable row before every command,
 * so a stale page or a late confirmation cannot operate a replaced run. */
@interface SRRunDetailScreen : UITableViewController
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, strong) SRSmallGroupSession *execution;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
@property(nonatomic, copy, nullable) NSString *planID;
@property(nonatomic, copy, nullable) NSString *ruleID;
@property(nonatomic, copy, nullable) NSString *runID;
@property(nonatomic, copy) NSArray *targetIdentifiers;
@property(nonatomic, strong) NSDictionary *card;
@property(nonatomic, strong) NSDictionary *summary;
@property(nonatomic, copy) NSDictionary *envelope;
@property(nonatomic, copy) NSArray *actionRows;
@property(nonatomic, copy, nullable) NSDictionary *problem;
@property(nonatomic) BOOL accountInvalid;
@property(nonatomic) BOOL replaced;
@end

@implementation SRRunDetailScreen
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"执行详情";
    SRStyleSettingsTable(self);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged:)
        name:SRRelayStateChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged:)
        name:@"andyz.syncrelay.smallGroupChanged" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hideContent)
        name:UIApplicationWillResignActiveNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (void)stateChanged:(__unused NSNotification *)notification { if (self.viewIfLoaded.window) [self reload]; }
- (void)hideContent {
    self.envelope = nil; self.card = nil; self.summary = nil; self.actionRows = @[];
    self.targetIdentifiers = @[]; self.accountInvalid = YES;
    [self.tableView reloadData];
}
- (BOOL)verified {
    @try { return self.verifyAccount && self.verifyAccount(); }
    @catch (__unused id exception) { return NO; }
}
- (void)reload {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) { [self hideContent]; return; }
    self.card = nil; self.summary = nil; self.actionRows = @[]; self.problem = nil;
    self.envelope = nil;
    self.targetIdentifiers = @[]; self.replaced = NO;
    self.accountInvalid = ![self verified];
    if (self.accountInvalid || !self.planID.length) { [self buildActions]; [self.tableView reloadData]; return; }
    NSError *error = nil;
    NSDictionary *plan = [self.store plan:self.planID account:self.account error:&error];
    if (!plan) {
        self.problem = @{@"title": @"内容读取失败", @"message": error.localizedDescription ?: @"请返回重新打开这条内容。"};
        [self.tableView reloadData]; return;
    }
    self.envelope = SRDictionary(plan[@"snapshot"]);
    NSArray *cards = [self.store ruleCardsForPlan:self.planID account:self.account error:&error];
    if (!cards) {
        self.problem = @{@"title": @"读取失败", @"message": error.localizedDescription ?: @"无法读取该分组的状态。"};
        [self.tableView reloadData]; return;
    }
    NSDictionary *card = SRCardForRule(cards, self.ruleID);
    if (!card) {
        self.problem = @{@"title": @"分组不可用", @"message": @"该分组已不在当前冻结计划中，请返回分组列表重新进入。"};
        [self.tableView reloadData]; return;
    }
    NSMutableDictionary *mutable = [card mutableCopy];
    NSDictionary *run = SRRunWithCancellation(self.store, self.account, SRDictionary(card[@"latestRun"]));
    mutable[@"latestRun"] = run ?: (id)NSNull.null;
    self.card = mutable;
    NSString *currentRunID = [run[@"id"] isKindOfClass:NSString.class] ? run[@"id"] : nil;
    /* The page keeps the identity it displayed: a run that appeared after a
     * "no run" page, or a run that is gone or changed after a bound page, makes
     * this page stale. It never switches to the run it did not display. */
    self.replaced = [SRRunProjection pageIsStaleForBoundRun:self.runID currentRunID:currentRunID];
    // A stale page must not present the other run's numbers as its own.
    self.summary = (run && !self.replaced) ? [SRRunProjection runSummary:run] : nil;
    self.title = self.summary ? @"执行进度" : @"转发核对";
    self.targetIdentifiers = [self loadTargetIdentifiers];
    [self buildActions];
    [self.tableView reloadData];
}
/* The ordered target identifiers of this group, straight from the frozen plan.
 * No preview call is made here, so listing the scope neither re-validates an
 * image asset nor touches an experiment state. */
- (NSArray *)loadTargetIdentifiers {
    return [self.card[@"targetIdentifiers"] isKindOfClass:NSArray.class] ?
        self.card[@"targetIdentifiers"] : @[];
}
- (NSDictionary *)currentRun { return SRDictionary(self.card[@"latestRun"]); }
/* A read-only list of this group's own batches. The old plan page used to own
 * this route inside its command menu; it is kept here instead so removing that
 * menu does not drop the history. It reads historyForRule: and never creates,
 * resumes or ends a run. */
- (NSArray *)historyActions {
    if (![self.ruleID isKindOfClass:NSString.class] || !self.ruleID.length) return @[];
    return @[@{@"kind": @"history", @"title": @"查看本组历史批次（只读）", @"enabled": @YES}];
}
- (void)buildActions {
    NSMutableArray *actions = [NSMutableArray array];
    if (!self.planID.length || self.problem) { self.actionRows = @[]; return; }
    /* Stale is decided before any active branch: a page whose run appeared,
     * vanished or changed offers no start, pause, continue, cancel or end. */
    if (self.replaced) {
        [actions addObject:@{@"title": self.runID.length ?
            @"本页记录的批次已不在或已被替换，页面不再提供任何操作；请返回分组列表重新进入。" :
            @"本页打开时还没有批次，之后已出现新批次，页面不再提供任何操作；请返回分组列表重新进入。",
            @"enabled": @NO}];
        self.actionRows = actions;
        return;
    }
    NSDictionary *card = self.card ?: @{};
    NSDictionary *run = [self currentRun];
    if (!run) {
        NSString *blocked = nil;
        NSUInteger count = [card[@"targetCount"] unsignedIntegerValue], limit = self.store.forwardingTargetLimit;
        if (count > limit) blocked = SRTargetLimitMessage(count, limit);
        else if (![card[@"initialUnlocked"] isEqual:@YES]) blocked = @"等待前序分组结束。";
        else if ([card[@"accountOccupied"] isEqual:@YES]) blocked = @"账号仍有活动批次，不能开始另一条。";
        else if (!self.execution) blocked = @"当前没有可用的执行会话。";
        if (blocked) [actions addObject:@{@"title": blocked, @"enabled": @NO}];
        else [actions addObject:@{@"kind": @"start", @"title": @"开始转发本组", @"enabled": @YES}];
        [actions addObjectsFromArray:[self historyActions]];
        self.actionRows = actions;
        return;
    }
    NSString *runID = [run[@"id"] isKindOfClass:NSString.class] ? run[@"id"] : @"";
    NSString *phase = self.summary[@"phase"];
    BOOL owns = self.execution && [self.execution progressBelongsToCurrentAccount] &&
        [self.execution.currentRunID isEqual:runID];
    if ([SRRunProjection phaseIsActive:phase]) {
        if ([phase isEqual:SRRunPhaseRunning] && owns)
            [actions addObject:@{@"kind": @"pause", @"title": @"暂停", @"runID": runID, @"enabled": @YES}];
        if ([phase isEqual:SRRunPhasePaused])
            [actions addObject:@{@"kind": @"resume", @"title": @"继续未发（只发未尝试项）", @"runID": runID, @"enabled": @YES}];
        if ([phase isEqual:SRRunPhaseSettling])
            [actions addObject:@{@"title": @"收尾中 · 等待在途结果，暂不能继续或暂停", @"enabled": @NO}];
        [actions addObject:@{@"kind": @"cancel", @"title": @"取消本组剩余发送", @"runID": runID, @"destructive": @YES, @"enabled": @YES}];
        [actions addObject:@{@"kind": @"end", @"title": @"结束这次执行（不重发）", @"runID": runID, @"destructive": @YES, @"enabled": @YES}];
    }
    [actions addObject:@{@"kind": @"exceptions", @"title": @"查看异常与未发项", @"runID": runID, @"enabled": @YES}];
    [actions addObjectsFromArray:[self historyActions]];
    self.actionRows = actions;
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    if (self.accountInvalid || self.problem || !self.planID.length) return 1;
    return self.summary ? 4 : 2;
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.accountInvalid || self.problem || !self.planID.length) return 1;
    if (section == 0) return 3;
    if (section == 1) return self.summary ? 6 : (NSInteger)self.actionRows.count;
    if (section == 2) return 2;
    return (NSInteger)self.actionRows.count;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.accountInvalid) return @"账号";
    if (self.problem) return @"读取已停止";
    if (!self.planID.length) return @"分组";
    NSArray *titles = self.summary ? @[@"本次分组", @"状态与统计", @"时间", @"操作"] : @[@"本次分组", @"操作"];
    return titles[section];
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.accountInvalid) return @"当前账号无法核对或已经改变，本页已失去操作资格。";
    if (self.problem) return @"本页不会创建、继续或重试发送任务。";
    if (!self.planID.length) return @"尚未确认内容：只能查看分组名称和目标群，不能发送。";
    NSInteger last = self.summary ? 3 : 1;
    if (section == last) return @"开始只适用于已确认且门禁允许的分组；继续只发送原批次未尝试项；取消或结束后不会自动开始下一组。";
    if (section == 1) return @"处理完成不等于全部送达：已提交、已确认送达、失败和结果未知分开统计。";
    if (section == 2) return @"时间按设备本地时区显示；没有持久化时间时显示未记录，不用页面打开时间代替。";
    return @"本次详情只针对这一分组和这一批次，其他分组或其他批次的数据不会混入。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"run-detail"] ?:
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"run-detail"];
    SRStyleSettingsCell(cell); cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.text = nil; cell.detailTextLabel.text = nil; cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (self.accountInvalid) { cell.textLabel.text = @"账号无法核对或已经改变"; cell.detailTextLabel.text = @"本页不会再执行任何操作"; return cell; }
    if (self.problem) {
        cell.textLabel.text = self.problem[@"title"];
        cell.detailTextLabel.text = self.problem[@"message"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if (!self.planID.length) {
        cell.textLabel.text = @"尚未确认内容";
        cell.detailTextLabel.text = @"这里没有可执行的批次。返回分组列表只能查看已保存配置的分组和群名单。";
        return cell;
    }
    NSDictionary *card = self.card ?: @{};
    if (path.section == 0) {
        if (path.row == 0) {
            cell.textLabel.text = @"分组名称";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %lu 个目标群",
                card[@"name"] ?: @"未记录", (unsigned long)[card[@"targetCount"] unsignedIntegerValue]];
            return cell;
        }
        if (path.row == 1) {
            cell.textLabel.text = @"目标范围";
            cell.detailTextLabel.text = self.targetIdentifiers.count ?
                [NSString stringWithFormat:@"%lu 个群（点开查看冻结的目标标识）", (unsigned long)self.targetIdentifiers.count] :
                [NSString stringWithFormat:@"%lu 个群（冻结范围；标识当前不可读取）", (unsigned long)[card[@"targetCount"] unsignedIntegerValue]];
            if (self.targetIdentifiers.count) {
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            return cell;
        }
        cell.textLabel.text = self.replaced ? @"页面已失效" : @"本次转发内容";
        cell.detailTextLabel.text = self.replaced ? @"分组批次已经改变，请返回重新核对。" :
            [SRRunProjection excerptForEnvelope:self.envelope limit:180];
        if (!self.replaced && self.envelope) {
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }
    if (path.section == 1) {
        if (!self.summary) {
            NSDictionary *action = path.row < (NSInteger)self.actionRows.count ?
                self.actionRows[(NSUInteger)path.row] : @{};
            cell.textLabel.text = action[@"title"];
            if (![action[@"enabled"] isEqual:@NO]) {
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.textLabel.textColor = [action[@"destructive"] isEqual:@YES] ? UIColor.systemRedColor : UIColor.labelColor;
                if ([action[@"kind"] isEqual:@"start"]) {
                    cell.textLabel.textColor = SRSettingsAccent();
                    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
                }
            } else cell.textLabel.textColor = UIColor.secondaryLabelColor;
            return cell;
        }
        NSArray *lines = [SRRunProjection countLinesForSummary:self.summary];
        if (path.row == 0) { cell.textLabel.text = @"展示状态"; cell.detailTextLabel.text = self.summary[@"phaseText"]; return cell; }
        if (path.row == 1) {
            cell.textLabel.text = @"原始状态（持久化值）";
            cell.detailTextLabel.text = [self.summary[@"state"] isKindOfClass:NSString.class] ? self.summary[@"state"] : @"未记录";
            return cell;
        }
        if (path.row == 2) {
            cell.textLabel.text = @"进度";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"已处理 %@/%@ · 在途 %@",
                self.summary[@"processed"], self.summary[@"total"], self.summary[@"inflight"]];
            return cell;
        }
        NSArray *groups = @[@[@0, @1, @6], @[@2, @3], @[@4, @5]][path.row - 3];
        NSMutableArray *parts = [NSMutableArray array];
        for (NSNumber *index in groups) [parts addObject:lines[index.unsignedIntegerValue]];
        cell.textLabel.text = path.row == 3 ? @"未尝试与收尾" : (path.row == 4 ? @"已提交与送达" : @"失败与未知");
        cell.detailTextLabel.text = [parts componentsJoinedByString:@" · "];
        return cell;
    }
    if (path.section == 2) {
        cell.textLabel.text = path.row == 0 ? @"开始时间" : @"结束时间";
        cell.detailTextLabel.text = path.row == 0 ? self.summary[@"startedText"] : self.summary[@"endedText"];
        return cell;
    }
    NSDictionary *action = path.row < (NSInteger)self.actionRows.count ? self.actionRows[(NSUInteger)path.row] : @{};
    cell.textLabel.text = action[@"title"];
    if (![action[@"enabled"] isEqual:@NO]) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.textColor = [action[@"destructive"] isEqual:@YES] ? UIColor.systemRedColor : UIColor.labelColor;
    } else cell.textLabel.textColor = UIColor.secondaryLabelColor;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (![self verified]) return;
    if (self.problem) { [self reload]; return; }
    if (path.section == 0 && path.row == 2 && !self.replaced && self.envelope) {
        SRPushContentViewer(self, self.store, self.envelope, self.verifyAccount); return;
    }
    if (path.section == 0 && path.row == 1 && self.targetIdentifiers.count) {
        SRSourceTextScreen *viewer = [[SRSourceTextScreen alloc] init];
        viewer.title = @"目标群标识（只读）";
        viewer.body = [NSString stringWithFormat:@"本组共 %lu 个目标群，按冻结顺序：\n\n%@\n\n本页只显示标识，不发送任何消息。",
            (unsigned long)self.targetIdentifiers.count, [self.targetIdentifiers componentsJoinedByString:@"\n"]];
        viewer.verifyAccount = self.verifyAccount;
        [self.navigationController pushViewController:viewer animated:YES];
        return;
    }
    /* The action rows live in section 3 when the run sections are shown and in
     * section 1 for a group that has not started yet. Any other row is not an
     * action and must not dispatch one. */
    NSInteger index = -1;
    if (self.summary) { if (path.section == 3) index = path.row; }
    else if (path.section == 1) index = path.row;
    if (index < 0 || index >= (NSInteger)self.actionRows.count) return;
    NSDictionary *action = self.actionRows[(NSUInteger)index];
    if ([action[@"enabled"] isEqual:@NO]) return;
    NSString *kind = action[@"kind"];
    NSString *run = [action[@"runID"] isKindOfClass:NSString.class] ? action[@"runID"] : nil;
    if ([kind isEqual:@"start"]) [self startPressed];
    else if ([kind isEqual:@"pause"]) [self pausePressed:run];
    else if ([kind isEqual:@"resume"]) [self resumePressed:run];
    else if ([kind isEqual:@"cancel"]) [self cancelPressed:run];
    else if ([kind isEqual:@"end"]) [self endPressed:run];
    else if ([kind isEqual:@"exceptions"] && run.length) {
        [self.navigationController pushViewController:SRCreateRunExceptions(self.store, self.account,
            self.verifyAccount, run) animated:YES];
    } else if ([kind isEqual:@"history"]) [self historyPressed];
}
/* Read-only: historyForRule: is a paged read of this group's batches. It
 * neither starts nor resumes anything, so no identity gate beyond the page's
 * own account verification is needed. */
- (void)historyPressed {
    SRRecordScreen *history = [[SRRecordScreen alloc] initWithStyle:UITableViewStyleGrouped];
    history.kind = SRRecordHistory; history.store = self.store; history.account = self.account;
    history.verifyAccount = self.verifyAccount; history.identifier = self.ruleID;
    history.title = @"本组历史批次";
    [self.navigationController pushViewController:history animated:YES];
}
#pragma mark - commands

/* Re-reads the durable row right before a command. A stale page, a changed
 * account or a run that is no longer the one displayed all refuse. */
- (BOOL)revalidateRun:(NSString *)runID {
    if (![self verified]) { SRScreenAlert(self, @"操作未执行", @"当前账号无法核对或已经改变。"); return NO; }
    if (!runID.length) { SRScreenAlert(self, @"操作未执行", @"没有可操作的批次。"); return NO; }
    if (self.replaced) {
        SRScreenAlert(self, @"操作未执行", self.runID.length ?
            @"本页记录的批次已不在或已被替换，请返回分组列表重新进入。" :
            @"本页打开时还没有批次，之后已出现新批次，请返回分组列表重新进入。");
        return NO;
    }
    /* The command must target the run this page displayed, not merely some run
     * that still exists under the same account, plan and group. */
    if (self.runID.length && ![self.runID isEqual:runID]) {
        SRScreenAlert(self, @"操作未执行", @"这次操作不属于本页记录的批次，请返回重新进入。"); return NO;
    }
    NSArray *cards = [self.store ruleCardsForPlan:self.planID account:self.account error:NULL];
    NSDictionary *run = SRDictionary(SRCardForRule(cards, self.ruleID)[@"latestRun"]);
    if (!run || ![run[@"id"] isEqual:runID]) {
        SRScreenAlert(self, @"操作未执行", @"这次运行已结束、被替换或不属于当前账号，请刷新后重试。");
        return NO;
    }
    return YES;
}
- (void)finish {
    [self reload];
    [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
}
- (void)showError:(NSString *)title error:(NSError *)error fallback:(NSString *)fallback {
    SRScreenAlert(self, title, error.localizedDescription ?: fallback);
}
- (void)startPressed {
    if (![self verified]) { SRScreenAlert(self, @"操作未执行", @"当前账号无法核对或已经改变。"); return; }
    /* A stale page never starts anything, even if the store would now accept it:
     * the run it would create is not the one this page was opened for. */
    if (self.replaced) {
        SRScreenAlert(self, @"操作未执行", self.runID.length ?
            @"本页记录的批次已不在或已被替换，请返回分组列表重新进入。" :
            @"本页打开时还没有批次，之后已出现新批次，请返回分组列表重新进入。");
        return;
    }
    if (!self.execution) { SRScreenAlert(self, @"操作未执行", @"当前没有可用的执行会话。"); return; }
    /* Snapshot the identity when the user taps, then confirm once. */
    NSString *rule = [self.ruleID copy];
    NSString *account = [self.account copy];
    NSArray *cards = [self.store ruleCardsForPlan:self.planID account:account error:NULL];
    NSDictionary *card = SRCardForRule(cards, rule);
    if (!card || [card[@"latestRun"] isKindOfClass:NSDictionary.class]) {
        [self reload]; SRScreenAlert(self, @"还不能开始", @"该分组的状态已经改变，请查看刷新后的详情。"); return;
    }
    NSUInteger count = [card[@"targetCount"] unsignedIntegerValue], limit = self.store.forwardingTargetLimit;
    if (count > limit) {
        SRScreenAlert(self, @"还不能开始", SRTargetLimitMessage(count, limit)); return;
    }
    if (![card[@"initialUnlocked"] isEqual:@YES]) { SRScreenAlert(self, @"还不能开始", @"前序分组尚未结束。"); return; }
    if ([card[@"accountOccupied"] isEqual:@YES]) { SRScreenAlert(self, @"还不能开始", @"账号仍有活动批次，不能开始另一条。"); return; }
    NSError *error = nil;
    NSDictionary *preview = [self.store smallGroupRulePreview:rule account:account error:&error];
    if (!preview) { [self showError:@"还不能开始" error:error fallback:@"当前状态不允许开始。"]; return; }
    NSArray *targets = [preview[@"targets"] isKindOfClass:NSArray.class] ? preview[@"targets"] : @[];
    NSString *risk = targets.count > 100 ? @"\n超过 100 个群有风控风险，建议先用更少的群验证。" : @"";
    NSString *message = [NSString stringWithFormat:
        @"将向这 %lu 个群串行发送已确认的 %@ 消息：\n%@\n\n每次结果处理后再等待 %@–%@ 秒；不会自动接下一条。保持微信前台，测试时可以暂停。已尝试但结果未知的群不自动重发。%@",
        (unsigned long)targets.count, [SRRunProjection typeTextForEnvelope:preview[@"source"]],
        [targets componentsJoinedByString:@"\n"], preview[@"minimum"], preview[@"maximum"], risk];
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"开始真实转发？" message:message preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"开始这条分组" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf startConfirmedRule:rule account:account];
    }]];
    SRScreenPresent(self, confirm);
}
/* A late confirmation proves the same account, that this page still owns the
 * group, and that the group is still unstarted. The confirmation can sit on
 * screen while another entry starts a run, so the frozen card is re-read here
 * and every start gate is re-checked before the command is issued. */
- (void)startConfirmedRule:(NSString *)rule account:(NSString *)account {
    if (![self verified]) {
        SRScreenAlert(self, @"操作未执行", @"当前账号无法核对或已经改变。");
        [self finish]; return;
    }
    if (![account isEqual:self.account]) {
        SRScreenAlert(self, @"操作未执行", @"页面账号与确认账号不一致。");
        [self finish]; return;
    }
    if (self.replaced) {
        SRScreenAlert(self, @"操作未执行", @"本页记录的批次已改变，请返回分组列表重新进入。");
        [self finish]; return;
    }
    /* Re-read the frozen plan for this account: a card that vanished means the
     * group no longer belongs here, and a card that now has any run means the
     * confirmation arrived too late to create this batch. */
    NSArray *cards = [self.store ruleCardsForPlan:self.planID account:account error:NULL];
    NSDictionary *card = SRCardForRule(cards, self.ruleID);
    if (!card) {
        SRScreenAlert(self, @"还不能开始", @"该分组已不在当前冻结计划中，请返回分组列表重新进入。");
        [self finish]; return;
    }
    if ([card[@"latestRun"] isKindOfClass:NSDictionary.class]) {
        SRScreenAlert(self, @"还不能开始", @"确认期间该分组已出现批次，本次不会开始；请查看刷新后的详情。");
        [self finish]; return;
    }
    NSUInteger count = [card[@"targetCount"] unsignedIntegerValue], limit = self.store.forwardingTargetLimit;
    if (count > limit) {
        SRScreenAlert(self, @"还不能开始", SRTargetLimitMessage(count, limit));
        [self finish]; return;
    }
    if (![card[@"initialUnlocked"] isEqual:@YES]) {
        SRScreenAlert(self, @"还不能开始", @"前序分组尚未结束。");
        [self finish]; return;
    }
    if ([card[@"accountOccupied"] isEqual:@YES]) {
        SRScreenAlert(self, @"还不能开始", @"账号仍有活动批次，不能开始另一条。");
        [self finish]; return;
    }
    NSError *error = nil;
    if (![self.store smallGroupRulePreview:rule account:account error:&error]) {
        [self showError:@"操作未执行" error:error fallback:@"该分组现在不能开始。"];
        [self finish]; return;
    }
    if (![self.execution startRule:rule account:account error:&error]) {
        [self showError:@"开始未执行" error:error fallback:@"当前环境或账号不允许开始。"];
        [self finish];
        return;
    }
    /* This page created the run, so it may adopt the identifier it just got and
     * keep operating that batch. No other path writes self.runID. */
    NSString *created = self.execution.currentRunID;
    if (created.length) self.runID = created;
    [self finish];
}
- (void)pausePressed:(NSString *)runID {
    if (![self revalidateRun:runID]) return;
    if (![self.execution.currentRunID isEqual:runID] || ![self.execution progressBelongsToCurrentAccount]) {
        SRScreenAlert(self, @"操作未执行", @"当前会话没有挂载这一批次，旧页面不能暂停它。"); return;
    }
    NSError *error = nil;
    if (![self.execution pauseForAccount:self.account error:&error])
        [self showError:@"暂停未执行" error:error fallback:@"当前状态不允许暂停。"];
    [self finish];
}
- (void)resumePressed:(NSString *)runID {
    if (![self revalidateRun:runID]) return;
    NSDictionary *counts = self.summary[@"counts"];
    if ([counts[@"submitting"] unsignedIntegerValue] > 0) {
        SRScreenAlert(self, @"暂不能继续", @"在途消息仍在收尾，等结果回来后再继续未发项。"); return;
    }
    NSError *error = nil;
    if (![self.execution resumeRun:runID account:self.account error:&error])
        [self showError:@"继续未执行" error:error fallback:@"当前状态不允许继续。"];
    [self finish];
}
- (void)cancelPressed:(NSString *)runID {
    if (![self revalidateRun:runID]) return;
    NSString *account = [self.account copy];
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"取消本组剩余发送？"
        message:@"尚未发送的目标将取消；已提交的消息无法撤回，在途消息仍可能发送完成。其他分组不会自动开始。"
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"继续发送" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消本组" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf cancelConfirmedRun:runID account:account];
    }]];
    SRScreenPresent(self, confirm);
}
- (void)cancelConfirmedRun:(NSString *)runID account:(NSString *)account {
    if (![self verified] || ![account isEqual:self.account]) {
        SRScreenAlert(self, @"操作未执行", @"当前账号无法核对或已经改变。"); return;
    }
    if (![self revalidateRun:runID]) return;
    NSError *error = nil;
    if (![self.execution cancelRun:runID account:account error:&error])
        [self showError:@"取消未执行" error:error fallback:@"当前状态不允许取消。"];
    [self finish];
}
- (void)endPressed:(NSString *)runID {
    if (![self revalidateRun:runID]) return;
    NSString *account = [self.account copy];
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"结束这次执行？"
        message:@"未发送的目标不再发送；已提交或在途的结果会保留，不会重发，也不会自动开始下一组。"
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"继续执行" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"结束" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        if (![weakSelf verified] || ![account isEqual:weakSelf.account]) return;
        if (![weakSelf revalidateRun:runID]) return;
        NSError *error = nil;
        if (![weakSelf.execution endRun:runID account:account error:&error])
            [weakSelf showError:@"结束未执行" error:error fallback:@"当前状态不允许结束。"];
        [weakSelf finish];
    }]];
    SRScreenPresent(self, confirm);
}
@end

UIViewController *SRCreateOperationsHome(SRStore *store, SRSourceCapture *capture, SRSmallGroupSession *execution,
                                          NSString *account, BOOL (^verifyAccount)(void),
                                          void (^ _Nullable openSettings)(void)) {
    SROperationsHomeScreen *screen = [[SROperationsHomeScreen alloc] initWithStyle:UITableViewStyleGrouped];
    screen.store = store; screen.capture = capture; screen.execution = execution;
    screen.account = account; screen.verifyAccount = verifyAccount;
    screen.openSettings = openSettings;
    return screen;
}
UIViewController *SRCreateGroupList(SRStore *store, SRSmallGroupSession *execution, NSString *account,
                                    BOOL (^verifyAccount)(void), NSString * _Nullable planID,
                                    NSDictionary * _Nullable configuration) {
    SRGroupListScreen *screen = [[SRGroupListScreen alloc] initWithStyle:UITableViewStyleGrouped];
    screen.store = store; screen.execution = execution; screen.account = account;
    screen.verifyAccount = verifyAccount; screen.planID = planID; screen.configuration = configuration;
    return screen;
}
UIViewController *SRCreateRunDetail(SRStore *store, SRSmallGroupSession *execution, NSString *account,
                                     BOOL (^verifyAccount)(void), NSString * _Nullable planID,
                                     NSString * _Nullable ruleID, NSString * _Nullable runID) {
    SRRunDetailScreen *screen = [[SRRunDetailScreen alloc] initWithStyle:UITableViewStyleGrouped];
    screen.store = store; screen.execution = execution; screen.account = account;
    screen.verifyAccount = verifyAccount; screen.planID = planID; screen.ruleID = ruleID; screen.runID = runID;
    return screen;
}
UIViewController *SRCreateRunExceptions(SRStore *store, NSString *account, BOOL (^verifyAccount)(void), NSString *run) {
    SRRecordScreen *screen = [[SRRecordScreen alloc] initWithStyle:UITableViewStyleGrouped];
    screen.kind = SRRecordExceptions; screen.store = store; screen.account = account;
    screen.verifyAccount = verifyAccount; screen.identifier = run; screen.title = @"异常与未发项";
    return screen;
}
UIViewController *SRCreateReadOnlyText(NSString *title, NSString *body, BOOL (^verifyAccount)(void)) {
    SRSourceTextScreen *viewer = [[SRSourceTextScreen alloc] init];
    viewer.title = title; viewer.body = body; viewer.verifyAccount = verifyAccount;
    return viewer;
}
