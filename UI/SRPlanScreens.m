#import "SRPlanScreens.h"
#import "SRNativeStyle.h"
#import "Core/SRStore.h"
#import "Core/SRSourceCapture.h"
#import "Core/SRImageAssetStore.h"
#import "Adapter/SRSmallGroupSession.h"

NSString *const SRRelayStateChangedNotification = @"andyz.syncrelay.stateChanged";
typedef NS_ENUM(NSUInteger, SRRecordKind) { SRRecordPreview, SRRecordPlans, SRRecordPlan, SRRecordHistory, SRRecordExceptions };

static NSString *SRDate(id value) {
    if (![value isKindOfClass:NSNumber.class] || [value doubleValue] <= 0) return @"时间未记录";
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = NSTimeZone.localTimeZone; formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[value doubleValue]]];
}
static NSString *SRRunDescription(NSDictionary *run) {
    NSString *state = @{@"running": @"执行中", @"paused": @"已暂停", @"awaiting_resume": @"待手动继续",
        @"completed": @"执行完成", @"ended": @"执行已结束"}[run[@"state"]] ?: @"状态待核对";
    if ([@[@"completed", @"ended"] containsObject:run[@"state"]]) state = [NSString stringWithFormat:@"%@ %@", SRDate(run[@"ended_at"]), state];
    NSDictionary *counts = run[@"counts"];
    return [NSString stringWithFormat:@"%@\n已提交 %@ · 已确认送达 %@\n失败 %@ · 结果未知 %@\n未发 %@ · 在途 %@ · 已取消 %@", state,
        counts[@"submitted"] ?: @0, counts[@"confirmed"] ?: @0, counts[@"failed"] ?: @0, counts[@"uncertain"] ?: @0,
        counts[@"pending"] ?: @0, counts[@"submitting"] ?: @0, counts[@"cancelled"] ?: @0];
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
        NSDictionary *status = self.capture.status;
        if ([status[@"account"] isEqual:self.account] && self.capture.preview) {
            self.content = self.capture.preview; self.configuration = status[@"configuration"];
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
    if (self.kind == SRRecordPreview) return section == 0 ? 5 : (section == 1 ? 1 : 2);
    if (self.kind == SRRecordPlan) return section == 0 ? 5 : MAX((NSUInteger)1, self.rows.count);
    return MAX((NSUInteger)1, self.rows.count + (self.more ? 1 : 0));
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.problem) return @"读取已停止";
    if (self.kind == SRRecordPreview) return @[@"锁定的一条源消息", @"捕获时冻结的配置", @"确认操作"][section];
    if (self.kind == SRRecordPlan) return section == 0 ? @"已确认源消息" : @"规则与最近状态";
    return nil;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.problem) return @"本页不会创建、继续或重试发送任务。";
    if (self.kind == SRRecordPreview && section == 2) return @"确认只建立内容计划和目标分组，不发送。所有规则使用同一条已确认内容；之后修改设置不会改变此计划。";
    if (self.kind == SRRecordPlan && section == 1) return @"点击规则可操作或查看历史。本轮只开放每条 1–20 个授权测试群：开始后串行转发，暂停后手动继续；大规则和重新执行尚未开放。请保持微信前台，切后台或锁屏会暂停，不自动接下一条。";
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
        cell.textLabel.text = @[@"母群 ID", @"实际发送者 wxid", @"源消息类型", @"源消息 ID", @"消息内容（点开完整查看）"][path.row];
        NSArray *values = @[source[@"group"] ?: @"未记录", source[@"sender"] ?: @"未记录", source[@"type"] ?: @"未记录", source[@"messageID"] ?: @"未记录"];
        if (path.row < 4) cell.detailTextLabel.text = values[path.row];
        else {
            NSString *text = [self sourceText];
            NSRange range = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, MIN((NSUInteger)600, text.length))];
            cell.detailTextLabel.text = [text substringWithRange:range];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
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
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ 条规则 · %@ 个群\n内容计划 %@", row[@"ruleCount"], row[@"targetCount"], row[@"id"]];
    } else if (self.kind == SRRecordPlan) {
        cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@ 个群", row[@"name"], row[@"targetCount"]];
        NSDictionary *run = [row[@"latestRun"] isKindOfClass:NSDictionary.class] ? row[@"latestRun"] : nil;
        cell.detailTextLabel.text = run ? SRRunDescription(run) : ([row[@"initialUnlocked"] boolValue] ? @"未执行 · 顺序已解锁" : @"未执行 · 等待前序规则结束");
        if ([row[@"targetCount"] unsignedIntegerValue] > 20) cell.detailTextLabel.text = [cell.detailTextLabel.text stringByAppendingString:@"\n超过本轮 20 群测试范围，不提供发送入口。"];
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
- (void)performExecution:(BOOL (^)(NSError **))operation {
    if (![self verified]) return;
    NSError *error = nil;
    if (!operation(&error)) SRScreenAlert(self, @"操作未执行", error.localizedDescription ?: @"当前状态不允许此操作，请下拉刷新。");
    [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
}
- (void)ruleActions:(NSDictionary *)rule {
    NSDictionary *run = [rule[@"latestRun"] isKindOfClass:NSDictionary.class] ? rule[@"latestRun"] : nil;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:rule[@"name"]
        message:run ? SRRunDescription(run) : @"本轮支持 1–20 个群的真实串行转发测试；一次只执行这条规则。"
        preferredStyle:UIAlertControllerStyleAlert];
    if (self.execution && [rule[@"targetCount"] unsignedIntegerValue] <= 20) {
        if (!run && [rule[@"initialUnlocked"] boolValue] && ![rule[@"accountOccupied"] boolValue]) {
            [menu addAction:[UIAlertAction actionWithTitle:@"开始小群测试" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                if (![self verified]) return;
                NSError *error = nil;
                NSDictionary *preview = [self.store smallGroupRulePreview:rule[@"id"] account:self.account error:&error];
                if (!preview) { SRScreenAlert(self, @"还不能开始", error.localizedDescription); return; }
                NSString *message = [NSString stringWithFormat:@"将向这 %lu 个群串行发送已确认的 %@ 消息：\n%@\n\n每次结果处理后再等待 %@–%@ 秒；不会自动接下一条。保持微信前台，测试时可以暂停。已尝试但结果未知的群不自动重发。",
                    (unsigned long)[preview[@"targets"] count], [preview[@"source"][@"type"] isEqual:@"image"] ? @"图片" : @"文字",
                    [preview[@"targets"] componentsJoinedByString:@"\n"], preview[@"minimum"], preview[@"maximum"]];
                UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"开始真实转发？" message:message preferredStyle:UIAlertControllerStyleAlert];
                [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                [confirm addAction:[UIAlertAction actionWithTitle:@"开始这条规则" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                    [self performExecution:^BOOL(NSError **failure) { return [self.execution startRule:rule[@"id"] account:self.account error:failure]; }];
                }]];
                SRScreenPresent(self, confirm);
            }]];
        }
        if ([@[@"running", @"paused", @"awaiting_resume"] containsObject:run[@"state"]]) {
            if ([run[@"state"] isEqual:@"running"]) [menu addAction:[UIAlertAction actionWithTitle:@"暂停" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                [self performExecution:^BOOL(NSError **failure) { return [self.execution pauseForAccount:self.account error:failure]; }];
            }]];
            else [menu addAction:[UIAlertAction actionWithTitle:@"继续未尝试的群" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                [self performExecution:^BOOL(NSError **failure) { return [self.execution resumeRun:run[@"id"] account:self.account error:failure]; }];
            }]];
            [menu addAction:[UIAlertAction actionWithTitle:@"结束这次执行（不重发）" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
                [self performExecution:^BOOL(NSError **failure) { return [self.execution endRun:run[@"id"] account:self.account error:failure]; }];
            }]];
        }
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"查看历史与异常" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self.navigationController pushViewController:[self screen:SRRecordHistory identifier:rule[@"id"] title:[rule[@"name"] stringByAppendingString:@" · 历史"]] animated:YES];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    SRScreenPresent(self, menu);
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (![self verified] || self.problem) return;
    if ((self.kind == SRRecordPreview || self.kind == SRRecordPlan) && path.section == 0) {
        if (path.row == 4) {
            if ([[self source][@"type"] isEqual:@"image"]) {
                SRSourceImageScreen *viewer = [[SRSourceImageScreen alloc] init]; viewer.title = @"源图片预览（不发送）";
                viewer.source = [self source]; viewer.assets = self.store.imageAssets; viewer.verifyAccount = self.verifyAccount;
                [self.navigationController pushViewController:viewer animated:YES]; return;
            }
            SRSourceTextScreen *viewer = [[SRSourceTextScreen alloc] init]; viewer.title = @"源消息内容";
            viewer.body = [self sourceText]; viewer.verifyAccount = self.verifyAccount;
            [self.navigationController pushViewController:viewer animated:YES];
        }
        return;
    }
    if (self.kind == SRRecordPreview) {
        if (path.section != 2) return;
        if (path.row == 1) { [self.capture cancel]; [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil]; [self.navigationController popViewControllerAnimated:YES]; return; }
        NSError *error = nil; NSString *plan = [self.capture confirmForCurrentAccount:self.account error:&error];
        if (!plan) { SRScreenAlert(self, @"确认失败，未发送", error.localizedDescription); return; }
        [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
        SRRecordScreen *next = [self screen:SRRecordPlan identifier:plan title:@"内容计划与规则"];
        NSMutableArray *stack = [self.navigationController.viewControllers mutableCopy]; stack[stack.count - 1] = next;
        [self.navigationController setViewControllers:stack animated:YES]; return;
    }
    if (path.row == (NSInteger)self.rows.count && self.more) { [self loadPage]; return; }
    if (path.row >= (NSInteger)self.rows.count) return;
    NSDictionary *row = self.rows[path.row]; SRRecordScreen *next = nil;
    if (self.kind == SRRecordPlans) next = [self screen:SRRecordPlan identifier:row[@"id"] title:@"内容计划与规则"];
    if (self.kind == SRRecordPlan) { [self ruleActions:row]; return; }
    if (self.kind == SRRecordHistory) next = [self screen:SRRecordExceptions identifier:row[@"id"] title:@"异常群与未发项"];
    if (next) [self.navigationController pushViewController:next animated:YES];
}
@end

UIViewController *SRCreateCapturePreview(SRStore *store, SRSourceCapture *capture, NSString *account, BOOL (^verifyAccount)(void), SRSmallGroupSession *execution) {
    SRRecordScreen *screen = [[SRRecordScreen alloc] initWithStyle:UITableViewStyleGrouped];
    screen.kind = SRRecordPreview; screen.store = store; screen.capture = capture; screen.account = account;
    screen.verifyAccount = verifyAccount; screen.execution = execution; screen.title = @"单条源消息预览"; return screen;
}
UIViewController *SRCreatePlanList(SRStore *store, NSString *account, BOOL (^verifyAccount)(void), SRSmallGroupSession *execution) {
    SRRecordScreen *screen = [[SRRecordScreen alloc] initWithStyle:UITableViewStyleGrouped];
    screen.kind = SRRecordPlans; screen.store = store; screen.account = account;
    screen.verifyAccount = verifyAccount; screen.execution = execution; screen.title = @"已确认内容计划"; return screen;
}
