#import "SRPanel.h"
#import "Core/SRStore.h"
#import "Core/SRSelection.h"
#import "Core/SRConfiguration.h"
#import "Core/SRGroupPlanner.h"
#import "Core/SRSourceMessage.h"
#import "Core/SRSourceCapture.h"
#import "Core/SREntryPreferences.h"
#import "Adapter/SRWeChatReader.h"
#import "Adapter/SRWeChatReceiver.h"
#import "Adapter/SRWeChatSendProbe.h"
#import "Adapter/SRWeChatSettingsEntry.h"
#import "SRPlanScreens.h"
#import "SRSettingsFallback.h"
#include <errno.h>
#include <stdlib.h>

static void SRPresentAlert(UIViewController *controller, UIAlertController *alert) {
    void (^show)(void) = ^{ [controller presentViewController:alert animated:YES completion:nil]; };
    UIViewController *presented = controller.presentedViewController;
    if ([presented isKindOfClass:UIAlertController.class]) {
        // A confirmation can follow an alert action before UIKit has finished dismissing it.
        if (presented.isBeingDismissed && [presented.transitionCoordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) { show(); }]) return;
        [presented dismissViewControllerAnimated:YES completion:show];
    } else show();
}

static void SRAlert(UIViewController *controller, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    SRPresentAlert(controller, alert);
}

static NSNumber *SRRuleCount(NSString *text) {
    if (!text.length) return @0;
    if ([text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound) return nil;
    errno = 0; char *end = NULL;
    unsigned long long value = strtoull(text.UTF8String, &end, 10);
    return errno == 0 && end && *end == '\0' && value <= NSUIntegerMax ? @(value) : nil;
}

static NSUInteger SRTargetCount(NSDictionary *draft) {
    NSUInteger count = 0;
    for (NSDictionary *rule in draft[@"rules"]) count += [rule[@"targets"] count];
    return count;
}

@interface SRPicker : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, strong) SRSelection *selection;
@property(nonatomic, copy) NSArray<NSDictionary *> *visibleRows;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic) BOOL multiple;
@property(nonatomic) BOOL excluding;
@property(nonatomic, copy) NSString *note;
@property(nonatomic, copy) void (^completion)(NSArray<NSDictionary *> *);
@end

@implementation SRPicker
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 70;
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchResultsUpdater = self;
    self.search.searchBar.placeholder = @"搜索名称或原始 ID";
    self.navigationItem.searchController = self.search;
    self.definesPresentationContext = YES;
    if (self.multiple) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:self.excluding ? @"应用排除" : @"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
        NSMutableArray *actions = [NSMutableArray array];
        NSArray *counts = self.excluding ? @[@(NSUIntegerMax), @0] : @[@100, @200, @(NSUIntegerMax), @0];
        for (NSNumber *count in counts) {
            NSString *title = self.excluding ? (count.unsignedIntegerValue ? @"排除全部可选群" : @"取消全部排除") :
                ([count unsignedIntegerValue] == NSUIntegerMax ? @"全选全部可选项" :
                ([count unsignedIntegerValue] == 0 ? @"清空选择" : [NSString stringWithFormat:@"选前 %@ 个", count]));
            __weak typeof(self) weakSelf = self;
            [actions addObject:[UIAction actionWithTitle:title image:nil identifier:nil handler:^(__unused UIAction *action) {
                [weakSelf.selection selectFirst:count.unsignedIntegerValue]; [weakSelf refresh];
            }]];
        }
        if (self.excluding) for (NSNumber *selected in @[@YES, @NO]) {
            __weak typeof(self) weakSelf = self;
            [actions addObject:[UIAction actionWithTitle:selected.boolValue ? @"排除搜索结果" : @"恢复搜索结果" image:nil identifier:nil handler:^(__unused UIAction *action) {
                [weakSelf.selection setRowsMatching:weakSelf.search.searchBar.text ?: @"" selected:selected.boolValue]; [weakSelf refresh];
            }]];
        }
        self.navigationItem.leftItemsSupplementBackButton = YES;
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"批量" menu:[UIMenu menuWithTitle:self.excluding ? @"勾选代表排除；搜索结果操作只影响当前匹配群" : @"按完整可选列表选择，不受搜索过滤影响" children:actions]];
    }
    [self refresh];
}
- (void)refresh {
    self.visibleRows = [self.selection rowsMatching:self.search.searchBar.text ?: @""];
    self.navigationItem.prompt = [NSString stringWithFormat:@"可选 %lu · %@ %lu · 搜索结果 %lu", (unsigned long)self.selection.rows.count,
        self.excluding ? @"排除" : @"已选", (unsigned long)self.selection.selectedCount, (unsigned long)self.visibleRows.count];
    self.navigationItem.rightBarButtonItem.enabled = self.excluding || self.selection.selectedCount > 0;
    [self.tableView reloadData];
}
- (void)updateSearchResultsForSearchController:(__unused UISearchController *)searchController { [self refresh]; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section { return self.visibleRows.count; }
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section { return self.note; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"contact"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"contact"];
    NSDictionary *row = self.visibleRows[indexPath.row];
    cell.textLabel.text = row[@"name"]; cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = row[@"id"]; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.accessoryType = [self.selection isSelected:row[@"id"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.visibleRows[indexPath.row];
    if (!self.multiple) {
        [self finish:@[row]]; return;
    }
    [self.selection toggle:row[@"id"]]; [self refresh];
}
- (void)done {
    if (!self.excluding && !self.selection.selectedCount) return;
    [self finish:self.selection.selectedRows];
}
- (void)finish:(NSArray *)rows {
    void (^completion)(NSArray *) = self.completion;
    UINavigationController *navigation = self.navigationController;
    [navigation popViewControllerAnimated:YES];
    if (navigation.transitionCoordinator) {
        [navigation.transitionCoordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) { completion(rows); }];
    } else completion(rows);
}
@end

@interface SRPanel : UITableViewController
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, strong) SRWeChatReader *reader;
@property(nonatomic, strong) SRWeChatReceiver *receiver;
@property(nonatomic, strong) SRWeChatSendProbe *sendProbe;
@property(nonatomic, strong) SRSourceCapture *capture;
@property(nonatomic, strong) SREntryPreferences *entryPreferences;
@property(nonatomic, strong) SRWeChatSettingsEntry *settingsEntry;
@property(nonatomic) BOOL settingsFooterActive;
@property(nonatomic, strong) NSMutableDictionary *draft;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSString *status;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL dirty;
@property(nonatomic, copy) void (^didClose)(void);
@end

@implementation SRPanel
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SyncRelay 转发";
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 64;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存草稿" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    self.reader = [[SRWeChatReader alloc] initWithVersion:version classResolver:^Class(NSString *name) { return NSClassFromString(name); }];
    self.draft = [SRConfiguration emptyDraft];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(captureChanged:) name:SRRelayStateChangedNotification object:nil];
    [self loadAccount];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.ready && ![self.reader verifyAccount:self.account error:NULL]) {
        self.ready = NO; self.status = @"账号无法核对或已经改变，请重新读取。旧草稿没有写入新账号。";
        [self.receiver stop]; [self.capture cancel];
    }
    [self refresh];
}
- (void)captureChanged:(__unused NSNotification *)notification { [self refresh]; }
- (void)loadAccount {
    NSError *error = nil;
    if (!self.store) {
        self.ready = NO; self.draft = [SRConfiguration emptyDraft]; self.dirty = NO;
        self.status = @"本地存储初始化或恢复失败；仅可查看诊断和修改入口开关，规则操作已停用。请完全退出微信后重开。";
        [self refresh]; return;
    }
    self.ready = [self.reader connect:&error];
    self.account = self.reader.accountID;
    id captureAccount = self.capture.status[@"account"];
    if (captureAccount != NSNull.null && ![captureAccount isEqual:self.account]) { [self.receiver stop]; [self.capture cancel]; }
    self.draft = [SRConfiguration emptyDraft];
    if (self.ready) {
        NSDictionary *saved = [self.store configurationForAccount:self.account error:&error];
        if (saved) self.draft = [saved mutableCopy]; else self.ready = NO;
    }
    self.dirty = NO;
    self.status = self.ready ? @"读取适配待真机核对 · 本版不会发送消息" : error.localizedDescription ?: @"无法读取账号";
    [self refresh];
}
- (BOOL)checkAccount {
    NSError *error = nil;
    if (!self.ready || ![self.reader verifyAccount:self.account error:&error]) {
        self.ready = NO;
        [self.receiver stop]; [self.capture cancel];
        self.status = error.localizedDescription ?: @"请先重新读取账号";
        [self refresh]; SRAlert(self, @"操作已停止", self.status); return NO;
    }
    return YES;
}
- (void)refresh {
    if ([self.capture.status[@"state"] isEqual:@"waiting"] && ![self.receiver.diagnostics[@"armed"] boolValue]) [self.capture cancel];
    self.navigationItem.rightBarButtonItem.enabled = self.ready;
    self.navigationItem.prompt = self.dirty ? @"有未保存的修改" : @"0.2.2 · 文字捕获候选 / 发送未启用";
    [self.tableView reloadData];
}
- (void)changed {
    self.dirty = YES;
    if ([self.capture.status[@"state"] isEqual:@"waiting"]) {
        [self.receiver stop]; [self.capture cancel];
        self.status = @"草稿已修改，旧的源消息等待已取消；保存后需重新手动等待。发送仍未启用。";
        [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
    }
    [self refresh];
}
- (void)close {
    if (!self.dirty) { [self dismissViewControllerAnimated:YES completion:self.didClose]; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"放弃未保存的修改？" message:@"已经保存的草稿不会被删除。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"放弃并关闭" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { [self dismissViewControllerAnimated:YES completion:self.didClose]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)save {
    if (![self checkAccount]) return;
    NSError *error = nil;
    if (![SRConfiguration validateDraft:self.draft error:&error] || ![self.store saveConfiguration:self.draft account:self.account error:&error]) {
        SRAlert(self, @"保存失败", error.localizedDescription); return;
    }
    self.dirty = NO; [self refresh];
    SRAlert(self, @"草稿已保存", @"下次打开会恢复该账号的统一转发条件、排除群和规则分组。保存不会创建发送任务。" );
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 5; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 5;
    if (section == 1) return 4;
    if (section == 2) return 1;
    if (section == 4) return 3;
    return [self.draft[@"rules"] count] + 3;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"适配状态", @"统一转发条件", @"统一发送节拍", @"自动分组与规则", @"单条内容与计划"][section];
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return self.status;
    if (section == 1) return @"所有草稿规则共用母群、发送者和消息类型，只需设置一次。接收为待真机核对的文字候选；图片接收和真实发送未启用。";
    if (section == 2) return @"下限至少 10 秒；上下限相同则固定间隔。随机节拍不代表平台允许或保证发送成功。";
    if (section == 4) return @"手动等待后可关闭面板回母群；仅观察其他成员的文字接收回调，不主动读取历史，不支持本人消息或图片媒体。离开前台/锁屏会取消等待，回前台不自动重启。预览确认只建立计划，不发送。";
    return @"只需搜索并勾选要排除的群，其他群自动按 100/200 个分配。母群和已分配群自动排除；不足按实际数量生成，不建空规则。生成/保存不会发送。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"setting"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"setting"];
    cell.accessoryView = nil; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.textColor = UIColor.labelColor; cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.text = nil; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (path.section == 0) {
        if (path.row == 0) { cell.textLabel.text = [@"微信 " stringByAppendingString:self.reader.version]; cell.detailTextLabel.text = self.account ?: @"账号 wxid 未读取"; cell.accessoryType = UITableViewCellAccessoryNone; cell.selectionStyle = UITableViewCellSelectionStyleNone; }
        if (path.row == 1) cell.textLabel.text = @"重新读取账号与草稿";
        if (path.row == 2) { cell.textLabel.text = @"查看适配诊断"; cell.detailTextLabel.text = @"版本、接口签名及手动观察摘要；不含 wxid、群 ID 或正文"; }
        if (path.row == 3) {
            BOOL armed = [self.sendProbe.diagnostics[@"armed"] boolValue];
            cell.textLabel.text = armed ? @"停止手动发送观察" : @"只读观察一次手动文字发送";
            cell.detailTextLabel.text = armed ? @"观察中 · 120 秒到期或切后台停止；结果见适配诊断" : @"只选一个测试群，由你手动发文字；插件不代发";
        }
        if (path.row == 4) {
            cell.textLabel.text = @"开启悬浮入口";
            cell.detailTextLabel.text = @"默认关闭；始终可从 我 → 设置 → SyncRelay 转发 进入";
            UISwitch *toggle = [[UISwitch alloc] init]; toggle.on = self.entryPreferences.floatingEntryEnabled;
            [toggle addTarget:self action:@selector(floatingEntryChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryType = UITableViewCellAccessoryNone; cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else if (path.section == 1) {
        if (path.row == 0) { cell.textLabel.text = @"母群"; cell.detailTextLabel.text = self.draft[@"sourceGroup"][@"name"] ?: @"选择消息来源群"; }
        else if (path.row == 1) { cell.textLabel.text = @"指定发送者"; cell.detailTextLabel.text = [NSString stringWithFormat:@"已选 %lu 人 · 查看 wxid", (unsigned long)[self.draft[@"senders"] count]]; }
        else {
            NSString *type = path.row == 2 ? @"text" : @"image";
            cell.textLabel.text = path.row == 2 ? @"允许文字" : @"允许图片";
            UISwitch *toggle = [[UISwitch alloc] init]; toggle.tag = path.row;
            toggle.on = [self.draft[@"types"] containsObject:type]; toggle.enabled = self.ready;
            [toggle addTarget:self action:@selector(typeChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else if (path.section == 2) {
        cell.textLabel.text = @"随机间隔";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@–%@ 秒 / 次", self.draft[@"minimum"], self.draft[@"maximum"]];
    } else if (path.section == 3) {
        NSArray *rules = self.draft[@"rules"];
        if (path.row == 0) { cell.textLabel.text = @"搜索并排除群聊"; cell.detailTextLabel.text = [NSString stringWithFormat:@"已排除 %lu 个 · 不必逐个选择转发目标", (unsigned long)[self.draft[@"excludedGroups"] count]]; }
        else if (path.row == 1) { cell.textLabel.text = @"自动分配规则"; cell.detailTextLabel.text = @"设置 100 群/条、200 群/条各生成多少条"; }
        else if (path.row == 2) { cell.textLabel.text = @"手动选择并分组（可选）"; cell.detailTextLabel.text = @"全选会拆成每条不超过 200 群，不合成大批次"; }
        else { NSDictionary *rule = rules[path.row - 3]; cell.textLabel.text = rule[@"name"]; cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 个群 · 共用统一条件 · 点击查看或移除", (unsigned long)[rule[@"targets"] count]]; }
    } else {
        NSString *state = self.capture.status[@"state"];
        if (path.row == 0) { cell.textLabel.text = [state isEqual:@"waiting"] ? @"取消等待源消息" : @"等待一条母群文字"; cell.detailTextLabel.text = @"先保存草稿，再手动开始等待；不会发送"; }
        if (path.row == 1) { cell.textLabel.text = @"预览并确认源消息"; cell.detailTextLabel.text = [state isEqual:@"preview"] ? @"已锁定一条 · 使用捕获时的冻结配置，可放弃" : ([state isEqual:@"waiting"] ? @"正在等待匹配的群、wxid 和文字类型" : @"尚无待确认内容"); }
        if (path.row == 2) { cell.textLabel.text = @"已确认内容计划与历史"; cell.detailTextLabel.text = @"查看规则状态、真实完成时间和异常群；只读"; }
    }
    if (path.section > 0 && !self.ready) cell.textLabel.textColor = UIColor.tertiaryLabelColor;
    return cell;
}
- (void)floatingEntryChanged:(UISwitch *)toggle {
    self.entryPreferences.floatingEntryEnabled = toggle.on;
}
- (void)typeChanged:(UISwitch *)toggle {
    if (![self checkAccount]) { [self refresh]; return; }
    NSMutableArray *types = [self.draft[@"types"] mutableCopy];
    NSString *type = toggle.tag == 2 ? @"text" : @"image";
    if (toggle.on) [types addObject:type]; else [types removeObject:type];
    if (!types.count) { toggle.on = YES; SRAlert(self, @"至少保留一种类型", @"请选择文字、图片或两者。"); return; }
    self.draft[@"types"] = types; [self changed];
}
- (void)picker:(NSString *)title rows:(NSArray *)rows selected:(NSArray *)selected excluded:(NSSet *)excluded multiple:(BOOL)multiple excluding:(BOOL)excluding completion:(void (^)(NSArray *))completion {
    SRPicker *picker = [[SRPicker alloc] initWithStyle:UITableViewStyleInsetGrouped];
    picker.title = title; picker.multiple = multiple; picker.excluding = excluding;
    NSString *note = [self.reader.warnings componentsJoinedByString:@"\n"];
    picker.note = excluding ? [@"勾选＝排除。可按群名或原始 ID 搜索；批量菜单支持排除/恢复搜索结果。应用后从草稿规则移除相应群；不会修改已有执行记录。\n" stringByAppendingString:note] : note;
    picker.selection = [[SRSelection alloc] initWithRows:rows excludedIDs:excluded selectedIDs:[NSSet setWithArray:[selected valueForKey:@"id"]]];
    __weak typeof(self) weakSelf = self;
    picker.completion = ^(NSArray *chosen) { if ([weakSelf checkAccount]) completion(chosen); };
    [self.navigationController pushViewController:picker animated:YES];
}
- (void)chooseSource {
    NSError *error = nil; NSArray *groups = [self.reader groups:&error];
    if (!groups) { SRAlert(self, @"无法读取群", error.localizedDescription); return; }
    __weak typeof(self) weakSelf = self;
    [self picker:@"选择母群" rows:groups selected:@[] excluded:NSSet.set multiple:NO excluding:NO completion:^(NSArray *chosen) {
        if ([chosen[0][@"id"] isEqual:weakSelf.draft[@"sourceGroup"][@"id"]]) return;
        void (^apply)(void) = ^{
            [weakSelf.receiver stop]; [weakSelf.capture cancel];
            weakSelf.draft[@"sourceGroup"] = chosen[0]; weakSelf.draft[@"senders"] = @[]; weakSelf.draft[@"rules"] = @[];
            [weakSelf changed]; [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
        };
        if ([weakSelf.draft[@"rules"] count] || [weakSelf.draft[@"senders"] count]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"更换母群？" message:@"将清空当前发送者和目标分组，并取消未确认的捕获，避免沿用错误来源。已有内容计划和保存前的旧草稿不变。" preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                [alert addAction:[UIAlertAction actionWithTitle:@"更换并清空" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { apply(); }]];
                [weakSelf presentViewController:alert animated:YES completion:nil];
            });
        } else apply();
    }];
}
- (void)chooseSenders {
    NSString *group = self.draft[@"sourceGroup"][@"id"];
    if (!group) { SRAlert(self, @"先选择母群", @"发送者必须从母群的成员中选择。"); return; }
    NSError *error = nil; NSArray *members = [self.reader membersOfGroup:group error:&error];
    if (!members) { SRAlert(self, @"无法读取成员", error.localizedDescription); return; }
    __weak typeof(self) weakSelf = self;
    [self picker:@"指定发送者 · wxid" rows:members selected:self.draft[@"senders"] excluded:NSSet.set multiple:YES excluding:NO completion:^(NSArray *chosen) {
        weakSelf.draft[@"senders"] = chosen; [weakSelf changed];
    }];
}
- (void)addRule {
    if (![self.draft[@"sourceGroup"] count]) { SRAlert(self, @"先选择母群", @"目标群必须排除母群。"); return; }
    NSError *error = nil; NSArray *groups = [self.reader groups:&error];
    if (!groups) { SRAlert(self, @"无法读取群", error.localizedDescription); return; }
    NSMutableSet *excluded = [NSMutableSet setWithObject:self.draft[@"sourceGroup"][@"id"]];
    for (NSDictionary *row in self.draft[@"excludedGroups"]) [excluded addObject:row[@"id"]];
    for (NSDictionary *rule in self.draft[@"rules"]) [excluded addObjectsFromArray:[rule[@"targets"] valueForKey:@"id"]];
    __weak typeof(self) weakSelf = self;
    [self picker:@"选择目标群 · 自动拆分" rows:groups selected:@[] excluded:excluded multiple:YES excluding:NO completion:^(NSArray *chosen) {
        NSUInteger size = chosen.count <= 100 ? 100 : 200;
        NSUInteger count = chosen.count / size + (chosen.count % size ? 1 : 0);
        [weakSelf previewGroups:chosen recipe:@[@{@"size": @(size), @"count": @(count)}]];
    }];
}
- (BOOL)checkDraft:(NSDictionary *)snapshot account:(NSString *)account {
    if (![self checkAccount]) return NO;
    if (![self.account isEqual:account] || ![self.draft isEqual:snapshot]) {
        SRAlert(self, @"配置已改变", @"旧预览未应用，请按当前账号和统一条件重新生成。"); return NO;
    }
    return YES;
}
- (void)chooseExclusions {
    NSError *error = nil; NSArray *groups = [self.reader groups:&error];
    if (!groups) { SRAlert(self, @"无法读取群", error.localizedDescription); return; }
    NSDictionary *snapshot = [SRSourceMessage frozenJSON:self.draft]; NSString *account = self.account;
    NSArray *previous = snapshot[@"excludedGroups"] ?: @[];
    // Keep excluded IDs that have temporarily disappeared from the local group list.
    NSMutableArray *rows = [groups mutableCopy]; [rows addObjectsFromArray:previous];
    __weak typeof(self) weakSelf = self;
    [self picker:@"搜索群聊 · 勾选排除" rows:rows selected:previous excluded:NSSet.set multiple:YES excluding:YES completion:^(NSArray *chosen) {
        if (![weakSelf checkDraft:snapshot account:account]) return;
        NSError *failure = nil;
        NSDictionary *candidate = [SRGroupPlanner configurationBySettingExcludedGroups:chosen inDraft:snapshot error:&failure];
        if (!candidate) { SRAlert(weakSelf, @"无法应用排除", failure.localizedDescription); return; }
        NSUInteger removed = SRTargetCount(snapshot) - SRTargetCount(candidate);
        void (^apply)(void) = ^{
            if (![weakSelf checkDraft:snapshot account:account]) return;
            weakSelf.draft = [candidate mutableCopy]; [weakSelf changed];
        };
        if (!removed) { apply(); return; }
        NSUInteger emptyRules = [snapshot[@"rules"] count] - [candidate[@"rules"] count];
        NSString *message = [NSString stringWithFormat:@"将从已有草稿规则移除 %lu 个群，并删除 %lu 条空规则。其他群不自动重排；已有执行记录不受影响。",
            (unsigned long)removed, (unsigned long)emptyRules];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"应用排除并更新草稿？" message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"应用排除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { apply(); }]];
        [weakSelf presentViewController:alert animated:YES completion:nil];
    }];
}
- (void)autoGroup {
    if (![self.draft[@"sourceGroup"] count] || ![self.draft[@"senders"] count]) {
        SRAlert(self, @"先设置统一转发条件", @"选择母群、发送者 wxid 和消息类型后，所有生成规则共用这些条件，无需逐条设置。"); return;
    }
    NSError *error = nil; NSArray *groups = [self.reader groups:&error];
    if (!groups) { SRAlert(self, @"无法读取群", error.localizedDescription); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"自动分配规则" message:@"只填写各自生成条数。先分配 100 群规则，再分配 200 群规则；0 或留空表示不生成。群不足按实际数量生成，最后一条可不足额。" preferredStyle:UIAlertControllerStyleAlert];
    for (NSNumber *size in @[@100, @200]) [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad; field.text = @"10";
        field.placeholder = [NSString stringWithFormat:@"每条 %@ 个群：生成多少条规则", size]; field.accessibilityLabel = field.placeholder;
        UILabel *label = [[UILabel alloc] init]; label.text = [NSString stringWithFormat:@"%@ 群/条 × ", size];
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]; [label sizeToFit];
        field.leftView = label; field.leftViewMode = UITextFieldViewModeAlways;
    }];
    NSDictionary *snapshot = [SRSourceMessage frozenJSON:self.draft]; NSString *account = self.account;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"查看分配预览" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (![self checkDraft:snapshot account:account]) return;
        NSNumber *hundreds = SRRuleCount(weakAlert.textFields[0].text), *twoHundreds = SRRuleCount(weakAlert.textFields[1].text);
        if (!hundreds || !twoHundreds || (!hundreds.unsignedIntegerValue && !twoHundreds.unsignedIntegerValue)) {
            SRAlert(self, @"条数无效", @"请输入非负整数，并至少生成一条规则。"); return;
        }
        [self previewGroups:groups recipe:@[@{@"size": @100, @"count": hundreds}, @{@"size": @200, @"count": twoHundreds}]];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)previewGroups:(NSArray *)groups recipe:(NSArray *)recipe {
    if (![self checkAccount]) return;
    NSDictionary *snapshot = [SRSourceMessage frozenJSON:self.draft]; NSString *account = self.account;
    NSError *error = nil;
    NSDictionary *preview = [SRGroupPlanner previewWithRows:groups draft:snapshot recipe:recipe error:&error];
    if (!preview) { SRAlert(self, @"无法生成分组", error.localizedDescription); return; }
    if (![preview[@"generatedRuleCount"] unsignedIntegerValue]) {
        SRAlert(self, @"没有新增规则", [NSString stringWithFormat:@"本次要求 %@ 个群，实际可分配 0 个。请检查排除项和已有规则；不生成空规则，原有草稿不变。", preview[@"requestedCount"]]); return;
    }
    NSMutableArray *typeNames = [NSMutableArray array];
    for (NSString *type in snapshot[@"types"]) [typeNames addObject:[type isEqual:@"text"] ? @"文字" : @"图片"];
    NSMutableString *message = [NSMutableString stringWithFormat:@"统一条件\n母群：%@\n%@\n发送者：%lu 人（按 wxid）\n类型：%@\n间隔：%@–%@ 秒\n\n",
        snapshot[@"sourceGroup"][@"name"], snapshot[@"sourceGroup"][@"id"], (unsigned long)[snapshot[@"senders"] count], [typeNames componentsJoinedByString:@"、"], snapshot[@"minimum"], snapshot[@"maximum"]];
    for (NSDictionary *batch in preview[@"batches"]) if ([batch[@"count"] unsignedIntegerValue])
        [message appendFormat:@"%@ 群/条 × %@ 条 → 实际 %@ 条、%@ 群\n", batch[@"size"], batch[@"count"], batch[@"generatedCount"], batch[@"assignedCount"]];
    [message appendFormat:@"\n本次可分配 %@ 群，新增 %@ 条规则、%@ 群。\n不足 %@ 群，末尾不足额 %@ 条；剩余未分配 %@ 群。\n\n母群、排除群、已分配群不会重复选入。群列表仅以当前接口返回为准。\n这里只生成草稿，不发送；后续每条仍需手动开始，不会自动接着执行。",
        preview[@"availableCount"], preview[@"generatedRuleCount"], preview[@"assignedCount"], preview[@"shortfallCount"], preview[@"partialRuleCount"], preview[@"remainingCount"]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"自动分组预览" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确认生成（不发送）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (![self checkDraft:snapshot account:account]) return;
        self.draft = [preview[@"configuration"] mutableCopy]; [self changed];
    }]];
    SRPresentAlert(self, alert);
}
- (void)editInterval {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"随机间隔（秒）" message:@"下限不能小于 10，上限不能小于下限。" preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *key in @[@"minimum", @"maximum"]) [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad; field.text = [self.draft[key] stringValue]; field.placeholder = [key isEqual:@"minimum"] ? @"下限" : @"上限";
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (![self checkAccount]) return;
        NSMutableDictionary *candidate = [self.draft mutableCopy];
        for (NSUInteger i = 0; i < 2; i++) {
            NSString *text = weakAlert.textFields[i].text ?: @"";
            if (!text.length || [text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) {
                SRAlert(self, @"间隔无效", @"请输入完整的整数秒。"); return;
            }
            candidate[i == 0 ? @"minimum" : @"maximum"] = @([text doubleValue]);
        }
        NSError *error = nil;
        if (![SRConfiguration validateDraft:candidate error:&error]) { SRAlert(self, @"间隔无效", error.localizedDescription); return; }
        self.draft = candidate; [self changed];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showRule:(NSUInteger)index {
    NSDictionary *rule = self.draft[@"rules"][index];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:rule[@"name"] message:@"共用本计划的母群、发送者 wxid、类型和间隔，不需要单独配置。此分组尚未执行；移除后，其中的群可重新分配。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"查看目标" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self picker:rule[@"name"] rows:rule[@"targets"] selected:@[] excluded:NSSet.set multiple:NO excluding:NO completion:^(NSArray *chosen) {
            SRAlert(self, chosen[0][@"name"], chosen[0][@"id"]);
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"移除分组" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        if (![self checkAccount]) return;
        NSMutableArray *rules = [self.draft[@"rules"] mutableCopy]; [rules removeObjectAtIndex:index];
        self.draft[@"rules"] = rules; [self changed];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showDiagnostics {
    NSMutableDictionary *report = [[self.reader diagnostics] mutableCopy];
    report[@"settingsEntry"] = self.settingsEntry.diagnostics;
    report[@"settingsFooterRecoveryActive"] = @(self.settingsFooterActive);
    report[@"storageReady"] = @(self.store != nil);
    report[@"floatingEntryEnabled"] = @(self.entryPreferences.floatingEntryEnabled);
    report[@"receiveCandidate"] = self.receiver.diagnostics;
    report[@"manualSendObservation"] = self.sendProbe.diagnostics;
    report[@"iOS"] = UIDevice.currentDevice.systemVersion;
    report[@"wechatBuild"] = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
    NSString *text = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL] encoding:NSUTF8StringEncoding];
    UIViewController *viewer = [[UIViewController alloc] init]; viewer.title = @"适配诊断";
    UITextView *view = [[UITextView alloc] init]; view.editable = NO; view.text = text;
    view.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; view.adjustsFontForContentSizeCategory = YES;
    view.backgroundColor = UIColor.systemBackgroundColor; viewer.view = view;
    viewer.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:[UIAction actionWithTitle:@"复制" image:nil identifier:nil handler:^(__unused UIAction *action) {
        UIPasteboard.generalPasteboard.string = text;
    }]];
    [self.navigationController pushViewController:viewer animated:YES];
}
- (void)beginSendProbe {
    if ([self.sendProbe.diagnostics[@"armed"] boolValue]) { [self.sendProbe stop]; return; }
    if (![self checkAccount]) return;
    if ([self.capture.status[@"state"] isEqual:@"waiting"]) {
        SRAlert(self, @"请先取消源消息等待", @"手动发送观察与源消息等待分开验证，避免混淆本轮测试。已有预览不会被观察覆盖。"); return;
    }
    NSError *error = nil; NSArray *groups = [self.reader groups:&error];
    if (!groups) { SRAlert(self, @"无法读取测试群", error.localizedDescription); return; }
    NSString *account = self.account; __weak typeof(self) weakSelf = self;
    [self picker:@"仅选一个授权测试群" rows:groups selected:@[] excluded:NSSet.set multiple:NO excluding:NO completion:^(NSArray *chosen) {
        SRPanel *panel = weakSelf; if (!panel) return;
        NSString *group = chosen.firstObject[@"id"];
        NSString *instruction = [NSString stringWithFormat:@"关闭面板，120 秒内到“%@”手动发送一条普通文字。请先停用其他自动发消息功能。\n\n插件仅观察原发送入口及本地消息读取，记录 ID 是否关联与原始状态码；不读取正文、不代发、不据此标记发送成功。切后台/锁屏会停止。之后返回适配诊断复制报告。", chosen.firstObject[@"name"]];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"开启只读发送观察？" message:instruction preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"开启观察（不代发）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            if (![panel checkAccount] || ![panel.account isEqual:account]) return;
            if ([panel.capture.status[@"state"] isEqual:@"waiting"]) { SRAlert(panel, @"先取消源消息等待", @"本次观察未开启。"); return; }
            NSError *failure = nil;
            if (![panel.sendProbe armForAccount:account targetGroup:group error:&failure]) SRAlert(panel, @"观察候选不可用", failure.localizedDescription);
        }]];
        SRPresentAlert(panel, alert);
    }];
}
- (BOOL (^)(void))planVerifier {
    SRWeChatReader *reader = self.reader; NSString *account = self.account;
    SRSourceCapture *capture = self.capture; SRWeChatReceiver *receiver = self.receiver;
    return ^BOOL {
        if ([reader verifyAccount:account error:NULL]) return YES;
        [receiver stop]; [capture cancel];
        [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil]; return NO;
    };
}
- (void)showCapture {
    if (![self.capture.status[@"state"] isEqual:@"preview"]) { SRAlert(self, @"还没有源消息预览", @"请先手动开始等待，再由指定成员在母群发送一条文字并核对预览。"); return; }
    [self.navigationController pushViewController:SRCreateCapturePreview(self.store, self.capture, self.account, [self planVerifier]) animated:YES];
}
- (void)beginCapture {
    if ([self.sendProbe.diagnostics[@"armed"] boolValue]) { SRAlert(self, @"请先停止手动发送观察", @"两种诊断分开进行；停止观察不会发送或修改规则。"); return; }
    NSString *state = self.capture.status[@"state"];
    if ([state isEqual:@"waiting"]) {
        [self.receiver stop]; [self.capture cancel];
        [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil]; return;
    }
    if ([state isEqual:@"preview"]) { [self showCapture]; return; }
    if (self.dirty) { SRAlert(self, @"请先保存草稿", @"捕获使用一份冻结配置；先保存统一条件和规则，再等待源消息，避免使用未确认的设置。"); return; }
    if (![self.draft[@"types"] containsObject:@"text"]) { SRAlert(self, @"图片捕获尚未开放", @"当前候选只能核对文字，不能猜测图片媒体路径。图片配置会保留，但本轮不能仅等待图片。"); return; }
    BOOL otherSender = NO;
    for (NSDictionary *sender in self.draft[@"senders"]) if (![sender[@"id"] isEqual:self.account]) otherSender = YES;
    if (!otherSender) { SRAlert(self, @"请选择母群的其他来源成员", @"当前接收候选不把本人发送或回显当作收到的新消息。请先核对来源 wxid。"); return; }
    NSDictionary *snapshot = [SRSourceMessage frozenJSON:self.draft]; NSString *account = self.account;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"手动等待一条母群文字？" message:@"仅观察指定母群和 wxid，锁定进入接收回调的第一条匹配文字后停止。候选尚未真机验证，可能包含离线补同步，请核对预览；切后台会取消等待。预览和确认都不会发送。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"开始等待（不发送）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (![self checkDraft:snapshot account:account]) return;
        NSError *error = nil;
        if (![self.capture armForAccount:account configuration:snapshot error:&error]) { SRAlert(self, @"无法开始等待", error.localizedDescription); return; }
        if (![self.receiver armForAccount:account sourceGroup:snapshot[@"sourceGroup"][@"id"] error:&error]) {
            [self.capture cancel]; SRAlert(self, @"接收候选不可用", error.localizedDescription); return;
        }
        [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
    }]];
    SRPresentAlert(self, alert);
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 0) {
        if (path.row == 1) {
            if (self.dirty) { SRAlert(self, @"有未保存的修改", @"请先保存，或关闭并放弃修改后重新打开。"); return; }
            [self loadAccount];
        }
        if (path.row == 2) [self showDiagnostics];
        if (path.row == 3) [self beginSendProbe];
        return;
    }
    if (![self checkAccount]) return;
    if (path.section == 1 && path.row == 0) [self chooseSource];
    if (path.section == 1 && path.row == 1) [self chooseSenders];
    if (path.section == 2) [self editInterval];
    if (path.section == 4) {
        if (path.row == 0) [self beginCapture];
        if (path.row == 1) [self showCapture];
        if (path.row == 2) [self.navigationController pushViewController:SRCreatePlanList(self.store, self.account, [self planVerifier]) animated:YES];
    }
    if (path.section == 3) {
        if (path.row == 0) [self chooseExclusions];
        else if (path.row == 1) [self autoGroup];
        else if (path.row == 2) [self addRule];
        else [self showRule:path.row - 3];
    }
}
@end

@interface SREntry : NSObject
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, strong) UIButton *button;
@property(nonatomic, strong) SRSourceCapture *capture;
@property(nonatomic, strong) SRWeChatReceiver *receiver;
@property(nonatomic, strong) SRWeChatSendProbe *sendProbe;
@property(nonatomic, strong) SRWeChatReader *identityReader;
@property(nonatomic, strong) SREntryPreferences *entryPreferences;
@property(nonatomic, strong) SRWeChatSettingsEntry *settingsEntry;
@property(nonatomic) BOOL settingsFooterActive;
@property(nonatomic, weak) UINavigationController *presented;
@end
@implementation SREntry
- (void)refreshVisibleSettings {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow || window.windowLevel != UIWindowLevelNormal || !window.rootViewController) continue;
            UIViewController *visible = window.rootViewController;
            for (NSUInteger depth = 0; visible && depth < 24; depth++) {
                if (visible.presentedViewController) visible = visible.presentedViewController;
                else if ([visible isKindOfClass:UINavigationController.class]) visible = ((UINavigationController *)visible).visibleViewController;
                else if ([visible isKindOfClass:UITabBarController.class]) visible = ((UITabBarController *)visible).selectedViewController;
                else { if (visible.viewIfLoaded.window) [self.settingsEntry refreshController:visible]; break; }
            }
        }
    }
}
- (void)prepareCapture {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    self.capture = [[SRSourceCapture alloc] initWithStore:self.store];
    self.identityReader = [[SRWeChatReader alloc] initWithVersion:version classResolver:^Class(NSString *name) { return NSClassFromString(name); }];
    __weak typeof(self) weakSelf = self;
    self.receiver = [[SRWeChatReceiver alloc] initWithVersion:version classResolver:^Class(NSString *name) { return NSClassFromString(name); }
        currentAccount:^NSString * {
            SREntry *entry = weakSelf; if (!entry) return nil;
            NSString *current = [entry.identityReader connect:NULL] ? entry.identityReader.accountID : nil;
            id expected = entry.capture.status[@"account"];
            if (expected != NSNull.null && ![expected isEqual:current]) {
                [entry.capture cancel]; [entry.receiver stop];
                [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
            }
            return current;
        } received:^(NSDictionary *message) {
            SREntry *entry = weakSelf;
            if ([entry.capture offerEnvelope:message]) {
                [entry.receiver stop]; [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
            }
        }];
    self.sendProbe = [[SRWeChatSendProbe alloc] initWithVersion:version classResolver:^Class(NSString *name) { return NSClassFromString(name); }
        currentAccount:^NSString * {
            SREntry *entry = weakSelf; if (!entry) return nil;
            return [entry.identityReader connect:NULL] ? entry.identityReader.accountID : nil;
        } clock:^double { return NSProcessInfo.processInfo.systemUptime; } changed:^{
            [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
        }];
}
- (void)install {
    [self.settingsEntry install:NULL];
    [self refreshVisibleSettings];
    if (!self.entryPreferences.floatingEntryEnabled) {
        [self.button removeFromSuperview]; self.button = nil; return;
    }
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSString *title = self.capture.preview ? @"预览" : ([self.sendProbe.diagnostics[@"armed"] boolValue] ? @"观察" : @"同步");
    [self.button setTitle:title forState:UIControlStateNormal];
    self.button.hidden = self.presented.presentingViewController != nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow || window.windowLevel != UIWindowLevelNormal || !window.rootViewController) continue;
            if (self.button.superview == window) return;
            [self.button removeFromSuperview];
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            [button setTitle:title forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
            button.titleLabel.adjustsFontForContentSizeCategory = YES;
            button.backgroundColor = UIColor.secondarySystemBackgroundColor; button.layer.cornerRadius = 22;
            button.accessibilityLabel = @"打开 SyncRelay 转发";
            [button addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
            button.translatesAutoresizingMaskIntoConstraints = NO; [window addSubview:button];
            [NSLayoutConstraint activateConstraints:@[
                [button.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-16],
                [button.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-72],
                [button.widthAnchor constraintGreaterThanOrEqualToConstant:64], [button.heightAnchor constraintGreaterThanOrEqualToConstant:44]
            ]];
            self.button = button; self.button.hidden = self.presented.presentingViewController != nil; return;
        }
    }
}
- (void)open {
    [self openFromController:nil];
}
- (void)openFromController:(UIViewController *)controller {
    if (!NSThread.isMainThread || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (self.presented.presentingViewController) return;
    UIViewController *presenter = controller;
    if (!presenter) for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow && window.windowLevel == UIWindowLevelNormal) { presenter = window.rootViewController; break; }
        }
        if (presenter) break;
    }
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter || presenter.isBeingDismissed || presenter.isBeingPresented || [presenter isKindOfClass:UIAlertController.class]) return;
    SRPanel *panel = [[SRPanel alloc] initWithStyle:UITableViewStyleInsetGrouped]; panel.store = self.store;
    panel.capture = self.capture; panel.receiver = self.receiver;
    panel.sendProbe = self.sendProbe;
    panel.entryPreferences = self.entryPreferences; panel.settingsEntry = self.settingsEntry;
    panel.settingsFooterActive = self.settingsFooterActive;
    __weak typeof(self) weakSelf = self;
    panel.didClose = ^{ weakSelf.presented = nil; [weakSelf install]; };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:panel];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    self.presented = navigation;
    self.button.hidden = YES;
    [presenter presentViewController:navigation animated:YES completion:nil];
}
- (void)windowChanged:(__unused NSNotification *)notification {
    if (NSThread.isMainThread) [self install];
    else dispatch_async(dispatch_get_main_queue(), ^{ [self install]; });
}
- (void)resigningActive:(__unused NSNotification *)notification {
    [self.sendProbe cancelForInactivity];
    [self.receiver stop];
    if ([self.capture.status[@"state"] isEqual:@"waiting"]) [self.capture cancel];
    [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
}
@end

void SRInstallPanelEntry(SRStore *store) {
    NSCAssert(NSThread.isMainThread, @"UI entry must be installed on main thread");
    static SREntry *entry;
    if (entry) return;
    entry = [[SREntry alloc] init]; entry.store = store;
    entry.entryPreferences = [[SREntryPreferences alloc] initWithDefaults:NSUserDefaults.standardUserDefaults];
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    __weak SREntry *weakEntry = entry;
    entry.settingsEntry = [[SRWeChatSettingsEntry alloc] initWithVersion:version classResolver:^Class(NSString *name) { return NSClassFromString(name); }
        open:^(id controller) { if ([controller isKindOfClass:UIViewController.class]) [weakEntry openFromController:controller]; }];
    entry.settingsEntry.updated = ^(id controller, BOOL present) {
        if (![controller isKindOfClass:UIViewController.class]) return;
        weakEntry.settingsFooterActive = SRUpdateSettingsFallback(controller, present, ^(UIViewController *host) {
            [weakEntry openFromController:host];
        });
    };
    if (store) [entry prepareCapture];
    [NSNotificationCenter.defaultCenter addObserver:entry selector:@selector(windowChanged:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:entry selector:@selector(windowChanged:) name:UIWindowDidBecomeKeyNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:entry selector:@selector(windowChanged:) name:SRRelayStateChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:entry selector:@selector(windowChanged:) name:SREntryPreferencesChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:entry selector:@selector(resigningActive:) name:UIApplicationWillResignActiveNotification object:nil];
    [entry install];
}
