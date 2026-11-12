#import "SRLibraryScreens.h"
#import "SRNativeStyle.h"
#import "SRPlanScreens.h"
#import "Core/SRStore.h"
#import "Core/SREntryPreferences.h"
#import "Adapter/SRSmallGroupSession.h"
#import "Core/SRImageAssetStore.h"
#import "Core/SRMediaProjection.h"
#import "Core/SRRunProjection.h"

/* ------------------------------------------------------------------------ */
/* Shared read-only helpers                                                  */
/* ------------------------------------------------------------------------ */

static NSDictionary *SRLibraryDictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static BOOL SRLibraryHasMedia(NSDictionary *version) {
    id token = version[@"media_token"];
    return [token isKindOfClass:NSString.class] && [token length] > 0;
}

/* One readable line for a stored version payload. Text is quoted with a bound;
 * image data is described by its stored metadata only — the page never reads
 * the asset bytes, prepares media or calls a host getter. */
static NSString *SRLibraryVersionBody(NSDictionary *version) {
    NSDictionary *payload = SRLibraryDictionary(version[@"payload"]);
    NSString *kind = [version[@"kind"] isKindOfClass:NSString.class] ? version[@"kind"] : nil;
    if ([kind isEqual:@"image"]) {
        if (!SRLibraryHasMedia(version)) return @"素材不可用：本地没有该版本的媒体引用";
        NSString *width = payload[@"pixelWidth"] ?: @"未记录";
        NSString *height = payload[@"pixelHeight"] ?: @"未记录";
        NSNumber *bytes = [payload[@"byteCount"] isKindOfClass:NSNumber.class] ? payload[@"byteCount"] : nil;
        return [NSString stringWithFormat:@"%@ × %@ · %@\n素材不在此页渲染",
            width, height, [SRMediaProjection bytesText:bytes]];
    }
    id text = payload[@"text"];
    if (![text isKindOfClass:NSString.class] || ![(NSString *)text length]) return @"没有可显示的文字内容";
    NSString *body = text;
    if (body.length <= 120) return body;
    NSRange range = [body rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 120)];
    return [[body substringWithRange:range] stringByAppendingString:@"…"];
}

/* ------------------------------------------------------------------------ */
/* 消息库列表                                                                */
/* ------------------------------------------------------------------------ */

@interface SRLibraryListScreen : UITableViewController
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
@property(nonatomic, copy, nullable) void (^openGroups)(UIViewController *source);
@property(nonatomic, strong, nullable) SRSmallGroupSession *session;
@property(nonatomic, strong) NSMutableArray *rows;
@property(nonatomic, copy, nullable) NSDictionary *problem;
@property(nonatomic) BOOL accountInvalid;
@property(nonatomic) BOOL masked;
@property(nonatomic) BOOL more;
@end

@implementation SRLibraryListScreen
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"消息库转发";
    SRStyleSettingsTable(self);
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resigningActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
/* Leaving the foreground hides what is on screen; it never stops a capture,
 * cancels a run or starts one. */
- (void)resigningActive:(__unused NSNotification *)notification {
    self.masked = YES;
    [self.rows removeAllObjects]; self.problem = nil; self.more = NO;
    [self.tableView reloadData];
}
/* Returning re-checks the account this page was opened with. A failed check
 * clears the page instead of switching to whatever account is current now. */
- (void)becameActive:(__unused NSNotification *)notification {
    if (!self.viewIfLoaded.window) return;
    if (![self verified]) {
        self.accountInvalid = YES; self.masked = NO;
        [self.rows removeAllObjects]; self.problem = nil; self.more = NO;
        [self.tableView reloadData]; return;
    }
    [self reload];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (BOOL)verified {
    @try { return self.verifyAccount && self.verifyAccount(); }
    @catch (__unused id exception) { return NO; }
}
- (void)reload {
    self.rows = [NSMutableArray array]; self.problem = nil; self.more = NO; self.masked = NO;
    self.accountInvalid = ![self verified];
    if (self.accountInvalid) { [self.refreshControl endRefreshing]; [self.tableView reloadData]; return; }
    NSError *error = nil;
    NSArray *page = [self.store libraryItemsForAccount:self.account limit:50 offset:0 error:&error];
    if (!page) self.problem = @{@"title": @"读取失败",
        @"message": error.localizedDescription ?: @"无法读取消息库，请下拉重试。"};
    else {
        [self.rows addObjectsFromArray:page];
        self.more = page.count == 50;
    }
    [self.refreshControl endRefreshing];
    [self.tableView reloadData];
}
- (void)loadMore {
    if (![self verified]) { self.accountInvalid = YES; [self.tableView reloadData]; return; }
    NSError *error = nil;
    NSArray *page = [self.store libraryItemsForAccount:self.account limit:50 offset:self.rows.count error:&error];
    if (!page) { self.problem = @{@"title": @"读取失败",
        @"message": error.localizedDescription ?: @"无法继续读取，请下拉重试。"}; }
    else { [self.rows addObjectsFromArray:page]; self.more = page.count == 50; }
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 1; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    if (self.masked) return 1;
    if (self.accountInvalid || self.problem) return 1;
    if (!self.rows.count) return 1;
    return (NSInteger)self.rows.count + (self.more ? 1 : 0);
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    if (self.masked) return @"内容已隐藏";
    if (self.accountInvalid) return @"账号";
    if (self.problem) return @"读取已停止";
    return @"消息库条目";
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    if (self.masked) return @"离开前台时已清除本页显示；回到前台会重新核对账号后再读取。";
    if (self.accountInvalid) return @"当前账号无法核对或已经改变，旧条目已隐藏。请返回重新读取账号。";
    if (self.problem) return @"读取失败时不提供任何操作。";
    return @"查看本账号保存的文字和静态图片；进入详情后选择分组，明确确认才会开始转发。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"library"] ?:
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"library"];
    SRStyleSettingsCell(cell);
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.text = nil; cell.detailTextLabel.text = nil;
    cell.imageView.image = nil;
    cell.accessoryType = UITableViewCellAccessoryNone; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (self.masked) {
        cell.textLabel.text = @"内容已隐藏";
        cell.detailTextLabel.text = @"离开前台时清除；回到前台重新核对账号后显示";
        return cell;
    }
    if (self.accountInvalid) {
        cell.textLabel.text = @"账号无法核对或已经改变";
        cell.detailTextLabel.text = @"旧条目已隐藏，不会显示其他账号的内容";
        return cell;
    }
    if (self.problem) {
        cell.textLabel.text = self.problem[@"title"];
        cell.detailTextLabel.text = self.problem[@"message"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if (!self.rows.count) {
        cell.textLabel.text = @"消息库还没有消息";
        cell.detailTextLabel.text = @"可在设置开启「长按消息存入库」，再长按文字或静态图片选择「存入同步库」。";
        return cell;
    }
    if (path.row == (NSInteger)self.rows.count) {
        cell.textLabel.text = @"加载更多";
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    NSDictionary *row = self.rows[(NSUInteger)path.row];
    cell.textLabel.text = [SRMediaProjection libraryKindText:row[@"kind"]];
    NSString *symbol = [@{@"image": @"photo", @"text": @"doc.text"} objectForKey:row[@"kind"] ?: @""] ?: @"questionmark.square";
    cell.imageView.image = [UIImage systemImageNamed:symbol];
    cell.imageView.tintColor = UIColor.systemBlueColor;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"更新于 %@ · %@ 个版本",
        [SRRunProjection localDateTimeText:row[@"updated_at"]], row[@"versionCount"] ?: @0];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    if (self.accountInvalid || self.problem) return nil;
    NSDictionary *entry = self.rows[path.row];
    NSString *item = entry[@"id"];
    if (!item.length) return nil;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(__unused UIContextualAction *action, __unused UIView *view,
                                 void (^completion)(BOOL)) {
        [weakSelf confirmDeleteItem:item completion:completion];
    }];
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

- (void)confirmDeleteItem:(NSString *)item completion:(void (^)(BOOL))completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除条目？"
        message:@"从消息库列表移除该条目；已保存的历史版本与媒体不会被删除。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
        if (completion) completion(NO);
    }]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        NSError *error = nil;
        BOOL ok = [weakSelf.store deleteLibraryEntry:item account:weakSelf.account error:&error];
        if (ok) { [weakSelf reload]; if (completion) completion(YES); return; }
        if (completion) completion(NO);
        UIAlertController *failure = [UIAlertController alertControllerWithTitle:@"删除失败"
            message:error.localizedDescription ?: @"请稍后重试" preferredStyle:UIAlertControllerStyleAlert];
        [failure addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [weakSelf presentViewController:failure animated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.masked) return;
    if (![self verified]) { self.accountInvalid = YES; [self.tableView reloadData]; return; }
    if (self.problem) { [self reload]; return; }
    if (!self.rows.count) return;
    if (path.row == (NSInteger)self.rows.count) { [self loadMore]; return; }
    // Repeated taps must not stack the same page twice.
    if (self.navigationController.topViewController != self) return;
    NSDictionary *row = self.rows[(NSUInteger)path.row];
    id identifier = row[@"id"];
    if (![identifier isKindOfClass:NSString.class] || ![identifier length]) return;
    [self.navigationController pushViewController:SRCreateLibraryItem(self.store, self.account,
        self.verifyAccount, identifier, self.session, self.openGroups) animated:YES];
}
@end

/* ------------------------------------------------------------------------ */
/* 条目详情                                                                  */
/* ------------------------------------------------------------------------ */

@interface SRLibraryItemScreen : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UIRefreshControl *refreshControl;
@property(nonatomic, strong) UIButton *forwardButton;
@property(nonatomic) UITableViewStyle detailTableStyle;
@property(nonatomic) BOOL recordsOnly;
- (instancetype)initWithStyle:(UITableViewStyle)style;
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
@property(nonatomic, copy, nullable) void (^openGroups)(UIViewController *source);
@property(nonatomic, strong, nullable) SRSmallGroupSession *session;
@property(nonatomic, copy) NSString *item;
@property(nonatomic, copy, nullable) NSDictionary *entry;
@property(nonatomic, strong) NSArray *versions;
@property(nonatomic, strong) NSArray *tasks;
@property(nonatomic, copy, nullable) NSDictionary *problem;
@property(nonatomic) BOOL accountInvalid;
@property(nonatomic) BOOL masked;
- (void)promptForward;
- (void)forwardToGroups:(NSArray<NSString *> *)targets;
- (void)createAndStartForwardToGroups:(NSArray<NSString *> *)targets version:(NSString *)version;
@end

@implementation SRLibraryItemScreen
- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithNibName:nil bundle:nil])) _detailTableStyle = style;
    return self;
}
- (NSDictionary *)currentVersion {
    for (NSDictionary *version in self.versions)
        if ([version[@"id"] isEqual:self.entry[@"current_version_id"]]) return version;
    return nil;
}
- (BOOL)canChooseTargets {
    NSString *kind = [self currentVersion][@"kind"];
    return !self.masked && !self.accountInvalid && !self.problem && self.session &&
        ([kind isEqual:@"text"] || [kind isEqual:@"image"]);
}
- (void)updateForwardButton {
    self.forwardButton.hidden = ![self canChooseTargets];
    self.forwardButton.enabled = !self.forwardButton.hidden;
}
- (void)showRecords {
    if (self.masked || ![self verified] || self.navigationController.topViewController != self) return;
    SRLibraryItemScreen *records = [[SRLibraryItemScreen alloc] initWithStyle:UITableViewStyleInsetGrouped];
    records.store = self.store; records.account = self.account; records.item = self.item;
    records.verifyAccount = self.verifyAccount; records.session = self.session; records.recordsOnly = YES;
    [self.navigationController pushViewController:records animated:YES];
}
- (void)showActions {
    if (self.masked || self.accountInvalid || self.problem || ![self verified]) return;
    NSString *kind = [self.entry[@"kind"] isKindOfClass:NSString.class] ? self.entry[@"kind"] : @"";
    BOOL forwardable = [kind isEqual:@"text"] || [kind isEqual:@"image"];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    if (forwardable && self.session && [self currentVersion]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"转发到群…" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *a) { [weakSelf promptForward]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"版本与记录" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) { [weakSelf showRecords]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除条目" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *a) { [weakSelf confirmDelete]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmDelete {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除条目？"
        message:@"从列表移除该条目；历史版本与媒体不会被删除。" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *a) {
        NSError *error = nil;
        if ([weakSelf.store deleteLibraryEntry:weakSelf.item account:weakSelf.account error:&error]) {
            [weakSelf.navigationController popViewControllerAnimated:YES];
            return;
        }
        [weakSelf showFailure:@"删除失败" error:error];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptForward {
    if (![self canChooseTargets] || ![self verified] || self.navigationController.topViewController != self) return;
    NSString *version = [self.entry[@"current_version_id"] copy];
    if (!version.length) return;
    __weak typeof(self) weakSelf = self;
    UIViewController *picker = SRCreateTargetPicker(self.store, self.account, self.verifyAccount, self.openGroups, ^(NSArray<NSString *> *targets) {
        SRLibraryItemScreen *detail = weakSelf;
        if (!detail || detail.navigationController.topViewController != detail || ![detail canChooseTargets] || ![detail verified]) return;
        if (![detail.entry[@"current_version_id"] isEqual:version]) {
            [detail showFailure:@"消息版本已变更，请重新选择分组" error:nil];
            return;
        }
        [detail forwardToGroups:targets];
    });
    [self.navigationController pushViewController:picker animated:YES];
}

- (void)forwardToGroups:(NSArray<NSString *> *)targets {
    if (![self verified]) return;
    NSUInteger limit = self.store.forwardingTargetLimit;
    if (targets.count > limit) {
        UIAlertController *over = [UIAlertController alertControllerWithTitle:@"超过目标上限"
            message:SRTargetLimitMessage(targets.count, limit) preferredStyle:UIAlertControllerStyleAlert];
        [over addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:over animated:YES completion:nil];
        return;
    }
    if (!targets.count) return;
    NSArray<NSString *> *confirmedTargets = [targets copy];
    NSString *version = [self.entry[@"current_version_id"] copy];
    if (!version.length) { [self showFailure:@"无法确认消息版本" error:nil]; return; }
    NSString *risk = targets.count > 100 ? @"\n超过 100 个群有风控风险，建议先用更少的群验证。" : @"";
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"确认转发消息库内容？"
        message:[NSString stringWithFormat:@"将按顺序转发当前版本的 %@ 内容到 %lu 个群，每个目标间隔 5–8 秒。微信切到后台会暂停；提交结果未知的群不会自动重发。%@",
            [self.entry[@"kind"] isEqual:@"image"] ? @"图片" : @"文字", (unsigned long)targets.count, risk]
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"确认并开始" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf createAndStartForwardToGroups:confirmedTargets version:version];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)createAndStartForwardToGroups:(NSArray<NSString *> *)targets version:(NSString *)version {
    if (![self verified]) return;
    NSError *error = nil;
    // A stable key makes an identical request (same entry, version and ordered
    // targets) resolve to the frozen task that already exists instead of
    // creating another plan every time the button is tapped.
    NSString *scope = [NSString stringWithFormat:@"%@|%@|%@", self.item, version,
                       [targets componentsJoinedByString:@","]];
    NSString *confirmation = [SRImageAssetStore sha256ForData:[scope dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *task = [self.store createLibraryTaskForAccount:self.account item:self.item
        version:version confirmationID:confirmation targets:targets
        minimum:5 maximum:8 error:&error];
    if (!task.length) { [self showFailure:@"创建转发任务失败" error:error]; return; }
    if (!self.session || ![self.session startLibraryTask:task account:self.account error:&error]) {
        [self showFailure:@"启动转发任务失败" error:error];
        return;
    }
    UIAlertController *done = [UIAlertController alertControllerWithTitle:@"已创建转发任务"
        message:[NSString stringWithFormat:@"目标 %lu 个；任务已冻结并启动。", (unsigned long)targets.count]
        preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:done animated:YES completion:nil];
}

- (void)showFailure:(NSString *)title error:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:error.localizedDescription ?: @"请稍后重试" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.recordsOnly ? @"版本与记录" : @"消息详情";
    if (!self.recordsOnly) self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis"] style:UIBarButtonItemStylePlain
        target:self action:@selector(showActions)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"更多操作";
    SRStyleSettingsController(self);
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:self.detailTableStyle];
    UITableView *table = self.tableView;
    table.translatesAutoresizingMaskIntoConstraints = NO;
    table.delegate = self; table.dataSource = self;
    table.backgroundColor = self.view.backgroundColor;
    table.rowHeight = UITableViewAutomaticDimension; table.estimatedRowHeight = 56;
    table.sectionFooterHeight = UITableViewAutomaticDimension; table.estimatedSectionFooterHeight = 44;
    table.sectionHeaderTopPadding = 0;
    table.separatorInset = UIEdgeInsetsMake(0, 18, 0, 18);
    if (!self.recordsOnly) {
        table.separatorStyle = UITableViewCellSeparatorStyleNone;
        table.layoutMargins = UIEdgeInsetsMake(0, 12, 0, 12);
        table.cellLayoutMarginsFollowReadableWidth = NO;
    }
    table.tableHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 8)];
    [self.view addSubview:table];
    [NSLayoutConstraint activateConstraints:@[
        [table.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
    if (self.recordsOnly) {
        [table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor].active = YES;
    } else {
        self.forwardButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButton *button = self.forwardButton;
        button.translatesAutoresizingMaskIntoConstraints = NO;
        UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
        configuration.baseBackgroundColor = UIColor.systemBlueColor;
        configuration.baseForegroundColor = UIColor.whiteColor;
        configuration.cornerStyle = UIButtonConfigurationCornerStyleFixed;
        configuration.background.cornerRadius = 12;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(12, 16, 12, 16);
        configuration.attributedTitle = [[NSAttributedString alloc] initWithString:@"选择分组转发"
            attributes:@{NSFontAttributeName: [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline]
                scaledFontForFont:[UIFont systemFontOfSize:18 weight:UIFontWeightSemibold]]}];
        button.configuration = configuration;
        button.titleLabel.adjustsFontForContentSizeCategory = YES;
        button.titleLabel.numberOfLines = 0; button.titleLabel.textAlignment = NSTextAlignmentCenter;
        button.accessibilityIdentifier = @"SyncRelay.LibraryChooseGroups";
        [button addTarget:self action:@selector(promptForward) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:button];
        [NSLayoutConstraint activateConstraints:@[
            [button.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
            [button.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
            [button.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-18],
            [button.heightAnchor constraintGreaterThanOrEqualToConstant:46],
            [table.bottomAnchor constraintEqualToAnchor:button.topAnchor constant:-12]]];
    }
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = self.refreshControl;
    [self updateForwardButton];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resigningActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
/* Hiding the entry never touches capture, runs or sending. */
- (void)resigningActive:(__unused NSNotification *)notification {
    self.masked = YES;
    self.entry = nil; self.versions = @[]; self.problem = nil;
    [self updateForwardButton]; [self.tableView reloadData];
}
- (void)becameActive:(__unused NSNotification *)notification {
    if (!self.viewIfLoaded.window) return;
    if (![self verified]) {
        self.accountInvalid = YES; self.masked = NO;
        self.entry = nil; self.versions = @[]; self.problem = nil;
        [self updateForwardButton]; [self.tableView reloadData]; return;
    }
    [self reload];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (BOOL)verified {
    @try { return self.verifyAccount && self.verifyAccount(); }
    @catch (__unused id exception) { return NO; }
}
- (void)reload {
    self.entry = nil; self.versions = @[]; self.problem = nil; self.masked = NO;
    self.accountInvalid = ![self verified];
    if (self.accountInvalid) { [self.refreshControl endRefreshing]; [self updateForwardButton]; [self.tableView reloadData]; return; }
    NSError *error = nil;
    NSDictionary *entry = [self.store libraryItem:self.item account:self.account error:&error];
    if (!entry) self.problem = @{@"title": @"读取失败",
        @"message": error.localizedDescription ?: @"无法读取该条目，请下拉重试。"};
    else {
        self.entry = entry;
        NSArray *versions = [entry[@"versions"] isKindOfClass:NSArray.class] ? entry[@"versions"] : @[];
        self.versions = versions;
        self.tasks = [self.store libraryTasksForItem:self.item account:self.account limit:20 error:NULL] ?: @[];
    }
    [self.refreshControl endRefreshing];
    [self updateForwardButton]; [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (self.masked || self.accountInvalid || self.problem) ? 1 : (self.recordsOnly ? 3 : 2);
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.masked || self.accountInvalid || self.problem) return 1;
    if (!self.recordsOnly) return section == 0 ? 1 : 3;
    if (section == 0) return 5;
    if (section == 1) return self.versions.count ? (NSInteger)self.versions.count : 1;
    return self.tasks.count ? (NSInteger)self.tasks.count : 1;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.masked) return @"内容已隐藏";
    if (self.accountInvalid) return @"账号";
    if (self.problem) return @"读取已停止";
    if (!self.recordsOnly) return nil;
    if (section == 0) return @"条目";
    return section == 1 ? @"版本（只读）" : @"发送记录";
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.masked) return @"离开前台时已清除本页显示；回到前台会重新核对账号后再读取。";
    if (self.accountInvalid) return @"当前账号无法核对或已经改变，本页已失去显示资格。";
    if (self.problem) return @"本页只读，不会创建、删除或发送任何条目。";
    if (!self.recordsOnly) return section == 1 ? @"只处理本次选择的分组，不会自动接下一组。" : nil;
    if (section == 0) return @"条目只属于打开本页时的账号；数量与版本以持久记录为准。";
    if (section == 1) return @"文字与图片版本可转发到群；删除只隐藏条目，不删除历史版本与媒体。";
    return @"发送记录只读：显示每次冻结任务的目标数、运行状态与创建时间。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"library-item"] ?:
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"library-item"];
    SRStyleSettingsCell(cell);
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.text = nil; cell.detailTextLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryNone; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (self.masked) {
        cell.textLabel.text = @"内容已隐藏";
        cell.detailTextLabel.text = @"离开前台时清除；回到前台重新核对账号后显示";
        return cell;
    }
    if (self.accountInvalid) {
        cell.textLabel.text = @"账号无法核对或已经改变";
        cell.detailTextLabel.text = @"本页不会再读取或显示任何内容";
        return cell;
    }
    if (self.problem) {
        cell.textLabel.text = self.problem[@"title"];
        cell.detailTextLabel.text = self.problem[@"message"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if (!self.recordsOnly) return [self messageCellAtIndexPath:path];
    NSDictionary *entry = self.entry ?: @{};
    if (path.section == 0) {
        NSArray *titles = @[@"条目标识", @"内容类型", @"版本数", @"创建时间", @"更新时间"];
        cell.textLabel.text = titles[(NSUInteger)path.row];
        if (path.row == 0) cell.detailTextLabel.text = entry[@"id"] ?: @"未记录";
        else if (path.row == 1) cell.detailTextLabel.text = [SRMediaProjection libraryKindText:entry[@"kind"]];
        else if (path.row == 2) cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ 个",
            @([self.versions count])];
        else if (path.row == 3) cell.detailTextLabel.text = [SRRunProjection localDateTimeText:entry[@"created_at"]];
        else cell.detailTextLabel.text = [SRRunProjection localDateTimeText:entry[@"updated_at"]];
        return cell;
    }
    if (!self.versions.count) {
        cell.textLabel.text = @"没有版本记录";
        cell.detailTextLabel.text = @"该条目没有可显示的版本；不会重建或导入。";
        return cell;
    }
    if (path.section == 2) {
        if (!self.tasks.count) {
            cell.textLabel.text = @"还没有发送记录";
            cell.detailTextLabel.text = @"从本条目转发后，这里会显示每次任务。";
            return cell;
        }
        NSDictionary *task = self.tasks[(NSUInteger)path.row];
        NSString *state = [task[@"run_state"] isKindOfClass:NSString.class] ? task[@"run_state"] : @"未启动";
        cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@ 个群",
            state, task[@"target_count"] ?: @0];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"创建 %@%@",
            [SRRunProjection localDateTimeText:task[@"created_at"]],
            [task[@"started_at"] isKindOfClass:NSNumber.class] ? @"" : @" · 尚未启动"];
        return cell;
    }
    NSDictionary *version = self.versions[(NSUInteger)path.row];
    BOOL current = [version[@"id"] isEqual:entry[@"current_version_id"]];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@%@",
        version[@"ordinal"] ?: @"?", [SRMediaProjection libraryKindText:version[@"kind"]],
        current ? @" · 当前版本" : @""];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"捕获 %@\n%@",
        [SRRunProjection localDateTimeText:version[@"captured_at"]], SRLibraryVersionBody(version)];
    // Only a stored text body opens a viewer; image versions stay metadata-only.
    if ([version[@"kind"] isEqual:@"text"]) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.masked) return;
    if (![self verified]) { self.accountInvalid = YES; [self updateForwardButton]; [self.tableView reloadData]; return; }
    if (self.problem) { [self reload]; return; }
    if (!self.recordsOnly) {
        if (path.section == 1 && path.row == 1) [self promptForward];
        return;
    }
    if (path.section != 1 || !self.versions.count) return;
    if (self.navigationController.topViewController != self) return;
    NSDictionary *version = self.versions[(NSUInteger)path.row];
    if (![version[@"kind"] isEqual:@"text"]) return;
    NSDictionary *payload = SRLibraryDictionary(version[@"payload"]);
    id text = payload[@"text"];
    NSString *body = [text isKindOfClass:NSString.class] ? text : @"没有可显示的文字内容";
    [self.navigationController pushViewController:SRCreateReadOnlyText(@"版本内容（只读）", body,
        self.verifyAccount) animated:YES];
}
- (CGFloat)tableView:(__unused UITableView *)tableView heightForHeaderInSection:(__unused NSInteger)section {
    return self.recordsOnly ? UITableViewAutomaticDimension : 0.01;
}
- (CGFloat)tableView:(__unused UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if (!self.recordsOnly && !self.masked && !self.accountInvalid && !self.problem && section == 0) return 14;
    return UITableViewAutomaticDimension;
}
- (void)tableView:(__unused UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if (!self.recordsOnly && section == 1 && [view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UILabel *label = ((UITableViewHeaderFooterView *)view).textLabel;
        label.textAlignment = NSTextAlignmentCenter;
        label.font = SRSettingsFont(13, UIFontTextStyleFootnote); label.numberOfLines = 0;
    }
}
- (UILabel *)messageLabel:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight {
    UILabel *label = [[UILabel alloc] init]; label.text = text; label.numberOfLines = 0;
    label.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]];
    label.adjustsFontForContentSizeCategory = YES; label.textColor = UIColor.labelColor;
    return label;
}
- (UITableViewCell *)messageCellAtIndexPath:(NSIndexPath *)path {
    BOOL accessible = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:accessible ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1 reuseIdentifier:nil];
    SRStyleSettingsCell(cell);
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    if (path.section == 1) {
        if (path.row == 0) {
            cell.textLabel.text = @"本次转发";
            cell.textLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline]
                scaledFontForFont:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]];
        } else {
            cell.textLabel.text = path.row == 1 ? @"目标分组" : @"预计目标";
            cell.detailTextLabel.text = path.row == 1 ? @"尚未选择" : @"选择分组后显示";
            cell.detailTextLabel.font = SRSettingsFont(15, UIFontTextStyleSubheadline);
            if (path.row == 1 && [self canChooseTargets]) {
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                cell.accessibilityIdentifier = @"SyncRelay.LibraryTargetGroup";
            }
            if (path.row == 1) {
                UIView *line = [[UIView alloc] init]; line.backgroundColor = UIColor.separatorColor;
                line.translatesAutoresizingMaskIntoConstraints = NO; [cell.contentView addSubview:line];
                [NSLayoutConstraint activateConstraints:@[
                    [line.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:14],
                    [line.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-14],
                    [line.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
                    [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale]]];
            }
        }
        cell.layoutMargins = UIEdgeInsetsMake(14, 18, 14, 18);
        return cell;
    }
    NSDictionary *version = [self currentVersion];
    UILabel *heading = [self messageLabel:@"消息内容" size:17 weight:UIFontWeightSemibold];
    NSString *kind = version[@"kind"];
    NSString *body = nil;
    if ([kind isEqual:@"text"]) {
        id text = SRLibraryDictionary(version[@"payload"])[@"text"];
        body = [text isKindOfClass:NSString.class] ? text : @"没有可显示的文字内容";
    } else if ([kind isEqual:@"image"]) body = SRLibraryVersionBody(version);
    else body = @"没有可显示的受支持内容";
    UILabel *message = [self messageLabel:body size:18 weight:UIFontWeightRegular];
    message.accessibilityIdentifier = @"SyncRelay.LibraryMessageBody";
    UIView *line = [[UIView alloc] init]; line.backgroundColor = UIColor.separatorColor;
    [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
    NSString *type = [SRMediaProjection libraryKindText:kind];
    UILabel *origin = [self messageLabel:[NSString stringWithFormat:@"%@消息 · 来自消息库", type]
        size:13 weight:UIFontWeightRegular];
    UILabel *time = [self messageLabel:[SRRunProjection localDateTimeText:version[@"captured_at"]]
        size:13 weight:UIFontWeightRegular];
    origin.textColor = UIColor.secondaryLabelColor; time.textColor = UIColor.secondaryLabelColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[heading, message, line, origin, time]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 10;
    [stack setCustomSpacing:20 afterView:heading]; [stack setCustomSpacing:14 afterView:message];
    [stack setCustomSpacing:4 afterView:origin];
    stack.translatesAutoresizingMaskIntoConstraints = NO; [cell.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-18],
        [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:14],
        [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-16]]];
    return cell;
}
@end

/* ------------------------------------------------------------------------ */
/* 资源容量                                                                  */
/* ------------------------------------------------------------------------ */

@interface SRMediaResourcesScreen : UITableViewController
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
@property(nonatomic, copy, nullable) NSDictionary *usage;
@property(nonatomic, copy) NSDictionary *resourceSection;
@property(nonatomic, strong) NSArray *resources;
@property(nonatomic, copy, nullable) NSDictionary *usageProblem;
@property(nonatomic, copy, nullable) NSDictionary *listProblem;
@property(nonatomic) BOOL accountInvalid;
@property(nonatomic) BOOL masked;
@end

@implementation SRMediaResourcesScreen
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"资源容量";
    SRStyleSettingsTable(self);
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.resourceSection = [SRMediaProjection resourceSectionForPayload:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resigningActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
/* Masking is display-only: capture, runs and sending are untouched. */
- (void)resigningActive:(__unused NSNotification *)notification {
    self.masked = YES;
    self.usage = nil; self.resources = @[]; self.usageProblem = nil; self.listProblem = nil;
    self.resourceSection = [SRMediaProjection resourceSectionForPayload:nil];
    [self.tableView reloadData];
}
- (void)becameActive:(__unused NSNotification *)notification {
    if (!self.viewIfLoaded.window) return;
    if (![self verified]) {
        self.accountInvalid = YES; self.masked = NO;
        self.usage = nil; self.resources = @[]; self.usageProblem = nil; self.listProblem = nil;
        self.resourceSection = [SRMediaProjection resourceSectionForPayload:nil];
        [self.tableView reloadData]; return;
    }
    [self reload];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (BOOL)verified {
    @try { return self.verifyAccount && self.verifyAccount(); }
    @catch (__unused id exception) { return NO; }
}
- (void)reload {
    self.usage = nil; self.resources = @[]; self.usageProblem = nil; self.listProblem = nil;
    self.masked = NO;
    self.resourceSection = [SRMediaProjection resourceSectionForPayload:nil];
    self.accountInvalid = ![self verified];
    if (self.accountInvalid) { [self.refreshControl endRefreshing]; [self.tableView reloadData]; return; }
    NSError *usageError = nil;
    self.usage = [self.store mediaUsageForAccount:self.account error:&usageError];
    if (!self.usage) self.usageProblem = @{@"title": @"用量读取失败",
        @"message": usageError.localizedDescription ?: @"无法扫描媒体用量，请下拉重试。"};
    // The shared capacity and the resource list fail independently: one may be
    // readable while the other is not.
    NSError *listError = nil;
    NSDictionary *resources = [self.store mediaResourcesForAccount:self.account limit:200 error:&listError];
    if (!resources) self.listProblem = @{@"title": @"资源列表读取失败",
        @"message": listError.localizedDescription ?: @"无法列出资源，请下拉重试。"};
    else {
        self.resourceSection = [SRMediaProjection resourceSectionForPayload:resources];
        self.resources = [self.resourceSection[@"rows"] isKindOfClass:NSArray.class] ?
            self.resourceSection[@"rows"] : @[];
    }
    [self.refreshControl endRefreshing];
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    // Only a mask or a lost account collapses the page. A failed usage scan
    // affects the capacity section alone and must not hide the resource list.
    return (self.masked || self.accountInvalid) ? 1 : 2;
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.masked || self.accountInvalid) return 1;
    if (section == 0) return self.usageProblem ? 1 : 5;
    if (self.listProblem) return 1;
    return self.resources.count ? (NSInteger)self.resources.count : 1;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.masked) return @"内容已隐藏";
    if (self.accountInvalid) return @"账号";
    return section == 0 ? @"共享容量" : @"本账号的资源";
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.masked) return @"离开前台时已清除本页显示；回到前台会重新核对账号后再读取。";
    if (self.accountInvalid) return @"当前账号无法核对或已经改变，旧统计已隐藏。";
    if (section == 0) return self.usageProblem ?
        @"用量读不到时不显示 0，避免把未知当成空闲；下方资源列表仍按已读到的结果展示。" :
        @"容量为所有 SyncRelay 素材共用的一个上限，不按账号或类型拆分；本页不会清理任何文件。";
    if (self.listProblem) return @"资源列表读取失败不影响上方容量；请下拉重试。";
    return @"本页只读：不提供删除、清理或导入。其他账号的文件只计入统计，不在此列出。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"media"] ?:
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"media"];
    SRStyleSettingsCell(cell);
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.text = nil; cell.detailTextLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryNone; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (self.masked) {
        cell.textLabel.text = @"内容已隐藏";
        cell.detailTextLabel.text = @"离开前台时清除；回到前台重新核对账号后显示";
        return cell;
    }
    if (self.accountInvalid) {
        cell.textLabel.text = @"账号无法核对或已经改变";
        cell.detailTextLabel.text = @"旧统计已隐藏，不会显示其他账号的资源";
        return cell;
    }
    // A usage failure is confined to section 0; section 1 is still rendered.
    if (path.section == 0 && self.usageProblem) {
        cell.textLabel.text = self.usageProblem[@"title"];
        cell.detailTextLabel.text = self.usageProblem[@"message"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    NSDictionary *summary = [SRMediaProjection usageSummary:self.usage];
    if (path.section == 0) {
        NSArray *titles = @[@"已用 / 上限", @"占比", @"剩余", @"文件数", @"可回收"];
        cell.textLabel.text = titles[(NSUInteger)path.row];
        if (path.row == 0) cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ / %@",
            summary[@"usedText"], summary[@"limitText"]];
        else if (path.row == 1) cell.detailTextLabel.text = [NSString stringWithFormat:@"%@（%@）",
            summary[@"percentText"], summary[@"levelText"]];
        else if (path.row == 2) cell.detailTextLabel.text = summary[@"remainingText"];
        else if (path.row == 3) cell.detailTextLabel.text = summary[@"fileCountText"];
        else cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@", summary[@"reclaimableText"],
            [summary[@"complete"] isEqual:@YES] ? @"" : @"（不完整）"];
        return cell;
    }
    if (self.listProblem) {
        cell.textLabel.text = self.listProblem[@"title"];
        cell.detailTextLabel.text = self.listProblem[@"message"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if (!self.resources.count) {
        NSString *state = [self.resourceSection[@"state"] isKindOfClass:NSString.class] ?
            self.resourceSection[@"state"] : @"unavailable";
        // Three different empty readings: unverified attribution, an incomplete
        // read, and a genuinely empty library.
        if ([state isEqual:@"unverified"]) {
            cell.textLabel.text = @"资源归属未验证";
            cell.detailTextLabel.text = @"引用关系读不到时无法确认哪些文件属于本账号，因此不显示明细；共享容量仍以上方数字为准。";
        } else if ([state isEqual:@"truncated_empty"]) {
            cell.textLabel.text = @"结果不完整";
            cell.detailTextLabel.text = @"本次没有取到资源行，且列表被截断，不能据此判断没有素材；请下拉重试。";
        } else {
            cell.textLabel.text = @"本账号没有已登记的素材";
            cell.detailTextLabel.text = @"列表为空只表示当前没有文件，不代表其他账号的情况。";
        }
        return cell;
    }
    NSDictionary *row = self.resources[(NSUInteger)path.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", row[@"kindText"], row[@"stateText"]];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n资源 %@%@", row[@"bytesText"],
        row[@"identifier"], [self.resourceSection[@"truncated"] isEqual:@YES] ? @"（列表已截断）" : @""];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.masked) return;
    if (![self verified]) { self.accountInvalid = YES; [self.tableView reloadData]; return; }
    // Retry only from the section that failed; the other section is untouched.
    if (path.section == 0 && self.usageProblem) { [self reload]; return; }
    if (path.section == 1 && self.listProblem) { [self reload]; return; }
}
@end


/* ------------------------------------------------------------------------ */
/* Saved group target picker                                                 */
/* ------------------------------------------------------------------------ */

@interface SRTargetPickerScreen : UITableViewController
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
@property(nonatomic, copy, nullable) void (^openGroups)(UIViewController *source);
@property(nonatomic, copy) NSArray *rules;
@property(nonatomic, strong) NSMutableIndexSet *selectedRules;
@property(nonatomic, copy) void (^completion)(NSArray<NSString *> *targets);
@property(nonatomic, copy, nullable) NSString *problem;
@end

@implementation SRTargetPickerScreen
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择转发目标";
    self.selectedRules = [NSMutableIndexSet indexSet];
    SRStyleSettingsTable(self);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成"
        style:UIBarButtonItemStyleDone target:self action:@selector(finish)];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resigningActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadGroups]; }
- (BOOL)verified {
    @try { return self.verifyAccount && self.verifyAccount(); }
    @catch (__unused id exception) { return NO; }
}
- (void)updateSelection {
    self.navigationItem.rightBarButtonItem.enabled = !self.problem && self.selectedRules.count > 0;
    [self.tableView reloadData];
}
- (void)resigningActive:(__unused NSNotification *)notification {
    self.rules = @[];
    self.problem = @"返回前台后重新核对";
    [self.selectedRules removeAllIndexes];
    [self updateSelection];
}
- (void)becameActive:(__unused NSNotification *)notification {
    if (self.viewIfLoaded.window && self.navigationController.topViewController == self) [self reloadGroups];
}
- (NSArray *)readGroups {
    NSDictionary *configuration = [self.store configurationForAccount:self.account error:NULL];
    id rules = configuration[@"rules"];
    return [rules isKindOfClass:NSArray.class] ? rules : nil;
}
- (void)reloadGroups {
    [self.selectedRules removeAllIndexes];
    BOOL verified = [self verified];
    self.rules = verified ? [self readGroups] : nil;
    self.problem = !verified ? @"账号无法核对，请返回后重新打开" :
        (self.rules ? nil : @"暂时无法读取目标分组，请返回后重试");
    [self updateSelection];
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 1; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    if (self.problem) return 1;
    if (!self.rules.count) return self.openGroups ? 2 : 1;
    return (NSInteger)self.rules.count;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return @"目标分组";
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    if (self.problem || !self.rules.count) return nil;
    return [NSString stringWithFormat:@"最多可选 %lu 个群，超过 100 个会有风控风险。", (unsigned long)self.store.forwardingTargetLimit];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"picker"] ?:
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"picker"];
    SRStyleSettingsCell(cell);
    cell.textLabel.text = nil; cell.detailTextLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryNone; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (self.problem) {
        cell.textLabel.text = self.problem;
    } else if (!self.rules.count) {
        if (path.row == 1 && self.openGroups) {
            cell.textLabel.text = @"去群分组";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else {
            cell.textLabel.text = @"还没有可用的目标分组";
            if (!self.openGroups) cell.detailTextLabel.text = @"请先回首页，在「群分组」中配置并保存。";
        }
    } else {
        NSDictionary *rule = self.rules[(NSUInteger)path.row];
        NSArray *targets = [rule[@"targets"] isKindOfClass:NSArray.class] ? rule[@"targets"] : @[];
        cell.textLabel.text = [rule[@"name"] isKindOfClass:NSString.class] ? rule[@"name"] : @"未命名分组";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 个群", (unsigned long)targets.count];
        cell.accessoryType = [self.selectedRules containsIndex:(NSUInteger)path.row] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}
- (BOOL)canAct {
    UINavigationController *navigation = self.navigationController;
    if (navigation.topViewController != self || navigation.transitionCoordinator || navigation.presentedViewController || self.problem) return NO;
    if ([self verified]) return YES;
    [self reloadGroups];
    return NO;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section != 0 || ![self canAct]) return;
    NSUInteger row = (NSUInteger)path.row;
    if (!self.rules.count) {
        if (row == 1 && self.openGroups) self.openGroups(self);
        return;
    }
    if (row >= self.rules.count) return;
    if ([self.selectedRules containsIndex:row]) [self.selectedRules removeIndex:row];
    else [self.selectedRules addIndex:row];
    [self updateSelection];
}
- (void)finish {
    if (![self canAct] || !self.selectedRules.count) return;
    if (![[self readGroups] isEqualToArray:self.rules]) {
        [self reloadGroups];
        if (!self.problem && self.rules.count) [self alert:@"目标分组已变更" message:@"请重新选择本次分组。"];
        return;
    }
    NSMutableOrderedSet<NSString *> *targets = [NSMutableOrderedSet orderedSet];
    [self.selectedRules enumerateIndexesUsingBlock:^(NSUInteger row, __unused BOOL *stop) {
        for (NSDictionary *target in self.rules[row][@"targets"]) {
            NSString *identifier = target[@"id"];
            if ([identifier isKindOfClass:NSString.class] && [identifier hasSuffix:@"@chatroom"]) [targets addObject:identifier];
        }
    }];
    [self deliver:targets.array];
}

- (void)deliver:(NSArray<NSString *> *)targets {
    if (!targets.count) { [self alert:@"没有选择目标" message:@"请先选择至少一个目标分组。"]; return; }
    NSUInteger limit = self.store.forwardingTargetLimit;
    if (targets.count > limit) { [self alert:@"超过目标上限" message:SRTargetLimitMessage(targets.count, limit)]; return; }
    void (^completion)(NSArray<NSString *> *) = self.completion;
    UINavigationController *navigation = self.navigationController;
    if (navigation.topViewController != self || ![navigation popViewControllerAnimated:YES] || !completion) return;
    if (![navigation.transitionCoordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (!context.isCancelled) completion(targets);
    }]) completion(targets);
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

UIViewController *SRCreateTargetPicker(SRStore *store, NSString *account, BOOL (^verifyAccount)(void),
                                      void (^openGroups)(UIViewController *source), void (^completion)(NSArray<NSString *> *targets)) {
    SRTargetPickerScreen *screen = [[SRTargetPickerScreen alloc] initWithStyle:UITableViewStyleInsetGrouped];
    screen.store = store; screen.account = account; screen.verifyAccount = verifyAccount;
    screen.openGroups = openGroups; screen.completion = completion;
    return screen;
}

UIViewController *SRCreateLibraryList(SRStore *store, NSString *account, BOOL (^verifyAccount)(void), SRSmallGroupSession *session,
                                      void (^openGroups)(UIViewController *source)) {
    SRLibraryListScreen *screen = [[SRLibraryListScreen alloc] initWithStyle:UITableViewStyleInsetGrouped];
    screen.store = store; screen.account = account; screen.verifyAccount = verifyAccount; screen.session = session;
    screen.openGroups = openGroups; screen.rows = [NSMutableArray array];
    return screen;
}
UIViewController *SRCreateLibraryItem(SRStore *store, NSString *account, BOOL (^verifyAccount)(void), NSString *item, SRSmallGroupSession *session,
                                      void (^openGroups)(UIViewController *source)) {
    SRLibraryItemScreen *screen = [[SRLibraryItemScreen alloc] initWithStyle:UITableViewStyleInsetGrouped];
    screen.store = store; screen.account = account; screen.verifyAccount = verifyAccount;
    screen.openGroups = openGroups; screen.item = item; screen.versions = @[]; screen.session = session;
    return screen;
}
UIViewController *SRCreateMediaResources(SRStore *store, NSString *account, BOOL (^verifyAccount)(void)) {
    SRMediaResourcesScreen *screen = [[SRMediaResourcesScreen alloc] initWithStyle:UITableViewStyleInsetGrouped];
    screen.store = store; screen.account = account; screen.verifyAccount = verifyAccount;
    screen.resources = @[];
    return screen;
}
