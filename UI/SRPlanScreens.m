#import "SRPlanScreens.h"
#import "Core/SRStore.h"
#import "Core/SRSourceCapture.h"

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
    return [NSString stringWithFormat:@"%@\n已确认 %@ · 失败 %@ · 待核对 %@\n未发 %@ · 在途 %@ · 已取消 %@", state,
        counts[@"confirmed"] ?: @0, counts[@"failed"] ?: @0, counts[@"uncertain"] ?: @0,
        counts[@"pending"] ?: @0, counts[@"submitting"] ?: @0, counts[@"cancelled"] ?: @0];
}
static void SRScreenAlert(UIViewController *controller, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

@interface SRRecordScreen : UITableViewController
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, strong) SRSourceCapture *capture;
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
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 76;
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (void)becameActive:(__unused NSNotification *)notification { if (self.viewIfLoaded.window) [self reload]; }
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
    return [text isKindOfClass:NSString.class] ? text : @"本版没有可验证的媒体预览，不把媒体引用当作已缓存图片。";
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
    if (self.kind == SRRecordPreview && section == 2) return @"确认只建立内容计划和目标分组，不发送。所有规则使用同一条已确认内容；之后修改草稿不会改变此计划。";
    if (self.kind == SRRecordPlan && section == 1) return @"点击规则查看历史及异常。真实发送适配尚未启用，本版不提供可用的开始、继续或重新执行按钮；顺序解锁也不会自动发送。";
    if (self.kind == SRRecordHistory) return @"按执行批次保留历史。完成时间取真实结束记录，不使用当前打开时间；点击批次查看失败、待核对和取消项。";
    if (self.kind == SRRecordExceptions) return @"不逐条列出成功群。待核对不等于失败，不能盲目重试；取消项代表未继续派发，不伪报为成功。";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"record"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"record"];
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.textColor = UIColor.labelColor; cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
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
        cell.detailTextLabel.text = run ? SRRunDescription(run) : ([row[@"initialUnlocked"] boolValue] ? @"未执行 · 顺序已解锁（本版发送未启用）" : @"未执行 · 等待前序规则结束");
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
    SRRecordScreen *screen = [[SRRecordScreen alloc] initWithStyle:UITableViewStyleInsetGrouped];
    screen.kind = kind; screen.store = self.store; screen.account = self.account; screen.verifyAccount = self.verifyAccount;
    screen.identifier = identifier; screen.title = title; return screen;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (![self verified] || self.problem) return;
    if ((self.kind == SRRecordPreview || self.kind == SRRecordPlan) && path.section == 0) {
        if (path.row == 4) {
            UIViewController *viewer = [[UIViewController alloc] init]; viewer.title = @"源消息内容";
            UITextView *text = [[UITextView alloc] init]; text.editable = NO;
            text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; text.adjustsFontForContentSizeCategory = YES;
            text.backgroundColor = UIColor.systemBackgroundColor;
            text.text = [self sourceText];
            viewer.view = text; [self.navigationController pushViewController:viewer animated:YES];
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
    if (self.kind == SRRecordPlan) next = [self screen:SRRecordHistory identifier:row[@"id"] title:[row[@"name"] stringByAppendingString:@" · 历史"]];
    if (self.kind == SRRecordHistory) next = [self screen:SRRecordExceptions identifier:row[@"id"] title:@"异常群与未发项"];
    if (next) [self.navigationController pushViewController:next animated:YES];
}
@end

UIViewController *SRCreateCapturePreview(SRStore *store, SRSourceCapture *capture, NSString *account, BOOL (^verifyAccount)(void)) {
    SRRecordScreen *screen = [[SRRecordScreen alloc] initWithStyle:UITableViewStyleInsetGrouped];
    screen.kind = SRRecordPreview; screen.store = store; screen.capture = capture; screen.account = account;
    screen.verifyAccount = verifyAccount; screen.title = @"单条源消息预览"; return screen;
}
UIViewController *SRCreatePlanList(SRStore *store, NSString *account, BOOL (^verifyAccount)(void)) {
    SRRecordScreen *screen = [[SRRecordScreen alloc] initWithStyle:UITableViewStyleInsetGrouped];
    screen.kind = SRRecordPlans; screen.store = store; screen.account = account;
    screen.verifyAccount = verifyAccount; screen.title = @"已确认内容计划"; return screen;
}
