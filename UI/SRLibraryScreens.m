#import "SRLibraryScreens.h"
#import "SRNativeStyle.h"
#import "SRPlanScreens.h"
#import "Core/SRStore.h"
#import "Core/SRMediaProjection.h"
#import "Core/SRRunProjection.h"

/* ------------------------------------------------------------------------ */
/* Shared read-only helpers                                                  */
/* ------------------------------------------------------------------------ */

/* A short numbered identifier, not a storage handle. */
static NSString *SRLibraryShortID(id value) {
    if (![value isKindOfClass:NSString.class] || ![(NSString *)value length]) return @"未记录";
    NSString *text = value;
    return text.length <= 8 ? text : [text substringToIndex:8];
}

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
@property(nonatomic, strong) NSMutableArray *rows;
@property(nonatomic, copy, nullable) NSDictionary *problem;
@property(nonatomic) BOOL accountInvalid;
@property(nonatomic) BOOL masked;
@property(nonatomic) BOOL more;
@end

@implementation SRLibraryListScreen
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"消息库";
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
    if (self.problem) return @"本页只读，不会创建、删除或发送任何条目。";
    return @"本页只读：条目来自本账号的消息库，不提供导入、编辑、删除、清理或派发。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"library"] ?:
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"library"];
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
        cell.textLabel.text = @"消息库还没有条目";
        cell.detailTextLabel.text = @"本版不提供导入；条目只由已确认的内容产生。";
        return cell;
    }
    if (path.row == (NSInteger)self.rows.count) {
        cell.textLabel.text = @"加载更多";
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    NSDictionary *row = self.rows[(NSUInteger)path.row];
    cell.textLabel.text = [SRMediaProjection libraryKindText:row[@"kind"]];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ 个版本\n更新于 %@ · 条目 %@",
        row[@"kind"] ?: @"未记录", row[@"versionCount"] ?: @0,
        [SRRunProjection localDateTimeText:row[@"updated_at"]], SRLibraryShortID(row[@"id"])];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
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
        self.verifyAccount, identifier) animated:YES];
}
@end

/* ------------------------------------------------------------------------ */
/* 条目详情                                                                  */
/* ------------------------------------------------------------------------ */

@interface SRLibraryItemScreen : UITableViewController
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) BOOL (^verifyAccount)(void);
@property(nonatomic, copy) NSString *item;
@property(nonatomic, copy, nullable) NSDictionary *entry;
@property(nonatomic, strong) NSArray *versions;
@property(nonatomic, copy, nullable) NSDictionary *problem;
@property(nonatomic) BOOL accountInvalid;
@property(nonatomic) BOOL masked;
@end

@implementation SRLibraryItemScreen
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"条目详情";
    SRStyleSettingsTable(self);
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
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
    [self.tableView reloadData];
}
- (void)becameActive:(__unused NSNotification *)notification {
    if (!self.viewIfLoaded.window) return;
    if (![self verified]) {
        self.accountInvalid = YES; self.masked = NO;
        self.entry = nil; self.versions = @[]; self.problem = nil;
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
    self.entry = nil; self.versions = @[]; self.problem = nil; self.masked = NO;
    self.accountInvalid = ![self verified];
    if (self.accountInvalid) { [self.refreshControl endRefreshing]; [self.tableView reloadData]; return; }
    NSError *error = nil;
    NSDictionary *entry = [self.store libraryItem:self.item account:self.account error:&error];
    if (!entry) self.problem = @{@"title": @"读取失败",
        @"message": error.localizedDescription ?: @"无法读取该条目，请下拉重试。"};
    else {
        self.entry = entry;
        NSArray *versions = [entry[@"versions"] isKindOfClass:NSArray.class] ? entry[@"versions"] : @[];
        self.versions = versions;
    }
    [self.refreshControl endRefreshing];
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (self.masked || self.accountInvalid || self.problem) ? 1 : 2;
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.masked || self.accountInvalid || self.problem) return 1;
    if (section == 0) return 5;
    return self.versions.count ? (NSInteger)self.versions.count : 1;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.masked) return @"内容已隐藏";
    if (self.accountInvalid) return @"账号";
    if (self.problem) return @"读取已停止";
    return section == 0 ? @"条目" : @"版本（只读）";
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.masked) return @"离开前台时已清除本页显示；回到前台会重新核对账号后再读取。";
    if (self.accountInvalid) return @"当前账号无法核对或已经改变，本页已失去显示资格。";
    if (self.problem) return @"本页只读，不会创建、删除或发送任何条目。";
    if (section == 0) return @"条目只属于打开本页时的账号；数量与版本以持久记录为准。";
    return @"本页不渲染媒体、不准备素材、不调用宿主图片接口，也不提供编辑、删除或派发。";
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
    if (![self verified]) { self.accountInvalid = YES; [self.tableView reloadData]; return; }
    if (self.problem) { [self reload]; return; }
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

UIViewController *SRCreateLibraryList(SRStore *store, NSString *account, BOOL (^verifyAccount)(void)) {
    SRLibraryListScreen *screen = [[SRLibraryListScreen alloc] initWithStyle:UITableViewStyleGrouped];
    screen.store = store; screen.account = account; screen.verifyAccount = verifyAccount;
    screen.rows = [NSMutableArray array];
    return screen;
}
UIViewController *SRCreateLibraryItem(SRStore *store, NSString *account, BOOL (^verifyAccount)(void), NSString *item) {
    SRLibraryItemScreen *screen = [[SRLibraryItemScreen alloc] initWithStyle:UITableViewStyleGrouped];
    screen.store = store; screen.account = account; screen.verifyAccount = verifyAccount;
    screen.item = item; screen.versions = @[];
    return screen;
}
UIViewController *SRCreateMediaResources(SRStore *store, NSString *account, BOOL (^verifyAccount)(void)) {
    SRMediaResourcesScreen *screen = [[SRMediaResourcesScreen alloc] initWithStyle:UITableViewStyleGrouped];
    screen.store = store; screen.account = account; screen.verifyAccount = verifyAccount;
    screen.resources = @[];
    return screen;
}
