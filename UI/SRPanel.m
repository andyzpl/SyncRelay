#import "SRPanel.h"
#import "Core/SRStore.h"
#import "Core/SRSelection.h"
#import "Core/SRConfiguration.h"
#import "Core/SRGroupPlanner.h"
#import "Core/SRSourceMessage.h"
#import "Core/SRSourceCapture.h"
#import "Core/SREntryPreferences.h"
#import "Core/SRRuntimeLog.h"
#import "Core/SRVersion.h"
#import "Core/SRImageAssetStore.h"
#import "Core/SRExecutionProgress.h"
#import "Core/SRRunProjection.h"
#import "Adapter/SRWeChatImageSource.h"
#import "Adapter/SRWeChatImageSendProbe.h"
#import "Adapter/SRWeChatImageSendHost.h"
#import "Adapter/SRWeChatImageMaterial.h"
#import "Adapter/SRSmallGroupSession.h"
#import "Core/SRPacing.h"
#include <math.h>
#import "Adapter/SRWeChatReader.h"
#import "Adapter/SRWeChatReceiver.h"
#import "Adapter/SRSourceTimeProbe.h"
#import "Adapter/SRWeChatSendProbe.h"
#import "Adapter/SRWeChatTextSendAdapter.h"
#import "Adapter/SRWeChatTextSendHost.h"
#import "Adapter/SRWeChatSettingsEntry.h"
#import "SRPlanScreens.h"
#import "SRSettingsFallback.h"
#import "SRNativeStyle.h"
#import "SRFloatingProgress.h"
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

// Preserve action dispatch IDs while putting configuration before diagnostics.
static NSInteger SRPanelSection(NSInteger displayedSection) {
    static const NSInteger sections[] = {1, 2, 3, 4, 0};
    return sections[displayedSection];
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
    SRStyleSettingsTable(self);
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
    SRStyleSettingsCell(cell);
    NSDictionary *row = self.visibleRows[indexPath.row];
    cell.textLabel.text = row[@"name"]; cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = row[@"id"]; cell.detailTextLabel.numberOfLines = 0;
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
@property(nonatomic, strong) SRSourceTimeProbe *sourceTimeProbe;
@property(nonatomic, strong) SRWeChatImageSource *imageSource;
@property(nonatomic, strong) SRWeChatImageSendProbe *imageSendProbe;
@property(nonatomic, strong) SRWeChatSendProbe *sendProbe;
@property(nonatomic, strong) SRWeChatTextSendHost *textSendHost;
@property(nonatomic, strong) SRWeChatImageSendHost *imageSendHost;
@property(nonatomic, strong) SRWeChatTextSendAdapter *textSendAdapter;
@property(nonatomic, strong) SRSmallGroupSession *smallGroupSession;
@property(nonatomic, strong) SRSourceCapture *capture;
@property(nonatomic, strong) SREntryPreferences *entryPreferences;
@property(nonatomic, strong) SRWeChatSettingsEntry *settingsEntry;
@property(nonatomic) BOOL settingsFooterActive;
@property(nonatomic, strong) NSMutableDictionary *draft;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSString *status;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL dirty;
@property(nonatomic) BOOL singleTextSendEnabled;
@property(nonatomic) BOOL singleImageSendEnabled;
@property(nonatomic) BOOL imageCountdown;
@property(nonatomic) NSUInteger imageGeneration;
@property(nonatomic) BOOL textCountdown;
@property(nonatomic) NSUInteger textGeneration;
@property(nonatomic) BOOL ownsIdleTimer;
@property(nonatomic) BOOL previousIdleTimer;
/* When the panel is stacked on the operations home, closing it returns to the
 * home instead of dismissing the whole modal. The unsaved-draft guard and the
 * save semantics stay the same either way. */
@property(nonatomic) BOOL returnsToOperationsHome;
@property(nonatomic, copy) void (^didClose)(void);
@end

@implementation SRPanel
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SyncRelay 转发";
    SRStyleSettingsTable(self);
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    self.reader = [[SRWeChatReader alloc] initWithVersion:version classResolver:^Class(NSString *name) { return NSClassFromString(name); }];
    __weak typeof(self) weakSelf = self;
    self.textSendAdapter = [[SRWeChatTextSendAdapter alloc] initWithVersion:version
        classResolver:^Class(NSString *name) { return NSClassFromString(name); }
        currentAccount:^NSString * { SRPanel *panel = weakSelf; return panel && [panel.reader connect:NULL] ? panel.reader.accountID : nil; }
        environmentAllowed:^BOOL {
            SRPanel *panel = weakSelf;
            return panel && !panel.sourceTimeProbe.active && panel.singleTextSendEnabled && UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
        }
        operation:^(NSDictionary *request, SRSendCompletion completion) {
            SRPanel *panel = weakSelf;
            if (!panel) { if (completion) completion(@"uncertain", nil, @"Panel is no longer available"); return; }
            [panel.textSendHost submitRequest:request completion:completion];
        }];
    self.draft = [SRConfiguration emptyDraft];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(captureChanged:) name:SRRelayStateChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(textExperimentInactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [self loadAccount];
}
- (void)dealloc {
    if (_ownsIdleTimer) UIApplication.sharedApplication.idleTimerDisabled = _previousIdleTimer;
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)restoreTextIdleTimer {
    if (self.ownsIdleTimer) {
        self.ownsIdleTimer = NO;
        UIApplication.sharedApplication.idleTimerDisabled = self.previousIdleTimer;
    }
}
- (void)cancelImageExperiment {
    BOOL held = self.ownsIdleTimer && (self.singleImageSendEnabled || self.imageCountdown || [self.imageSendHost.diagnostics[@"observing"] boolValue]);
    self.imageGeneration++; self.imageCountdown = NO; self.singleImageSendEnabled = NO;
    [self.imageSendHost stopObservation];
    if (held) [self restoreTextIdleTimer];
}
- (void)cancelTextExperiment {
    [self cancelImageExperiment];
    self.textGeneration++; self.textCountdown = NO;
    [self.textSendHost stopObservation];
    [self restoreTextIdleTimer];
}
- (void)textExperimentInactive:(__unused NSNotification *)notification {
    [self cancelTextExperiment]; self.singleTextSendEnabled = NO;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.ready && ![self.reader verifyAccount:self.account error:NULL]) {
        [self cancelTextExperiment];
        self.ready = NO; self.status = @"账号无法核对或已经改变，请重新读取。原账号的设置没有写入新账号。";
        self.singleTextSendEnabled = NO; [self.textSendAdapter reset];
        [self.sourceTimeProbe stopForReason:SRSourceTimeProbeAccountInvalidated];
        [self.receiver stop]; [self.capture cancel];
    }
    [self refresh];
}
- (void)captureChanged:(__unused NSNotification *)notification { [self refresh]; }
- (void)loadAccount {
    [self cancelTextExperiment];
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
    self.singleTextSendEnabled = NO;
    [self.textSendAdapter reset];
    self.status = self.ready ? @"1–20 群规则测试可用 · 保存和捕获不会自动发送" : error.localizedDescription ?: @"无法读取账号";
    [self refresh];
}
- (BOOL)checkAccount {
    NSError *error = nil;
    if (!self.ready || ![self.reader verifyAccount:self.account error:&error]) {
        [self cancelTextExperiment];
        self.ready = NO;
        self.singleTextSendEnabled = NO; [self.textSendAdapter reset];
        [self.sourceTimeProbe stopForReason:SRSourceTimeProbeAccountInvalidated];
        [self.receiver stop]; [self.capture cancel];
        self.status = error.localizedDescription ?: @"请先重新读取账号";
        [self refresh]; SRAlert(self, @"操作已停止", self.status); return NO;
    }
    return YES;
}
- (void)refresh {
    if ([self.capture.status[@"state"] isEqual:@"waiting"] && ![self.receiver.diagnostics[@"armed"] boolValue]) {
        NSString *imageState = self.receiver.diagnostics[@"imageState"];
        if ([@[@"timed_out", @"preparation_failed", @"identity_conflict"] containsObject:imageState ?: @""])
            self.status = [imageState isEqual:@"timed_out"] ? @"图片资源等待超时；请在母群点开加载后重新等待新图。可导出运行诊断。" : @"图片捕获已停止，资源或来源校验未通过；请导出运行诊断。";
        [self.capture cancel];
    }
    self.navigationItem.rightBarButtonItem.enabled = self.ready;
    self.navigationItem.prompt = nil;
    [self.tableView reloadData];
}
- (void)changed {
    [self.sourceTimeProbe stopForReason:SRSourceTimeProbeConfigurationChanged];
    if (self.smallGroupSession.busy) [self.smallGroupSession pauseForAccount:self.account error:NULL];
    [self cancelTextExperiment];
    self.dirty = YES;
    if ([self.capture.status[@"state"] isEqual:@"waiting"]) {
        [self.receiver stop]; [self.capture cancel];
        self.status = @"设置已修改，旧的源消息等待已取消；保存后需重新手动等待。不会自动发送。";
        [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
    }
    [self refresh];
}
- (void)close {
    [self cancelTextExperiment]; self.singleTextSendEnabled = NO;
    /* Stacked on the operations home, closing returns to the home rather than
     * dismissing the whole modal. The unsaved-draft guard is unchanged. */
    if (self.returnsToOperationsHome && self.navigationController.viewControllers.count > 1) {
        if (!self.dirty) { [self.navigationController popViewControllerAnimated:YES]; return; }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"放弃未保存的修改？" message:@"已经保存的设置不会被删除。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"放弃并关闭" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [self.navigationController popViewControllerAnimated:YES];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (!self.dirty) { [self dismissViewControllerAnimated:YES completion:self.didClose]; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"放弃未保存的修改？" message:@"已经保存的设置不会被删除。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"放弃并关闭" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { [self dismissViewControllerAnimated:YES completion:self.didClose]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)save {
    if (![self checkAccount]) return;
    NSError *error = nil;
    if (![SRConfiguration validateDraft:self.draft error:&error] || ![self.store saveConfiguration:self.draft account:self.account error:&error]) {
        [SRRuntimeLog.shared record:@"draft_save_failed" facts:@{@"errorCode": @(error.code)}];
        SRAlert(self, @"保存失败", error.localizedDescription); return;
    }
    self.dirty = NO; [self.sourceTimeProbe tick]; [self refresh];
    [SRRuntimeLog.shared record:@"draft_saved" facts:[self diagnosticDraft]];
    SRAlert(self, @"已保存", @"下次打开会恢复该账号的统一转发条件、排除群和规则分组。保存不会创建发送任务。" );
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 5; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    section = SRPanelSection(section);
    if (section == 0) return 10;
    if (section == 1) return 4;
    if (section == 2) return 1;
    if (section == 4) return 6;
    return [self.draft[@"rules"] count] + 3;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"来源设置", @"发送间隔", @"目标群与规则", @"源消息与计划", @"更多设置"][section];
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    section = SRPanelSection(section);
    if (section == 0) return [NSString stringWithFormat:@"SyncRelay %@ · 开发版\n%@", SR_PLUGIN_VERSION, self.status ?: @"小群测试需手动开始"];
    if (section == 1) return self.dirty ? @"修改尚未保存，请点右上角“保存”。" : @"所有规则共用来源条件；图片先捕获并预览，不自动发送。";
    if (section == 2) return @"下限至少 3 秒；默认 5–10 秒。上下限相同则固定间隔。";
    if (section == 4) return @"预览和确认不会启动规则；单群实验需单独开启并二次确认，切后台或锁屏会取消等待。";
    return @"母群自动排除，默认每条 100 群；200 群为高级规格，不足按实际数量分组。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    NSInteger section = SRPanelSection(path.section);
    BOOL accessible = UIContentSizeCategoryIsAccessibilityCategory(tableView.traitCollection.preferredContentSizeCategory);
    NSString *reuse = accessible ? @"setting-accessible" : @"setting-value";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse] ?: [[UITableViewCell alloc]
        initWithStyle:accessible ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1 reuseIdentifier:reuse];
    SRStyleSettingsCell(cell);
    cell.accessoryView = nil; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.text = nil; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (section == 0) {
        if (path.row == 0) { cell.textLabel.text = @"微信版本"; cell.detailTextLabel.text = self.reader.version; cell.accessoryType = UITableViewCellAccessoryNone; cell.selectionStyle = UITableViewCellSelectionStyleNone; }
        if (path.row == 1) { cell.textLabel.text = @"重新读取配置"; cell.detailTextLabel.text = self.ready ? @"已连接" : @"待核对"; }
        if (path.row == 2) { cell.textLabel.text = @"运行诊断"; cell.detailTextLabel.text = @"只读"; }
        if (path.row == 3) {
            BOOL armed = [self.sendProbe.diagnostics[@"armed"] boolValue];
            cell.textLabel.text = armed ? @"停止发送观察" : @"手动发送观察";
            cell.detailTextLabel.text = armed ? @"观察中" : @"不代发";
        }
        if (path.row == 4) {
            cell.textLabel.text = @"悬浮入口";
            UISwitch *toggle = [[UISwitch alloc] init]; toggle.on = self.entryPreferences.floatingEntryEnabled;
            toggle.onTintColor = SRSettingsAccent();
            [toggle addTarget:self action:@selector(floatingEntryChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryType = UITableViewCellAccessoryNone; cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        if (path.row == 5) cell.textLabel.text = @"使用说明";
        if (path.row == 6) cell.textLabel.text = @"导出运行诊断";
        if (path.row == 7 || path.row == 8) {
            BOOL image = path.row == 8;
            cell.textLabel.text = image ? @"单群图片实验发送" : @"单群文字实验发送";
            UISwitch *toggle = [[UISwitch alloc] init]; toggle.on = image ? self.singleImageSendEnabled : self.singleTextSendEnabled;
            toggle.onTintColor = SRSettingsAccent();
            [toggle addTarget:self action:(image ? @selector(singleImageSendChanged:) : @selector(singleTextSendChanged:)) forControlEvents:UIControlEventValueChanged];
            cell.accessoryType = UITableViewCellAccessoryNone; cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.detailTextLabel.text = toggle.on ? @"已开启：仅允许一次、一个目标群" : @"默认关闭，需明确开启";
        }
        if (path.row == 9) {
            NSDictionary *probe = self.sourceTimeProbe.diagnostics;
            NSUInteger sampleCount = [probe[@"samples"] count];
            NSString *state = self.sourceTimeProbe.active ? @"采样中" :
                ([probe[@"state"] isEqual:@"stopped"] ? @"已停止" : @"未开启");
            cell.textLabel.text = @"来源时间采样";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %lu/16", state, (unsigned long)sampleCount];
            cell.accessibilityLabel = @"来源时间采样";
            cell.accessibilityValue = [NSString stringWithFormat:@"%@，%lu/16", state, (unsigned long)sampleCount];
        }
    } else if (section == 1) {
        if (path.row == 0) { cell.textLabel.text = @"母群"; cell.detailTextLabel.text = self.draft[@"sourceGroup"][@"name"] ?: @"未选择"; }
        else if (path.row == 1) { cell.textLabel.text = @"来源成员"; cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 人", (unsigned long)[self.draft[@"senders"] count]]; }
        else {
            NSString *type = path.row == 2 ? @"text" : @"image";
            cell.textLabel.text = path.row == 2 ? @"转发文字" : @"转发图片";
            UISwitch *toggle = [[UISwitch alloc] init]; toggle.tag = path.row;
            toggle.onTintColor = SRSettingsAccent();
            toggle.on = [self.draft[@"types"] containsObject:type]; toggle.enabled = self.ready;
            [toggle addTarget:self action:@selector(typeChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryType = UITableViewCellAccessoryNone; cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else if (section == 2) {
        cell.textLabel.text = @"随机间隔";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@–%@ 秒 / 次", self.draft[@"minimum"], self.draft[@"maximum"]];
    } else if (section == 3) {
        NSArray *rules = self.draft[@"rules"];
        if (path.row == 0) { cell.textLabel.text = @"排除群聊"; cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 个", (unsigned long)[self.draft[@"excludedGroups"] count]]; }
        else if (path.row == 1) { cell.textLabel.text = @"自动分组"; cell.detailTextLabel.text = @"默认 100 群/条 · 新群自动补位"; }
        else if (path.row == 2) { cell.textLabel.text = @"手动选择群聊"; cell.detailTextLabel.text = @"生成自定义分组，不参与补位"; }
        else {
            NSDictionary *rule = rules[path.row - 3];
            cell.textLabel.text = rule[@"name"];
            NSUInteger count = [rule[@"targets"] count];
            /* The cell shows the grouping spec, never the executable range:
             * that range is a separate, temporary gate. */
            cell.detailTextLabel.text = [rule[@"origin"] isEqual:@"custom"] ?
                [NSString stringWithFormat:@"%lu 个群 · 自定义，不参与补位", (unsigned long)count] :
                [NSString stringWithFormat:@"%lu 个群 · 自动，补位到 %lu", (unsigned long)count,
                    (unsigned long)[SRGroupPlanner capacityForRule:rule]];
        }
    } else {
        NSString *state = self.capture.status[@"state"];
        if (path.row == 0) { cell.textLabel.text = [state isEqual:@"waiting"] ? @"取消等待" : @"等待源消息"; cell.detailTextLabel.text = [state isEqual:@"waiting"] ? @"等待中" : @"手动开始"; }
        if (path.row == 1) { cell.textLabel.text = @"源消息预览"; cell.detailTextLabel.text = [state isEqual:@"preview"] ? @"已锁定 1 条" : ([state isEqual:@"waiting"] ? @"等待中" : @"暂无内容"); }
        if (path.row == 1 && [state isEqual:@"waiting"] && [self.receiver.diagnostics[@"imagePending"] boolValue]) cell.detailTextLabel.text = @"图片加载中，最多 30 秒";
        if (path.row == 2) { cell.textLabel.text = @"内容计划与历史"; cell.detailTextLabel.text = @"只读"; }
        if (path.row == 3) {
            cell.textLabel.text = @"单群文字发送（实验）";
            cell.detailTextLabel.text = self.singleTextSendEnabled ? ([state isEqual:@"preview"] ? @"选择一个目标群后发送一次" : @"先锁定一条源消息") : @"先在更多设置中开启实验开关";
            cell.textLabel.textColor = self.singleTextSendEnabled ? UIColor.labelColor : UIColor.tertiaryLabelColor;
        }
        if (path.row == 4) { cell.textLabel.text = @"图片发送接口检查"; cell.detailTextLabel.text = @"不发送"; }
        if (path.row == 5) {
            cell.textLabel.text = @"单群图片发送（实验）";
            cell.detailTextLabel.text = self.singleImageSendEnabled ? @"选择一个目标群后发送一次" : @"先在更多设置中开启图片实验开关";
            cell.textLabel.textColor = self.singleImageSendEnabled ? UIColor.labelColor : UIColor.tertiaryLabelColor;
        }
    }
    if (section > 0 && !self.ready) cell.textLabel.textColor = UIColor.tertiaryLabelColor;
    return cell;
}
- (void)floatingEntryChanged:(UISwitch *)toggle {
    self.entryPreferences.floatingEntryEnabled = toggle.on;
}
- (void)singleTextSendChanged:(UISwitch *)toggle {
    if (toggle.on && ![self allowLegacyExperiment]) { toggle.on = NO; return; }
    if (!toggle.on) { [self cancelTextExperiment]; self.singleTextSendEnabled = NO; [self refresh]; return; }
    toggle.on = NO;
    if (self.ownsIdleTimer) { SRAlert(self, @"已有活动实验", @"先取消倒计时或停止观察，再切换实验类型。"); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"开启单群实验发送？"
        message:@"本次微信启动只允许提交一次、一个目标群，确认后至少等待 10 秒。不会启动规则、批量发送或自动重试。同一源消息即使重启也不能重复实验。服务器 ID 不代表送达；请只用授权测试群。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"开启本次实验" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        if (self.ownsIdleTimer || self.sourceTimeProbe.active) return;
        [self cancelImageExperiment]; self.singleTextSendEnabled = YES; [self refresh];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)singleImageSendChanged:(UISwitch *)toggle {
    if (toggle.on && ![self allowLegacyExperiment]) { toggle.on = NO; return; }
    if (!toggle.on) { [self cancelImageExperiment]; [self refresh]; return; }
    toggle.on = NO;
    if (self.ownsIdleTimer) { SRAlert(self, @"已有活动实验", @"先取消倒计时或停止观察，再切换实验类型。"); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"开启单群图片实验？"
        message:@"只允许一张静态图片、一个授权目标群。按已保存的间隔等待，最低 3 秒；与文字实验共用本次进程的一次机会。图片会从已校验快照生成 JPEG，不保证原图质量。装载接口可能写入微信本地媒体文件，即使后续提交阻断也不自动重试。批量仍关闭。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"开启本次图片实验" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        if (self.ownsIdleTimer || self.sourceTimeProbe.active) return;
        [self cancelTextExperiment]; self.singleTextSendEnabled = NO; self.singleImageSendEnabled = YES; [self refresh];
    }]];
    SRPresentAlert(self, alert);
}
- (void)typeChanged:(UISwitch *)toggle {
    if (![self checkAccount]) { [self refresh]; return; }
    NSMutableArray *types = [self.draft[@"types"] mutableCopy];
    NSString *type = toggle.tag == 2 ? @"text" : @"image";
    if (toggle.on) [types addObject:type]; else [types removeObject:type];
    if (!types.count) { toggle.on = YES; SRAlert(self, @"至少保留一种类型", @"请选择文字、图片或两者。"); return; }
    self.draft[@"types"] = types; [self changed];
}
- (SRPicker *)picker:(NSString *)title rows:(NSArray *)rows selected:(NSArray *)selected excluded:(NSSet *)excluded multiple:(BOOL)multiple excluding:(BOOL)excluding completion:(void (^)(NSArray *))completion {
    SRPicker *picker = [[SRPicker alloc] initWithStyle:UITableViewStyleGrouped];
    picker.title = title; picker.multiple = multiple; picker.excluding = excluding;
    NSString *note = [self.reader.warnings componentsJoinedByString:@"\n"];
    picker.note = excluding ? [@"勾选＝排除。可按群名或原始 ID 搜索；批量菜单支持排除/恢复搜索结果。应用后从当前规则移除相应群；不会修改已有执行记录。\n" stringByAppendingString:note] : note;
    picker.selection = [[SRSelection alloc] initWithRows:rows excludedIDs:excluded selectedIDs:[NSSet setWithArray:[selected valueForKey:@"id"]]];
    __weak typeof(self) weakSelf = self;
    picker.completion = ^(NSArray *chosen) { if ([weakSelf checkAccount]) completion(chosen); };
    [self.navigationController pushViewController:picker animated:YES];
    return picker;
}
- (void)chooseSource {
    NSError *error = nil; NSArray *groups = [self.reader groups:&error];
    if (!groups) { SRAlert(self, @"无法读取群", error.localizedDescription); return; }
    __weak typeof(self) weakSelf = self;
    [self picker:@"选择母群" rows:groups selected:@[] excluded:NSSet.set multiple:NO excluding:NO completion:^(NSArray *chosen) {
        if ([chosen[0][@"id"] isEqual:weakSelf.draft[@"sourceGroup"][@"id"]]) return;
        NSDictionary *snapshot = [SRSourceMessage frozenJSON:weakSelf.draft]; NSString *account = weakSelf.account;
        NSError *error = nil;
        NSDictionary *candidate = [SRGroupPlanner configurationBySettingSourceGroup:chosen[0] inDraft:snapshot error:&error];
        if (!candidate) { SRAlert(weakSelf, @"无法更换母群", error.localizedDescription); return; }
        void (^apply)(void) = ^{
            if (![weakSelf checkDraft:snapshot account:account]) return;
            [weakSelf.receiver stop]; [weakSelf.capture cancel];
            weakSelf.draft = [candidate mutableCopy];
            [SRRuntimeLog.shared record:@"source_changed" facts:@{@"removedTargets": @(SRTargetCount(snapshot) - SRTargetCount(candidate)),
                @"ruleCount": @([candidate[@"rules"] count])}];
            [weakSelf changed]; [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
        };
        if ([weakSelf.draft[@"rules"] count] || [weakSelf.draft[@"senders"] count]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"更换母群？" message:@"保留目标规则，并从目标中自动移除新母群；空规则会删除。来源成员需重新选择，未确认的捕获会取消。选好成员并保存后即可重新等待；已有内容计划不变。" preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                [alert addAction:[UIAlertAction actionWithTitle:@"更换母群" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { apply(); }]];
                [weakSelf presentViewController:alert animated:YES completion:nil];
            });
        } else apply();
    }];
}
- (void)chooseSenders {
    NSString *group = self.draft[@"sourceGroup"][@"id"];
    if (!group) { SRAlert(self, @"先选择母群", @"发送者必须从母群的成员中选择。"); return; }
    NSError *error = nil; NSArray *members = [self.reader membersOfGroup:group error:&error];
    if (![self checkAccount]) return;
    NSMutableArray *senderRows = [NSMutableArray arrayWithObject:@{@"id": self.account, @"name": @"我（当前登录账号）"}];
    for (NSDictionary *member in members) if (![member[@"id"] isEqual:self.account]) [senderRows addObject:member];
    NSDictionary *snapshot = [SRSourceMessage frozenJSON:self.draft]; NSString *account = self.account;
    __weak typeof(self) weakSelf = self;
    SRPicker *picker = [self picker:@"指定发送者 · wxid" rows:senderRows selected:self.draft[@"senders"] excluded:NSSet.set multiple:YES excluding:NO completion:^(NSArray *chosen) {
        if (![weakSelf checkDraft:snapshot account:account]) return;
        weakSelf.draft[@"senders"] = chosen; [weakSelf changed];
    }];
    picker.note = members ? @"“我”使用已核对的当前登录账号 wxid，不按昵称识别。其他来源成员来自微信本地群记录。" :
        [NSString stringWithFormat:@"暂时只能选择本人：%@。当前账号 wxid 已核对；其他成员需打开母群后重试。", error.localizedDescription ?: @"成员列表尚不可读"];
    [picker refresh];
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
        // A hand-picked pool stays a deliberate composition: every rule it
        // creates is marked custom, so a later top-up never adds groups to it.
        NSUInteger size = 100;
        NSUInteger count = chosen.count / size + (chosen.count % size ? 1 : 0);
        [weakSelf previewGroups:chosen recipe:@[@{@"size": @(size), @"count": @(count)}] intent:SRGroupingIntentCustom];
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
    NSSet *automatic = snapshot[@"sourceGroup"][@"id"] ? [NSSet setWithObject:snapshot[@"sourceGroup"][@"id"]] : NSSet.set;
    [self picker:@"母群已自动排除 · 额外排除" rows:rows selected:previous excluded:automatic multiple:YES excluding:YES completion:^(NSArray *chosen) {
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
        NSString *message = [NSString stringWithFormat:@"将从已有规则移除 %lu 个群，并删除 %lu 条空规则。其他群不自动重排；已有执行记录不受影响。",
            (unsigned long)removed, (unsigned long)emptyRules];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"应用排除并更新规则？" message:message preferredStyle:UIAlertControllerStyleAlert];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"自动分配规则" message:@"推荐每条 100 个群；200 群保留为高级规格。只填写各自生成条数，先分配 100 群规则，再分配 200 群规则；0 或留空表示不生成。群不足按实际数量生成，最后一条可不足额。两项都为 0 时只把新群补进未满的自动分组，不新建规则。" preferredStyle:UIAlertControllerStyleAlert];
    for (NSNumber *size in @[@100, @200]) [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad; field.text = size.unsignedIntegerValue == 100 ? @"10" : @"0";
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
        if (!hundreds || !twoHundreds) {
            SRAlert(self, @"条数无效", @"请输入非负整数。两项都为 0 表示只补位、不新建规则。"); return;
        }
        [self previewGroups:groups recipe:@[@{@"size": @100, @"count": hundreds}, @{@"size": @200, @"count": twoHundreds}] intent:SRGroupingIntentAutomatic];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)previewGroups:(NSArray *)groups recipe:(NSArray *)recipe intent:(SRGroupingIntent)intent {
    if (![self checkAccount]) return;
    NSDictionary *snapshot = [SRSourceMessage frozenJSON:self.draft]; NSString *account = self.account;
    NSError *error = nil;
    NSDictionary *preview = [SRGroupPlanner previewWithRows:groups draft:snapshot recipe:recipe
        intent:intent executionLimit:SRRunProjectionTargetLimit error:&error];
    if (!preview) { SRAlert(self, @"无法生成分组", error.localizedDescription); return; }
    if (![preview[@"generatedRuleCount"] unsignedIntegerValue] && ![preview[@"topUpCount"] unsignedIntegerValue]) {
        SRAlert(self, @"没有变更", [NSString stringWithFormat:@"本次要求 %@ 个群，实际可分配 0 个，也没有可补位的分组。请检查排除项和已有规则；原有设置不变。", preview[@"requestedCount"]]); return;
    }
    NSMutableArray *typeNames = [NSMutableArray array];
    for (NSString *type in snapshot[@"types"]) [typeNames addObject:[type isEqual:@"text"] ? @"文字" : @"图片"];
    NSMutableString *message = [NSMutableString stringWithFormat:@"统一条件\n母群：%@\n%@\n发送者：%lu 人（按 wxid）\n类型：%@\n间隔：%@–%@ 秒\n\n",
        snapshot[@"sourceGroup"][@"name"], snapshot[@"sourceGroup"][@"id"], (unsigned long)[snapshot[@"senders"] count], [typeNames componentsJoinedByString:@"、"], snapshot[@"minimum"], snapshot[@"maximum"]];
    for (NSDictionary *topUp in preview[@"topUpRules"])
        [message appendFormat:@"补位：%@ %@ → %@ 群（上限 %@）\n", topUp[@"name"], topUp[@"before"], topUp[@"after"], topUp[@"target"]];
    for (NSDictionary *batch in preview[@"batches"]) if ([batch[@"count"] unsignedIntegerValue])
        [message appendFormat:@"%@ 群/条 × %@ 条 → 实际 %@ 条、%@ 群\n", batch[@"size"], batch[@"count"], batch[@"generatedCount"], batch[@"assignedCount"]];
    [message appendFormat:@"\n本次可分配 %@ 群：补位 %@ 群，新建 %@ 条规则、%@ 群。\n不足 %@ 群，末尾不足额 %@ 条；剩余未分配 %@ 群。\n\n母群、排除群、已分配群不会重复选入；标记为自定义的分组不参与补位。群列表仅以当前接口返回为准。\n这里只生成规则，需点“保存”保留，不发送；后续每条仍需手动开始，不会自动接着执行。",
        preview[@"availableCount"], preview[@"topUpCount"], preview[@"generatedRuleCount"], preview[@"assignedCount"], preview[@"shortfallCount"], preview[@"partialRuleCount"], preview[@"remainingCount"]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"自动分组预览" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确认生成（不发送）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (![self checkDraft:snapshot account:account]) return;
        self.draft = [preview[@"configuration"] mutableCopy]; [self changed];
    }]];
    SRPresentAlert(self, alert);
}
- (void)editInterval {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"发送间隔（秒）" message:@"下限不能小于 3；默认 5–10 秒。上限不能小于下限，设成相同数值即为固定间隔。" preferredStyle:UIAlertControllerStyleAlert];
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
- (void)setRuleIndex:(NSUInteger)index custom:(BOOL)custom {
    if (![self checkAccount]) return;
    NSMutableArray *rules = [self.draft[@"rules"] mutableCopy];
    if (index >= rules.count) return;
    NSMutableDictionary *rule = [rules[index] mutableCopy];
    if (custom) {
        // A custom rule is never topped up, so it must not claim a capacity.
        rule[@"origin"] = @"custom"; [rule removeObjectForKey:@"capacity"];
    } else {
        rule[@"origin"] = @"auto";
        rule[@"capacity"] = @([SRGroupPlanner capacityForRule:rule]);
    }
    rules[index] = rule;
    NSMutableDictionary *candidate = [self.draft mutableCopy]; candidate[@"rules"] = rules;
    NSError *error = nil;
    if (![SRConfiguration validateDraft:candidate error:&error]) {
        SRAlert(self, @"无法修改分组类型", error.localizedDescription); return;
    }
    self.draft = candidate; [self changed];
}
- (void)showRule:(NSUInteger)index {
    NSDictionary *rule = self.draft[@"rules"][index];
    BOOL custom = [rule[@"origin"] isEqual:@"custom"];
    NSString *provenance = custom ? @"当前为自定义分组：新群不会自动补进来。"
        : [NSString stringWithFormat:@"自动分组：新群会补到 %lu 个；可执行范围更小时按较小值。",
            (unsigned long)[SRGroupPlanner capacityForRule:rule]];
    NSString *message = [NSString stringWithFormat:
        @"共用本计划的母群、发送者 wxid、类型和间隔，不需要单独配置。此分组尚未执行；移除后，其中的群可重新分配。\n\n%@",
        provenance];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:rule[@"name"]
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"查看目标" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self picker:rule[@"name"] rows:rule[@"targets"] selected:@[] excluded:NSSet.set multiple:NO excluding:NO completion:^(NSArray *chosen) {
            SRAlert(self, chosen[0][@"name"], chosen[0][@"id"]);
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:(custom ? @"改为自动分组（参与补位）" : @"改为自定义分组（不参与补位）")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self setRuleIndex:index custom:!custom];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"移除分组" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        if (![self checkAccount]) return;
        NSMutableArray *rules = [self.draft[@"rules"] mutableCopy]; [rules removeObjectAtIndex:index];
        self.draft[@"rules"] = rules; [self changed];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSDictionary *)diagnosticDraft {
    BOOL includesSelf = NO;
    for (NSDictionary *sender in self.draft[@"senders"]) if ([sender[@"id"] isEqual:self.account]) includesSelf = YES;
    return @{@"sourceSelected": @([self.draft[@"sourceGroup"] count] > 0), @"senderCount": @([self.draft[@"senders"] count]),
        @"ruleCount": @([self.draft[@"rules"] count]), @"targetCount": @(SRTargetCount(self.draft)), @"includesSelf": @(includesSelf),
        @"textEnabled": @([self.draft[@"types"] containsObject:@"text"]), @"imageEnabled": @([self.draft[@"types"] containsObject:@"image"]),
        @"dirty": @(self.dirty)};
}
- (NSDictionary *)diagnosticReport {
    NSMutableDictionary *report = [[self.reader diagnostics] mutableCopy];
    report[@"reportSchema"] = @1;
    report[@"generatedAt"] = @([NSDate.date timeIntervalSince1970]);
    report[@"build"] = @{@"plugin": SR_PLUGIN_VERSION, @"commit": SR_BUILD_COMMIT, @"ciRun": SR_BUILD_RUN,
        @"singleTextExperimentImplemented": @YES, @"singleImageExperimentImplemented": @YES, @"batchSendingEnabled": @NO, @"defaultSendingEnabled": @NO};
    report[@"sendingEnabled"] = @(self.singleTextSendEnabled || self.singleImageSendEnabled);
    report[@"batchSendingEnabled"] = @NO;
    report[@"settingsEntry"] = self.settingsEntry.diagnostics;
    report[@"settingsFooterRecoveryActive"] = @(self.settingsFooterActive);
    // Box the branch values explicitly so exported JSON preserves a boolean
    // instead of serializing the BOOL expression as 0/1.
    report[@"storageReady"] = self.store ? @YES : @NO;
    report[@"schemaVersion"] = self.store ? @(self.store.schemaVersion) : NSNull.null;
    report[@"floatingEntryEnabled"] = @(self.entryPreferences.floatingEntryEnabled);
    report[@"receiveCandidate"] = self.receiver.diagnostics;
    report[@"sourceTimeProbe"] = self.sourceTimeProbe.diagnostics ?: @{@"state": @"unavailable"};
    report[@"imageSource"] = self.imageSource.diagnostics ?: @{};
    report[@"imageSendPreparation"] = self.imageSendProbe.diagnostics ?: @{};
    report[@"sourceCapture"] = self.capture.diagnostics ?: @{@"state": @"unavailable"};
    report[@"draftSummary"] = [self diagnosticDraft];
    report[@"runtimeLog"] = SRRuntimeLog.shared.snapshot;
    report[@"manualSendObservation"] = self.sendProbe.diagnostics;
    report[@"singleTextSendCandidate"] = self.textSendHost.diagnostics;
    report[@"singleTextSendExperimentEnabled"] = @(self.singleTextSendEnabled);
    report[@"singleTextSendCountdown"] = @(self.textCountdown);
    report[@"singleTextExperimentIdleTimerHeld"] = @(self.ownsIdleTimer && !self.singleImageSendEnabled);
    report[@"singleImageSendCandidate"] = self.imageSendHost.diagnostics;
    report[@"smallGroupExecutionImplemented"] = @YES;
    report[@"smallGroupExecution"] = self.smallGroupSession.diagnostics ?: @{};
    report[@"singleImageSendExperimentEnabled"] = @(self.singleImageSendEnabled);
    report[@"singleImageSendCountdown"] = @(self.imageCountdown);
    report[@"singleImageExperimentIdleTimerHeld"] = @(self.ownsIdleTimer && self.singleImageSendEnabled);
    if (self.ready) report[@"singleImageExperimentHistory"] = [self.store imageExperimentSummaryForAccount:self.account error:NULL] ?: @{@"state": @"unavailable"};
    if (self.ready) report[@"singleTextExperimentHistory"] = [self.store textExperimentSummaryForAccount:self.account error:NULL] ?: @{@"state": @"unavailable"};
    report[@"iOS"] = UIDevice.currentDevice.systemVersion;
    report[@"wechatBuild"] = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
    return report;
}
- (void)exportDiagnosticFromController:(UIViewController *)controller {
    NSData *data = [NSJSONSerialization dataWithJSONObject:[self diagnosticReport] options:NSJSONWritingPrettyPrinted error:NULL];
    NSString *name = [NSString stringWithFormat:@"SyncRelay-diagnostic-%@.json", NSUUID.UUID.UUIDString];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    NSError *error = nil;
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:&error]) {
        SRAlert(controller, @"诊断导出失败", @"无法写入临时诊断文件，请重试；现有配置未改变。"); return;
    }
    [SRRuntimeLog.shared record:@"export_created" facts:@{}];
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = controller.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds), CGRectGetMidY(controller.view.bounds), 1, 1);
    [controller presentViewController:share animated:YES completion:nil];
}
- (void)showDiagnostics {
    NSDictionary *report = [self diagnosticReport];
    NSString *text = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL] encoding:NSUTF8StringEncoding];
    UIViewController *viewer = [[UIViewController alloc] init]; viewer.title = @"运行诊断";
    SRStyleSettingsController(viewer);
    UITextView *view = [[UITextView alloc] init]; view.editable = NO; view.text = text;
    view.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; view.adjustsFontForContentSizeCategory = YES;
    view.textContainerInset = UIEdgeInsetsMake(16, 16, 24, 16);
    view.backgroundColor = UIColor.systemBackgroundColor; viewer.view = view;
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithPrimaryAction:[UIAction actionWithTitle:@"复制" image:nil identifier:nil handler:^(__unused UIAction *action) {
        UIPasteboard.generalPasteboard.string = text;
    }]];
    __weak typeof(self) weakSelf = self; __weak UIViewController *weakViewer = viewer;
    UIBarButtonItem *export = [[UIBarButtonItem alloc] initWithPrimaryAction:[UIAction actionWithTitle:@"导出" image:nil identifier:nil handler:^(__unused UIAction *action) {
        UIViewController *owner = weakViewer; if (owner) [weakSelf exportDiagnosticFromController:owner];
    }]];
    viewer.navigationItem.rightBarButtonItems = @[export, copy];
    [self.navigationController pushViewController:viewer animated:YES];
}
- (void)showUsage {
    UIViewController *viewer = [[UIViewController alloc] init]; viewer.title = @"使用说明";
    SRStyleSettingsController(viewer);
    UITextView *view = [[UITextView alloc] init]; view.editable = NO;
    view.font = SRSettingsFont(17, UIFontTextStyleBody); view.adjustsFontForContentSizeCategory = YES;
    view.textColor = UIColor.labelColor; view.backgroundColor = SRSettingsCellBackground();
    view.textContainerInset = UIEdgeInsetsMake(16, 16, 24, 16);
    view.text = @"当前版本\n这是开发测试版，已开放每条 1–20 个授权群的真实串行转发。保存、捕获、预览及确认计划都不自动发送；确认计划后，进入内容计划点击规则，再点“开始小群测试”。不需要打开旧单群实验开关。100/200 群大规则和重新执行尚未开放。\n\n"
        @"来源条件\n所有规则共用母群、来源成员 wxid、消息类型和间隔。“我”对应已核对的当前登录账号；其他成员按原始 wxid 识别，不按昵称。图片支持捕获、资源校验、实际预览及小群测试；发送的是已加载快照重新生成的 JPEG，不承诺原图质量或动态图片。等待资源最多 30 秒；如未就绪，请在母群点开图片加载后重新等待并发送一张新图。\n\n"
        @"群聊与分组\n母群和已分配群自动排除。只需搜索并排除不想转发的群，默认按每条 100 群自动分组；200 群保留为高级规格。数量不足按实际生成，不建空规则。手动全选也默认拆分为每条 100 群。\n\n"
        @"等待源消息\n先保存设置，再手动开始等待。关闭面板回母群，由指定成员或本人发一条文字；须取得服务器消息 ID 才进入预览。本人候选最多等待确认 30 秒，不用临时本地 ID 替代。\n\n"
        @"预览与计划\n第一条匹配内容锁定后停止等待。核对母群、发送者 wxid、类型和完整正文再确认；候选可能包含离线补同步，不能只凭回调时间判断新旧。确认只建立计划，不开始执行任何规则。\n\n"
        @"小群执行\n测试时手动只选 1–20 个群组成规则；大分组可以保存，但本轮不能实发。每条规则点一次开始，内部串行处理，不逐群弹窗。暂停后手动继续未尝试群；切后台、锁屏或账号改变会暂停，回前台或重启不自动继续。等待和在途观察时保持常亮，暂停收尾和完成时释放。已提交不等于确认送达，失败/未知不自动重发，当前规则结束不自动执行下一条。\n\n"
        @"暂停采集\n切后台、锁屏或账号改变会取消等待，回前台不自动重启。预览未确认前只保留在内存，退出微信后需重新捕获；已确认计划与历史独立于当前设置。\n\n"
        @"间隔与发送观察\n默认间隔 5–10 秒，最低 3 秒，上限可自定义；上下限相同为固定间隔。间隔仅控制本插件的发送节奏，不保证发送成功。手动发送观察只记录一个测试群的元数据，需你回微信手动发送，120 秒到期或切后台停止，不代发、不读取正文、不判定送达。单群文字实验必须先打开开关、选择一个目标并二次确认；回读到服务器 ID 仍只记为主机关联，不自动重试。\n\n"
        @"入口与诊断\n主入口始终是“我 → 设置 → SyncRelay 转发”。悬浮入口默认关闭，可自行开启。诊断包含版本、接口签名及脱敏观察摘要，不含账号 wxid、群 ID、消息 ID 或正文。所有采集候选及页面表现仍需真机验证。";
    viewer.view = view;
    [self.navigationController pushViewController:viewer animated:YES];
}
- (void)beginSendProbe {
    if (self.sourceTimeProbe.active) { SRAlert(self, @"请先停止来源时间采样", @"来源时间与发送观察分轮验证，不叠加监听或发送。"); return; }
    if (self.smallGroupSession.busy) { SRAlert(self, @"请先暂停并结束小群测试", @"只读观察与真实规则执行分开进行。"); return; }
    if ([self.sendProbe.diagnostics[@"armed"] boolValue]) { [self.sendProbe stop]; return; }
    if (![self checkAccount]) return;
    if (self.ownsIdleTimer) { SRAlert(self, @"已有活动实验", @"请先取消倒计时或停止观察。"); return; }
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
            if (panel.sourceTimeProbe.active || panel.ownsIdleTimer || [panel.capture.status[@"state"] isEqual:@"waiting"]) { SRAlert(panel, @"先取消活动实验或源消息等待", @"本次观察未开启。"); return; }
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
    [self.navigationController pushViewController:SRCreateCapturePreview(self.store, self.capture, self.account, [self planVerifier], self.smallGroupSession) animated:YES];
}
- (BOOL)allowLegacyExperiment {
    if (self.sourceTimeProbe.active) { SRAlert(self, @"请先停止来源时间采样", @"只读采样期间不开放发送实验。"); return NO; }
    if (!self.smallGroupSession.busy && !self.smallGroupSession.usedNativeHost) return YES;
    SRAlert(self, @"本次请使用小群规则测试", @"小群执行与旧单群实验互斥。请在内容计划中暂停、继续或结束；本进程用过小群发送后不再开启旧单群实验。"); return NO;
}
- (void)beginSingleImageSend {
    if (![self allowLegacyExperiment]) return;
    if (!self.singleImageSendEnabled) { SRAlert(self, @"实验开关未开启", @"请先在“更多设置”开启单群图片实验发送；默认关闭。" ); return; }
    if (![self checkAccount]) return;
    if (self.ownsIdleTimer) { SRAlert(self, @"已有活动实验", @"请先取消倒计时或停止观察，不会叠加第二次提交。" ); return; }
    if (self.dirty || [self.sendProbe.diagnostics[@"armed"] boolValue]) { SRAlert(self, @"请先保存并停止手动观察", @"单群实验与设置修改、手动发送观察分开进行。" ); return; }
    if ([self.imageSendHost.diagnostics[@"attemptConsumed"] boolValue] || [self.textSendHost.diagnostics[@"submissionAttempted"] boolValue]) { SRAlert(self, @"本次实验已使用", @"请先导出诊断并核对目标群，不要重复发送。重新打开面板也不会再次提交。" ); return; }
    if (![self.capture.status[@"state"] isEqual:@"preview"] || ![self.capture.preview[@"type"] isEqual:@"image"]) {
        SRAlert(self, @"还没有可发送的图片预览", @"先保存设置并等待一张母群图片，核对 wxid 和实际图片后再进行单群实验。" ); return;
    }
    NSDictionary *source = [SRSourceMessage frozenJSON:self.capture.preview];
    if (!SRImageMaterialSupportsPayload(source[@"payload"])) {
        SRAlert(self, @"图片超出本轮实验范围", @"请使用静态小图；本轮最多 1600 万像素、单边 8192 像素。不压缩猜测超限资源，未建立发送占位。"); return;
    }
    NSDictionary *configuration = [SRSourceMessage frozenJSON:self.capture.status[@"configuration"]];
    if (![self.draft isEqual:configuration]) { SRAlert(self, @"来源预览的设置已过期", @"请放弃旧预览，使用当前已保存的设置重新等待一张图片。" ); return; }
    NSString *account = self.account;
    NSError *error = nil; NSArray *groups = [self.reader groups:&error];
    if (!groups) { SRAlert(self, @"无法读取目标群", error.localizedDescription); return; }
    NSMutableSet *allowed = [NSMutableSet set];
    for (NSDictionary *rule in configuration[@"rules"]) for (NSDictionary *row in rule[@"targets"]) [allowed addObject:row[@"id"]];
    [allowed removeObject:source[@"group"]];
    [allowed minusSet:[NSSet setWithArray:[configuration[@"excludedGroups"] valueForKey:@"id"] ?: @[]]];
    NSMutableArray *targets = [NSMutableArray array];
    for (NSDictionary *group in groups) if ([allowed containsObject:group[@"id"]]) [targets addObject:group];
    if (!targets.count) { SRAlert(self, @"没有可核对的目标", @"只允许选择捕获时规则中的非母群、未排除且目前仍能读取的目标群。" ); return; }
    __weak typeof(self) weakSelf = self;
    [self picker:@"单群实验：只选一个目标群" rows:targets selected:@[] excluded:NSSet.set multiple:NO excluding:NO completion:^(NSArray *chosen) {
        SRPanel *panel = weakSelf; if (!panel || !chosen.count || ![panel checkAccount]) return;
        NSString *target = chosen.firstObject[@"id"]; NSString *name = chosen.firstObject[@"name"] ?: target;
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"最后确认：只发送一次"
            message:[NSString stringWithFormat:@"目标群：%@\n%@\n来源 wxid：%@\n\n请先打开源消息图片核对。发送已捕获静态快照的 JPEG，不承诺原图质量。按保存的随机间隔（至少 3 秒）提交一次；切后台、关闭面板或修改设置会取消。", name, target, source[@"sender"]]
            preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"发送一次" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            if (![panel checkAccount] || !panel.singleImageSendEnabled || panel.ownsIdleTimer || panel.dirty ||
                ![panel.account isEqual:account] || ![panel.capture.preview isEqual:source] || ![panel.draft isEqual:configuration]) return;
            NSError *failure = nil;
            if ([panel.textSendHost.diagnostics[@"submissionAttempted"] boolValue] ||
                ![panel.imageSendHost readyForAccount:account error:&failure]) {
                [SRRuntimeLog.shared record:@"image_test_blocked" facts:@{@"reasonCode": @1}];
                SRAlert(panel, @"发送门禁未通过", failure.localizedDescription); return;
            }
            SRPacing pacing = {0};
            double now = NSProcessInfo.processInfo.systemUptime;
            if (!SRPacingConfigure(&pacing, [configuration[@"minimum"] doubleValue], [configuration[@"maximum"] doubleValue]) ||
                pacing.maximum > 3600 || !SRPacingResume(&pacing, now, (double)arc4random() / 4294967296.0)) {
                SRAlert(panel, @"实验间隔无效", @"本轮单群实验要求上下限在 3 至 3600 秒内，请保存后重新捕获。"); return;
            }
            double wait = pacing.next_monotonic - now;
            panel.imageCountdown = YES; NSUInteger generation = ++panel.imageGeneration;
            panel.previousIdleTimer = UIApplication.sharedApplication.idleTimerDisabled;
            panel.ownsIdleTimer = YES; UIApplication.sharedApplication.idleTimerDisabled = YES;
            UIAlertController *countdown = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%.1f 秒后仅提交一张图片", wait] message:@"保持本页和微信前台；你可以取消。提交后无自动重试，结果必须核对。" preferredStyle:UIAlertControllerStyleAlert];
            [countdown addAction:[UIAlertAction actionWithTitle:@"取消 / 停止观察" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) { [panel cancelImageExperiment]; panel.singleImageSendEnabled = NO; [panel refresh]; }]];
            SRPresentAlert(panel, countdown);
            [SRRuntimeLog.shared record:@"image_test_countdown" facts:@{}];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ceil(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!panel.imageCountdown || panel.imageGeneration != generation) return;
                // Keep the idle-timer claim until the host's bounded observation ends.
                panel.imageCountdown = NO;
                NSError *error = nil;
                if (!SRPacingReady(&pacing, NSProcessInfo.processInfo.systemUptime) || !panel.singleImageSendEnabled || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
                    !panel.viewIfLoaded.window || panel.dirty || ![panel checkAccount] || ![panel.account isEqual:account] ||
                    ![panel.capture.preview isEqual:source] || ![panel.capture.status[@"configuration"] isEqual:configuration] ||
                    ![panel.draft isEqual:configuration] || [panel.sendProbe.diagnostics[@"armed"] boolValue]) {
                    [panel cancelImageExperiment]; return;
                }
                NSArray *currentGroups = [panel.reader groups:&error];
                if (![[currentGroups valueForKey:@"id"] containsObject:target] ||
                    ![panel.imageSendHost readyForAccount:account error:&error] ||
                    ![panel.store claimImageExperiment:source configuration:configuration account:account target:target error:&error]) {
                    [panel cancelImageExperiment];
                    SRPresentAlert(panel, [panel textTestResult:@"提交前已阻断（未发送）" message:error.localizedDescription ?: @"目标群已无法核对" ]); return;
                }
                [SRRuntimeLog.shared record:@"image_test_claimed" facts:@{}];
                countdown.title = @"单群图片提交与观察";
                countdown.message = @"最多观察 30 秒。提交后不能由此撤回；停止观察不会重试，也不代表发送失败。请保持微信前台。";
                NSDictionary *request = @{@"account": account, @"target": target, @"type": @"image",
                    @"sourceGroup": source[@"group"], @"sourceSender": source[@"sender"],
                    @"sourceMessageID": source[@"messageID"], @"payload": source[@"payload"]};
                [panel.imageSendHost submitRequest:request completion:^(__unused NSString *state, __unused NSString *messageID, NSString *reason) {
                    BOOL invoked = [panel.imageSendHost.diagnostics[@"submissionAttempted"] boolValue];
                    [SRRuntimeLog.shared record:invoked ? @"image_test_submitted" : @"image_test_blocked" facts:@{}];
                    if (panel.imageGeneration != generation) return;
                    [panel restoreTextIdleTimer]; panel.singleImageSendEnabled = NO;
                    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || !panel.viewIfLoaded.window) return;
                    SRPresentAlert(panel, [panel textTestResult:invoked ? @"已调用，送达待核对" : @"发送门禁阻断"
                        message:[NSString stringWithFormat:@"%@\n\n请核对目标群是否收到，并导出运行诊断。同一条源消息不会自动重试。", reason ?: @"没有可靠送达回执"]]);
                    [panel refresh];
                }];
            });
        }]];
        SRPresentAlert(panel, confirm);
    }];
}
- (void)beginSingleTextSend {
    if (![self allowLegacyExperiment]) return;
    if (!self.singleTextSendEnabled) { SRAlert(self, @"实验开关未开启", @"请先在“更多设置”开启单群文字实验发送；默认关闭。" ); return; }
    if (![self checkAccount]) return;
    if (self.ownsIdleTimer) { SRAlert(self, @"已有活动实验", @"请先取消倒计时或停止观察，不会叠加第二次提交。" ); return; }
    if (self.dirty || [self.sendProbe.diagnostics[@"armed"] boolValue]) { SRAlert(self, @"请先保存并停止手动观察", @"单群实验与设置修改、手动发送观察分开进行。" ); return; }
    if ([self.textSendHost.diagnostics[@"submissionAttempted"] boolValue] || [self.imageSendHost.diagnostics[@"attemptConsumed"] boolValue]) { SRAlert(self, @"本次实验已使用", @"请先导出诊断并核对目标群，不要重复发送。重新打开面板也不会再次提交。" ); return; }
    if (![self.capture.status[@"state"] isEqual:@"preview"] || ![self.capture.preview[@"type"] isEqual:@"text"]) {
        SRAlert(self, @"还没有可发送的文字预览", @"先保存设置并等待一条母群文字，核对 wxid 和正文后再进行单群实验。" ); return;
    }
    NSDictionary *source = [SRSourceMessage frozenJSON:self.capture.preview];
    NSDictionary *configuration = [SRSourceMessage frozenJSON:self.capture.status[@"configuration"]];
    if (![self.draft isEqual:configuration]) { SRAlert(self, @"来源预览的设置已过期", @"请放弃旧预览，使用当前已保存的设置重新等待一条文字。" ); return; }
    NSString *account = self.account;
    NSError *error = nil; NSArray *groups = [self.reader groups:&error];
    if (!groups) { SRAlert(self, @"无法读取目标群", error.localizedDescription); return; }
    NSMutableSet *allowed = [NSMutableSet set];
    for (NSDictionary *rule in configuration[@"rules"]) for (NSDictionary *row in rule[@"targets"]) [allowed addObject:row[@"id"]];
    [allowed removeObject:source[@"group"]];
    [allowed minusSet:[NSSet setWithArray:[configuration[@"excludedGroups"] valueForKey:@"id"] ?: @[]]];
    NSMutableArray *targets = [NSMutableArray array];
    for (NSDictionary *group in groups) if ([allowed containsObject:group[@"id"]]) [targets addObject:group];
    if (!targets.count) { SRAlert(self, @"没有可核对的目标", @"只允许选择捕获时规则中的非母群、未排除且目前仍能读取的目标群。" ); return; }
    __weak typeof(self) weakSelf = self;
    [self picker:@"单群实验：只选一个目标群" rows:targets selected:@[] excluded:NSSet.set multiple:NO excluding:NO completion:^(NSArray *chosen) {
        SRPanel *panel = weakSelf; if (!panel || !chosen.count || ![panel checkAccount]) return;
        NSString *target = chosen.firstObject[@"id"]; NSString *name = chosen.firstObject[@"name"] ?: target;
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"最后确认：只发送一次"
            message:[NSString stringWithFormat:@"目标群：%@\n%@\n来源 wxid：%@\n\n文字：%@\n\n确认后等待至少 3 秒再提交一次；切后台、关闭面板或修改设置会取消倒计时。", name, target, source[@"sender"], [source[@"payload"][@"text"] substringToIndex:MIN((NSUInteger)300, [source[@"payload"][@"text"] length])]]
            preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"发送一次" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            if (![panel checkAccount] || !panel.singleTextSendEnabled || panel.ownsIdleTimer || panel.dirty ||
                ![panel.account isEqual:account] || ![panel.capture.preview isEqual:source] || ![panel.draft isEqual:configuration]) return;
            NSError *failure = nil;
            if ([panel.imageSendHost.diagnostics[@"attemptConsumed"] boolValue] || ![panel.textSendHost readyForAccount:account error:&failure] ||
                ![panel.textSendAdapter prepareForAccount:account targetGroup:target sourceSnapshot:source confirmed:YES error:&failure]) {
                [SRRuntimeLog.shared record:@"text_test_blocked" facts:@{@"reasonCode": @1}];
                SRAlert(panel, @"发送门禁未通过", failure.localizedDescription); return;
            }
            SRPacing pacing = {0};
            double now = NSProcessInfo.processInfo.systemUptime;
            if (!SRPacingConfigure(&pacing, [configuration[@"minimum"] doubleValue], [configuration[@"maximum"] doubleValue]) ||
                pacing.maximum > 3600 || !SRPacingResume(&pacing, now, (double)arc4random() / 4294967296.0)) {
                SRAlert(panel, @"实验间隔无效", @"本轮单群实验要求上下限在 3 至 3600 秒内，请保存后重新捕获。"); return;
            }
            double wait = pacing.next_monotonic - now;
            panel.textCountdown = YES; NSUInteger generation = ++panel.textGeneration;
            panel.previousIdleTimer = UIApplication.sharedApplication.idleTimerDisabled;
            panel.ownsIdleTimer = YES; UIApplication.sharedApplication.idleTimerDisabled = YES;
            UIAlertController *countdown = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%.1f 秒后仅提交一次文字", wait] message:@"保持本页和微信前台；你可以取消。提交后无自动重试，结果必须核对。" preferredStyle:UIAlertControllerStyleAlert];
            [countdown addAction:[UIAlertAction actionWithTitle:@"取消 / 停止观察" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) { [panel cancelTextExperiment]; panel.singleTextSendEnabled = NO; [panel refresh]; }]];
            SRPresentAlert(panel, countdown);
            [SRRuntimeLog.shared record:@"text_test_countdown" facts:@{}];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ceil(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!panel.textCountdown || panel.textGeneration != generation) return;
                // Keep the idle-timer claim until the host's bounded observation ends.
                panel.textCountdown = NO;
                NSError *error = nil;
                if (!panel.singleTextSendEnabled || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
                    !panel.viewIfLoaded.window || panel.dirty || ![panel checkAccount] || ![panel.account isEqual:account] ||
                    ![panel.capture.preview isEqual:source] || ![panel.capture.status[@"configuration"] isEqual:configuration] ||
                    ![panel.draft isEqual:configuration] || [panel.sendProbe.diagnostics[@"armed"] boolValue]) {
                    [panel cancelTextExperiment]; return;
                }
                NSArray *currentGroups = [panel.reader groups:&error];
                if (![[currentGroups valueForKey:@"id"] containsObject:target] ||
                    ![panel.textSendHost readyForAccount:account error:&error] ||
                    ![panel.store claimTextExperiment:source configuration:configuration account:account target:target error:&error]) {
                    [panel cancelTextExperiment];
                    SRPresentAlert(panel, [panel textTestResult:@"提交前已阻断（未发送）" message:error.localizedDescription ?: @"目标群已无法核对" ]); return;
                }
                [SRRuntimeLog.shared record:@"text_test_claimed" facts:@{}];
                countdown.title = @"单群文字提交与观察";
                countdown.message = @"最多观察 30 秒。提交后不能由此撤回；停止观察不会重试，也不代表发送失败。请保持微信前台。";
                [panel.textSendAdapter submitDelivery:@{@"target": target, @"state": @"submitting"} snapshot:source completion:^(__unused NSString *state, __unused NSString *messageID, NSString *reason) {
                    BOOL invoked = [panel.textSendHost.diagnostics[@"submissionAttempted"] boolValue];
                    [SRRuntimeLog.shared record:invoked ? @"text_test_submitted" : @"text_test_blocked" facts:@{}];
                    if (panel.textGeneration != generation) return;
                    [panel restoreTextIdleTimer]; panel.singleTextSendEnabled = NO;
                    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || !panel.viewIfLoaded.window) return;
                    SRPresentAlert(panel, [panel textTestResult:invoked ? @"已调用，送达待核对" : @"发送门禁阻断"
                        message:[NSString stringWithFormat:@"%@\n\n请核对目标群是否收到，并导出运行诊断。同一条源消息不会自动重试。", reason ?: @"没有可靠送达回执"]]);
                    [panel refresh];
                }];
            });
        }]];
        SRPresentAlert(panel, confirm);
    }];
}
- (void)inspectImageSendContract {
    if (self.sourceTimeProbe.active) { SRAlert(self, @"请先停止来源时间采样", @"只读时间采样不进入图片构造或资源准备链。"); return; }
    if (self.smallGroupSession.busy) { SRAlert(self, @"当前有小群批次", @"请先结束当前测试，再做独立接口检查。"); return; }
    if (![self checkAccount]) return;
    if (self.dirty || self.ownsIdleTimer || self.textCountdown || self.imageCountdown || [self.textSendHost.diagnostics[@"observing"] boolValue] ||
        [self.sendProbe.diagnostics[@"armed"] boolValue] || [self.capture.status[@"state"] isEqual:@"waiting"]) {
        SRAlert(self, @"请先保存并停止等待或观察", @"图片接口检查与捕获、文字实验分开进行；不会发送消息或消耗文字实验次数。"); return;
    }
    NSString *account = [self.account copy];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"检查图片发送接口（不发送）？"
        message:@"仅创建一条未发送的图片消息，核对图片扩展对象和方法参数。不会写入图片、选择目标群、调用发送或建立占位。检查通过不代表图片能发出或送达。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"检查（不发送）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (![self checkAccount] || ![self.account isEqual:account] || self.sourceTimeProbe.active || self.dirty || self.ownsIdleTimer || self.textCountdown || self.imageCountdown ||
            !self.viewIfLoaded.window || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        NSError *error = nil;
        BOOL compatible = [self.imageSendProbe inspectForAccount:account error:&error];
        SRAlert(self, compatible ? @"接口兼容，尚未发送" : @"接口检查未通过（未发送）",
            compatible ? @"本机未发送图片消息的构造器和图片扩展方法签名可用。请导出运行诊断；图片写入、实际发送和送达仍未验证。" :
            [NSString stringWithFormat:@"%@\n\n请导出运行诊断；不要反复点击文字实验或修改门禁。", error.localizedDescription ?: @"检查已停止"]);
    }]];
    SRPresentAlert(self, alert);
}
- (UIAlertController *)textTestResult:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]]; return alert;
}
- (void)beginCapture {
    if (self.sourceTimeProbe.active) { SRAlert(self, @"请先停止来源时间采样", @"时间采样与源消息预览共用同一接收器，不能同时开始。"); return; }
    if (self.smallGroupSession.busy) { SRAlert(self, @"当前有小群批次", @"现有规则继续使用已经确认的源消息；请先完成或结束它，再等待新内容。"); return; }
    [SRRuntimeLog.shared record:@"capture_attempt" facts:[self diagnosticDraft]];
    if ([self.sendProbe.diagnostics[@"armed"] boolValue]) { SRAlert(self, @"请先停止手动发送观察", @"两种诊断分开进行；停止观察不会发送或修改规则。"); return; }
    NSString *state = self.capture.status[@"state"];
    if ([state isEqual:@"waiting"]) {
        [self.receiver stop]; [self.capture cancel];
        [SRRuntimeLog.shared record:@"capture_cancelled" facts:@{}];
        [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil]; return;
    }
    if ([state isEqual:@"preview"]) { [self showCapture]; return; }
    if (self.dirty) { [SRRuntimeLog.shared record:@"capture_blocked" facts:@{@"reasonCode": @1}]; SRAlert(self, @"请先保存", @"捕获使用一份冻结配置；先保存统一条件和规则，再等待源消息，避免使用未确认的设置。"); return; }
    NSDictionary *snapshot = [SRSourceMessage frozenJSON:self.draft]; NSString *account = self.account;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"手动等待一条母群消息？" message:@"仅捕获所选 wxid 和类型，支持本人。图片需有服务器消息 ID 和可用图片资源，最多等待 30 秒。可能包含补同步，请核对实际预览；切后台取消等待。预览和确认都不会发送；确认后需到内容计划手动开始小群测试。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"开始等待（不发送）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (![self checkDraft:snapshot account:account] || self.sourceTimeProbe.active) return;
        NSError *error = nil;
        if (![self.capture armForAccount:account configuration:snapshot error:&error]) {
            [SRRuntimeLog.shared record:@"capture_arm_failed" facts:@{@"errorCode": @(error.code)}];
            SRAlert(self, @"还不能开始等待", error.localizedDescription); return;
        }
        if (![self.receiver armForAccount:account configuration:snapshot error:&error]) {
            [SRRuntimeLog.shared record:@"capture_arm_failed" facts:@{@"errorCode": @(error.code)}];
            [self.capture cancel]; SRAlert(self, @"接收候选不可用", error.localizedDescription); return;
        }
        // Bind the receiver round that may deliver into this capture round. The
        // two counters are independent and are never compared with each other.
        [self.capture bindReceiverGeneration:self.receiver.diagnostics[@"receiverGeneration"]];
        [SRRuntimeLog.shared record:@"capture_started" facts:[self diagnosticDraft]];
        [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
    }]];
    SRPresentAlert(self, alert);
}
- (void)toggleSourceTimeProbe {
    if (self.sourceTimeProbe.active) {
        [self.sourceTimeProbe stopForReason:SRSourceTimeProbeUserStopped]; [self refresh]; return;
    }
    if (![self checkAccount]) return;
    if (self.dirty || self.ownsIdleTimer || self.singleTextSendEnabled || self.singleImageSendEnabled ||
        self.smallGroupSession.busy || ![self.capture.status[@"state"] isEqual:@"idle"] ||
        [self.sendProbe.diagnostics[@"armed"] boolValue] || [self.textSendHost.diagnostics[@"observing"] boolValue] ||
        [self.imageSendHost.diagnostics[@"observing"] boolValue]) {
        SRAlert(self, @"请先保存并结束捕获或发送实验", @"来源时间采样独立进行；已有预览、计划、进度不会被采样覆盖或删除。"); return;
    }
    if (![self.draft[@"types"] containsObject:@"text"]) { SRAlert(self, @"请先保存文字来源条件", @"文字交付采样要求保存文字类型；同一授权来源的图片只观察回调元数据，不准备资源，不代表阶段 A 已验收。"); return; }
    NSDictionary *snapshot = [SRSourceMessage frozenJSON:self.draft]; NSString *account = self.account;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"开始来源时间只读采样？"
        message:@"使用已保存的母群和来源成员，最多 16 个文字交付回调或 120 秒，另限量观察 16 个文字/图片原始回调元数据。关闭本页后仍可采样，切后台/锁屏、账号或配置改变即停止，回前台不会自动重开。\n\n只保留创建时间、首次回调、实际 getter ABI 等脱敏证据，不生成预览/计划，不发送。新一轮替换上一轮样本，请先导出需要保留的运行诊断。\n\n图片不下载、不准备资源，资源就绪仍未观察；错误来源和其他类型不采样。字段存在、样本出现均不代表时间语义已验证。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"开始采样（不捕获、不发送）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (![self checkDraft:snapshot account:account]) return;
        NSError *error = nil;
        if (![self.sourceTimeProbe startForAccount:account configuration:snapshot error:&error]) {
            SRAlert(self, @"采样未开启", error.localizedDescription ?: @"采样入口不可用，请导出诊断。"); return;
        }
        [self refresh];
    }]];
    SRPresentAlert(self, alert);
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    NSInteger section = SRPanelSection(path.section);
    if (section == 0) {
        if (path.row == 1) {
            if (self.dirty) { SRAlert(self, @"有未保存的修改", @"请先保存，或关闭并放弃修改后重新打开。"); return; }
            [self loadAccount];
        }
        if (path.row == 2) [self showDiagnostics];
        if (path.row == 3) [self beginSendProbe];
        if (path.row == 5) [self showUsage];
        if (path.row == 6) [self exportDiagnosticFromController:self];
        if (path.row == 9) [self toggleSourceTimeProbe];
        return;
    }
    if (![self checkAccount]) return;
    if (section == 1 && path.row == 0) [self chooseSource];
    if (section == 1 && path.row == 1) [self chooseSenders];
    if (section == 2) [self editInterval];
    if (section == 4) {
        if (path.row == 0) [self beginCapture];
        if (path.row == 1) [self showCapture];
        if (path.row == 2) [self.navigationController pushViewController:SRCreatePlanList(self.store, self.account, [self planVerifier], self.smallGroupSession) animated:YES];
        if (path.row == 3) [self beginSingleTextSend];
        if (path.row == 4) [self inspectImageSendContract];
        if (path.row == 5) [self beginSingleImageSend];
    }
    if (section == 3) {
        if (path.row == 0) [self chooseExclusions];
        else if (path.row == 1) [self autoGroup];
        else if (path.row == 2) [self addRule];
        else [self showRule:path.row - 3];
    }
}
@end

@interface SREntry : NSObject
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, strong) UIButton *button;@property(nonatomic, strong) SRSourceCapture *capture;
@property(nonatomic, strong) SRWeChatReceiver *receiver;
@property(nonatomic, strong) SRSourceTimeProbe *sourceTimeProbe;
@property(nonatomic, strong) SRWeChatImageSource *imageSource;
@property(nonatomic, strong) SRWeChatImageSendProbe *imageSendProbe;
@property(nonatomic, strong) SRWeChatSendProbe *sendProbe;
@property(nonatomic, strong) SRWeChatTextSendHost *textSendHost;
@property(nonatomic, strong) SRWeChatImageSendHost *imageSendHost;
@property(nonatomic, strong) SRSmallGroupSession *smallGroupSession;
@property(nonatomic, strong) dispatch_source_t smallGroupTimer;
@property(nonatomic, copy) NSDictionary *lastSmallGroupState;
@property(nonatomic) BOOL smallGroupOwnsIdleTimer;
@property(nonatomic) BOOL smallGroupPreviousIdleTimer;
@property(nonatomic, strong) SRFloatingProgress *floatingProgress;
@property(nonatomic, strong) SRWeChatReader *identityReader;
@property(nonatomic, strong) SREntryPreferences *entryPreferences;
@property(nonatomic, strong) SRWeChatSettingsEntry *settingsEntry;
@property(nonatomic) BOOL settingsFooterActive;
@property(nonatomic, weak) UINavigationController *presented;
@property(nonatomic) CGFloat floatingEntryUnitX;
@property(nonatomic) CGFloat floatingEntryUnitY;
@property(nonatomic) BOOL floatingEntryPlacementSet;
@property(nonatomic) BOOL floatingEntryDragging;
@end
@implementation SREntry
/* Locates the real settings panel inside the presented navigation stack.
 * The stack shape depends on how the settings were reached: the standalone
 * settings entry has the panel as its root, while the operations home has the
 * panel pushed on top of the home. The root controller therefore differs
 * between the two, so reading it would find the home instead of the settings
 * panel and report the wrong dirty/idle/experiment/countdown state. Pushing a
 * sub-page (group picker, content viewer, plan list) does not move the root;
 * the panel is found by its type anywhere in the stack.
 * Returns nil when no settings panel is presented. */
- (SRPanel *)presentedSettingsPanel {
    for (UIViewController *controller in self.presented.viewControllers)
        if ([controller isKindOfClass:SRPanel.class]) return (SRPanel *)controller;
    return nil;
}
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
- (void)acceptCapturedMessage:(NSDictionary *)message evidence:(NSDictionary *)evidence {
    if ([self.capture offerEnvelope:message evidence:evidence]) {
        [SRRuntimeLog.shared record:@"capture_accepted" facts:@{}];
        [self.receiver stop]; [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
    } else {
        if ([message[@"type"] isEqual:@"image"]) [self.store.imageAssets discardPayload:message[@"payload"]];
        [SRRuntimeLog.shared record:@"capture_rejected" facts:@{@"reasonCode": self.capture.diagnostics[@"lastReasonCode"] ?: @0}];
    }
}
- (void)prepareCapture {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    self.capture = [[SRSourceCapture alloc] initWithStore:self.store];
    self.imageSource = [[SRWeChatImageSource alloc] initWithClassResolver:^Class(NSString *name) { return NSClassFromString(name); }];
    self.identityReader = [[SRWeChatReader alloc] initWithVersion:version classResolver:^Class(NSString *name) { return NSClassFromString(name); }];
    __weak typeof(self) weakSelf = self;
    void (^received)(NSDictionary *) = ^(NSDictionary *message) {
        [weakSelf acceptCapturedMessage:message evidence:nil];
    };
    void (^receivedWithTime)(NSDictionary *, NSDictionary *) = ^(NSDictionary *message, NSDictionary *evidence) {
        [weakSelf acceptCapturedMessage:message evidence:evidence];
    };
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
        } received:received];
    self.sourceTimeProbe = [[SRSourceTimeProbe alloc] initWithReceiver:self.receiver
        classResolver:^Class(NSString *name) { return NSClassFromString(name); }
        currentAccount:^NSString * {
            SREntry *entry = weakSelf;
            return entry && [entry.identityReader connect:NULL] ? entry.identityReader.accountID : nil;
        } configurationForAccount:^NSDictionary *(NSString *account) { return [weakSelf.store configurationForAccount:account error:NULL]; }
        environmentAllowed:^BOOL {
            SREntry *entry = weakSelf;
            // Switching WeChat pages can transiently make the app inactive without
            // entering background. Once armed, do not consult the settings panel:
            // it may be dismissed or replaced while the host remains foreground.
            if (!entry || UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return NO;
            if (entry.sourceTimeProbe.active) return !entry.smallGroupSession.busy && [entry.capture.status[@"state"] isEqual:@"idle"] &&
                ![entry.sendProbe.diagnostics[@"armed"] boolValue] && ![entry.textSendHost.diagnostics[@"observing"] boolValue] &&
                ![entry.imageSendHost.diagnostics[@"observing"] boolValue];
            SRPanel *panel = [entry presentedSettingsPanel];
            BOOL panelIdle = ![panel isKindOfClass:SRPanel.class] || (!panel.dirty && !panel.ownsIdleTimer &&
                !panel.singleTextSendEnabled && !panel.singleImageSendEnabled && !panel.textCountdown && !panel.imageCountdown);
            return panelIdle && !entry.smallGroupSession.busy && [entry.capture.status[@"state"] isEqual:@"idle"] &&
                ![entry.sendProbe.diagnostics[@"armed"] boolValue] && ![entry.textSendHost.diagnostics[@"observing"] boolValue] &&
                ![entry.imageSendHost.diagnostics[@"observing"] boolValue];
        } monotonicClock:^double { return NSProcessInfo.processInfo.systemUptime; }
        wallClock:^NSTimeInterval { return NSDate.date.timeIntervalSince1970; } legacyReceived:receivedWithTime
        changed:^{ [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil]; }];
    self.receiver.prepareImage = ^NSDictionary *(id wrap, NSDictionary *source, NSError **error) {
        SREntry *entry = weakSelf; if (!entry) return nil;
        UIImage *image = [entry.imageSource imageForWrap:wrap error:error];
        if (!image) return nil;
        CGImageRef raster = image.CGImage;
        size_t width = raster ? CGImageGetWidth(raster) : 0, height = raster ? CGImageGetHeight(raster) : 0;
        if (!width || !height || image.images.count > 1 || width > 12000 || height > 12000 || (uint64_t)width * height > 32000000ULL) {
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.ImageAsset" code:8
                userInfo:@{NSLocalizedDescriptionKey: @"Image dimensions exceed the capture limit"}];
            return nil;
        }
        NSData *data = UIImagePNGRepresentation(image);
        return [entry.store.imageAssets saveData:data source:source error:error];
    };
    self.receiver.discardImage = ^(NSDictionary *payload) { [weakSelf.store.imageAssets discardPayload:payload]; };
    self.receiver.trace = ^(NSString *event, NSDictionary *facts) {
        [SRRuntimeLog.shared record:event facts:facts];
        if ([event hasPrefix:@"image_"]) dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
        });
    };
    self.sendProbe = [[SRWeChatSendProbe alloc] initWithVersion:version classResolver:^Class(NSString *name) { return NSClassFromString(name); }
        currentAccount:^NSString * {
            SREntry *entry = weakSelf; if (!entry) return nil;
            return [entry.identityReader connect:NULL] ? entry.identityReader.accountID : nil;
        } clock:^double { return NSProcessInfo.processInfo.systemUptime; } changed:^{
            [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
        }];
    self.textSendHost = [[SRWeChatTextSendHost alloc] initWithVersion:version
        classResolver:^Class(NSString *name) { return NSClassFromString(name); }
        currentAccount:^NSString * {
            SREntry *entry = weakSelf;
            return entry && [entry.identityReader connect:NULL] ? entry.identityReader.accountID : nil;
        } environmentAllowed:^BOOL {
            SREntry *entry = weakSelf;
            return entry && !entry.sourceTimeProbe.active && UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
                !entry.smallGroupSession.busy && !entry.smallGroupSession.usedNativeHost &&
                ![entry.capture.status[@"state"] isEqual:@"waiting"] && ![entry.sendProbe.diagnostics[@"armed"] boolValue] &&
                ![entry.imageSendHost.diagnostics[@"attemptConsumed"] boolValue];
        }];
    self.imageSendHost = [[SRWeChatImageSendHost alloc] initWithVersion:version
        classResolver:^Class(NSString *name) { return NSClassFromString(name); }
        currentAccount:^NSString * {
            SREntry *entry = weakSelf;
            return entry && [entry.identityReader connect:NULL] ? entry.identityReader.accountID : nil;
        } environmentAllowed:^BOOL {
            SREntry *entry = weakSelf;
            SRPanel *panel = [entry presentedSettingsPanel];
            return entry && !entry.sourceTimeProbe.active && [panel isKindOfClass:SRPanel.class] && panel.singleImageSendEnabled &&
                !entry.smallGroupSession.busy && !entry.smallGroupSession.usedNativeHost &&
                panel.viewIfLoaded.window && UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
                !panel.dirty && ![entry.capture.status[@"state"] isEqual:@"waiting"] &&
                ![entry.sendProbe.diagnostics[@"armed"] boolValue] && ![entry.textSendHost.diagnostics[@"submissionAttempted"] boolValue];
        } materialLoader:^NSDictionary *(NSDictionary *source, NSError **error) {
            return SRCreateImageMaterial(weakSelf.store.imageAssets, source, error);
        }];
    self.imageSendProbe = [[SRWeChatImageSendProbe alloc] initWithVersion:version
        classResolver:^Class(NSString *name) { return NSClassFromString(name); }
        currentAccount:^NSString * {
            SREntry *entry = weakSelf;
            return entry && [entry.identityReader connect:NULL] ? entry.identityReader.accountID : nil;
        } environmentAllowed:^BOOL {
            SREntry *entry = weakSelf;
            return entry && !entry.sourceTimeProbe.active && UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
                !entry.smallGroupSession.busy &&
                ![entry.capture.status[@"state"] isEqual:@"waiting"] && ![entry.sendProbe.diagnostics[@"armed"] boolValue] &&
                ![entry.textSendHost.diagnostics[@"observing"] boolValue] && ![entry.imageSendHost.diagnostics[@"observing"] boolValue];
        }];
    self.smallGroupSession = [[SRSmallGroupSession alloc] initWithStore:self.store currentAccount:^NSString * {
        SREntry *entry = weakSelf;
        return entry && [entry.identityReader connect:NULL] ? entry.identityReader.accountID : nil;
    } environmentAllowed:^BOOL {
        SREntry *entry = weakSelf;
        SRPanel *panel = [entry presentedSettingsPanel];
        BOOL panelIdle = ![panel isKindOfClass:SRPanel.class] || (!panel.dirty && !panel.ownsIdleTimer && !panel.textCountdown && !panel.imageCountdown);
        return entry && !entry.sourceTimeProbe.active && panelIdle && UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
            ![entry.capture.status[@"state"] isEqual:@"waiting"] && ![entry.sendProbe.diagnostics[@"armed"] boolValue] &&
            ![entry.textSendHost.diagnostics[@"submissionAttempted"] boolValue] && ![entry.imageSendHost.diagnostics[@"attemptConsumed"] boolValue];
    } targetAllowed:^BOOL(NSString *target) {
        SREntry *entry = weakSelf;
        for (NSDictionary *group in [entry.identityReader groups:NULL]) if ([group[@"id"] isEqual:target]) return YES;
        return NO;
    } hostFactory:^id<SRSmallGroupHost>(NSDictionary *source, BOOL (^allowed)(void)) {
        NSString *(^account)(void) = ^NSString * {
            SREntry *entry = weakSelf;
            return entry && [entry.identityReader connect:NULL] ? entry.identityReader.accountID : nil;
        };
        if ([source[@"type"] isEqual:@"image"]) return (id<SRSmallGroupHost>)[[SRWeChatImageSendHost alloc] initWithVersion:version
            classResolver:^Class(NSString *name) { return NSClassFromString(name); } currentAccount:account environmentAllowed:allowed
            materialLoader:^NSDictionary *(NSDictionary *imageSource, NSError **error) { return SRCreateImageMaterial(weakSelf.store.imageAssets, imageSource, error); }];
        return (id<SRSmallGroupHost>)[[SRWeChatTextSendHost alloc] initWithVersion:version
            classResolver:^Class(NSString *name) { return NSClassFromString(name); } currentAccount:account environmentAllowed:allowed];
    } clock:^double { return NSProcessInfo.processInfo.systemUptime; }
        random:^double { return (double)arc4random_uniform(UINT32_MAX) / (double)UINT32_MAX; }];
    self.smallGroupTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.smallGroupTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_MSEC * 100);
    dispatch_source_set_event_handler(self.smallGroupTimer, ^{ [weakSelf updateSmallGroupState]; });
    dispatch_resume(self.smallGroupTimer);
}
- (void)updateSmallGroupState {
    [self.sourceTimeProbe tick];
    [self.smallGroupSession tick];
    BOOL hold = self.smallGroupSession.needsIdleTimer;
    if (hold && !self.smallGroupOwnsIdleTimer) {
        self.smallGroupPreviousIdleTimer = UIApplication.sharedApplication.idleTimerDisabled;
        self.smallGroupOwnsIdleTimer = YES; UIApplication.sharedApplication.idleTimerDisabled = YES;
    } else if (!hold && self.smallGroupOwnsIdleTimer) {
        self.smallGroupOwnsIdleTimer = NO; UIApplication.sharedApplication.idleTimerDisabled = self.smallGroupPreviousIdleTimer;
    }
    NSDictionary *state = self.smallGroupSession.status;
    if (![state isEqual:self.lastSmallGroupState]) {
        self.lastSmallGroupState = state;
        [NSNotificationCenter.defaultCenter postNotificationName:@"andyz.syncrelay.smallGroupChanged" object:nil];
    }
    [self refreshFloatingProgress];
}
- (void)refreshFloatingProgress {
    if (self.presented && !self.presented.presentingViewController && !self.presented.viewIfLoaded.window) self.presented = nil;
    if (self.presented.presentingViewController) { [self.floatingProgress hide]; return; }
    self.button.hidden = self.presented.presentingViewController != nil || self.smallGroupSession.busy;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self.floatingProgress hide]; return;
    }
    NSDictionary *model = nil;
    if ([self.smallGroupSession progressBelongsToCurrentAccount]) {
        NSDictionary *progress = [SRExecutionProgress modelForStatus:self.smallGroupSession.status];
        if ([progress[@"visible"] boolValue]) {
            NSMutableDictionary *mutable = [progress mutableCopy]; mutable[@"menuEnabled"] = @YES; model = mutable;
        }
    }
    NSDictionary *captureStatus = self.capture.status;
    NSString *account = [self.identityReader connect:NULL] ? self.identityReader.accountID : nil;
    BOOL captureBelongs = account.length && [captureStatus[@"account"] isEqual:account];
    NSDictionary *operations = account.length ? [self.store operationsContentForAccount:account error:NULL] : nil;
    NSDictionary *currentContent = [operations[@"current"] isKindOfClass:NSDictionary.class] ? operations[@"current"] : nil;
    NSDictionary *recentContent = [operations[@"recent"] isKindOfClass:NSDictionary.class] ? operations[@"recent"] : nil;
    if (!model && captureBelongs && self.capture.preview) {
        model = @{ @"visible": @YES, @"countText": @"新消息", @"phase": @"ready", @"action": @"open",
            @"actionEnabled": @YES, @"menuEnabled": @YES };
    } else if (!model && captureBelongs && [captureStatus[@"state"] isEqual:@"waiting"]) {
        model = @{ @"visible": @YES, @"countText": @"...", @"phase": @"waiting", @"action": @"open",
            @"actionEnabled": @YES, @"menuEnabled": @YES };
    } else if (!model && captureBelongs && [self.smallGroupSession.status[@"state"] isEqual:@"completed"]) {
        model = @{ @"visible": @YES, @"countText": @"完成", @"phase": @"completed", @"action": @"open",
            @"actionEnabled": @YES, @"menuEnabled": @YES };
    } else if (!model && currentContent) {
        model = @{ @"visible": @YES, @"countText": @"待转发", @"phase": @"ready", @"action": @"open",
            @"actionEnabled": @YES, @"menuEnabled": @YES };
    } else if (!model && recentContent) {
        model = @{ @"visible": @YES, @"countText": @"完成", @"phase": @"completed", @"action": @"open",
            @"actionEnabled": @YES, @"menuEnabled": @YES };
    }
    if (!model) { [self.floatingProgress hide]; return; }
    if (![model[@"visible"] boolValue]) { [self.floatingProgress hide]; return; }
    UIWindow *host = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            if (window.isKeyWindow && window.windowLevel == UIWindowLevelNormal && window.rootViewController) { host = window; break; }
        if (host) break;
    }
    if (!host) { [self.floatingProgress hide]; return; }
    if (!self.floatingProgress) {
        self.floatingProgress = [[SRFloatingProgress alloc] initWithFrame:CGRectZero];
        __weak typeof(self) weakSelf = self;
        self.floatingProgress.action = ^{
            SREntry *entry = weakSelf;
            [entry.smallGroupSession togglePauseForCurrentAccount:NULL];
            [entry updateSmallGroupState];
        };
        self.floatingProgress.openAction = ^{ [weakSelf openOperationsFromController:nil]; };
        self.floatingProgress.menuAction = ^{ [weakSelf showOperationsMenu]; };
    }
    [self.floatingProgress showModel:model inWindow:host]; self.button.hidden = YES;
}
- (void)showOperationsMenu {
    if (self.presented.presentingViewController) return;
    UIViewController *presenter = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow && window.windowLevel == UIWindowLevelNormal) { presenter = window.rootViewController; break; }
        }
        if (presenter) break;
    }
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"SyncRelay 运营" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"打开运营首页" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self openOperationsFromController:presenter];
    }]];
    NSString *account = [self.identityReader connect:NULL] ? self.identityReader.accountID : nil;
    NSString *run = self.smallGroupSession.currentRunID;
    if ([self.smallGroupSession progressBelongsToCurrentAccount] && run.length) {
        [menu addAction:[UIAlertAction actionWithTitle:@"取消本组发送" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
            UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"取消本组发送？"
                message:@"尚未尝试的目标将取消；已提交或在途消息无法撤回，其他分组不会自动开始。" preferredStyle:UIAlertControllerStyleAlert];
            [confirm addAction:[UIAlertAction actionWithTitle:@"继续发送" style:UIAlertActionStyleCancel handler:nil]];
            [confirm addAction:[UIAlertAction actionWithTitle:@"取消本组" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x) {
                [self.smallGroupSession cancelRun:run account:account error:NULL];
                [self updateSmallGroupState];
            }]];
            [presenter presentViewController:confirm animated:YES completion:nil];
        }]];
    } else if (self.capture.preview) {
        [menu addAction:[UIAlertAction actionWithTitle:@"放弃当前预览" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
            [self.capture cancel]; [self updateSmallGroupState];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"进入设置" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self openFromController:presenter];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = self.floatingProgress;
    menu.popoverPresentationController.sourceRect = self.floatingProgress.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}
- (CGRect)floatingEntryAvailableBoundsInWindow:(UIWindow *)window {
    if (!window) return CGRectZero;
    return CGRectInset(UIEdgeInsetsInsetRect(window.bounds, window.safeAreaInsets), 12, 12);
}
- (void)placeFloatingEntryButtonInWindow:(UIWindow *)window {
    if (!self.button || self.button.superview != window || self.floatingEntryDragging) return;
    CGRect bounds = [self floatingEntryAvailableBoundsInWindow:window];
    if (CGRectIsEmpty(bounds)) return;
    CGFloat width = MAX(72, ceil(self.button.intrinsicContentSize.width + 28));
    width = MIN(width, CGRectGetWidth(bounds));
    CGFloat height = MIN(44, CGRectGetHeight(bounds));
    CGSize size = CGSizeMake(width, height);
    CGFloat x = CGRectGetMaxX(bounds) - width;
    CGFloat y = CGRectGetMaxY(bounds) - height - 60;
    if (self.floatingEntryPlacementSet) {
        CGFloat travelX = MAX(0, CGRectGetWidth(bounds) - width);
        CGFloat travelY = MAX(0, CGRectGetHeight(bounds) - height);
        x = CGRectGetMinX(bounds) + travelX * MAX(0, MIN(1, self.floatingEntryUnitX));
        y = CGRectGetMinY(bounds) + travelY * MAX(0, MIN(1, self.floatingEntryUnitY));
    }
    x = MAX(CGRectGetMinX(bounds), MIN(x, CGRectGetMaxX(bounds) - width));
    y = MAX(CGRectGetMinY(bounds), MIN(y, CGRectGetMaxY(bounds) - height));
    self.button.frame = (CGRect){CGPointMake(x, y), size};
    self.button.layer.cornerRadius = height / 2;
}
- (void)floatingEntryDragged:(UIPanGestureRecognizer *)pan {
    UIWindow *window = self.button.window;
    if (!window) return;
    if (pan.state == UIGestureRecognizerStateBegan) self.floatingEntryDragging = YES;
    CGPoint translation = [pan translationInView:window];
    [pan setTranslation:CGPointZero inView:window];
    CGRect bounds = [self floatingEntryAvailableBoundsInWindow:window];
    CGRect frame = self.button.frame;
    frame.origin.x += translation.x; frame.origin.y += translation.y;
    frame.origin.x = MAX(CGRectGetMinX(bounds), MIN(frame.origin.x, CGRectGetMaxX(bounds) - frame.size.width));
    frame.origin.y = MAX(CGRectGetMinY(bounds), MIN(frame.origin.y, CGRectGetMaxY(bounds) - frame.size.height));
    self.button.frame = frame;
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {
        self.floatingEntryDragging = NO;
        self.floatingEntryPlacementSet = YES;
        CGFloat travelX = CGRectGetWidth(bounds) - CGRectGetWidth(frame);
        CGFloat travelY = CGRectGetHeight(bounds) - CGRectGetHeight(frame);
        self.floatingEntryUnitX = travelX > 0 ? MAX(0, MIN(1, (CGRectGetMinX(frame) - CGRectGetMinX(bounds)) / travelX)) : 1;
        self.floatingEntryUnitY = travelY > 0 ? MAX(0, MIN(1, (CGRectGetMinY(frame) - CGRectGetMinY(bounds)) / travelY)) : 0;
        [self.entryPreferences setFloatingEntryPlacementUnitX:self.floatingEntryUnitX unitY:self.floatingEntryUnitY];
        if (UIAccessibilityIsReduceMotionEnabled()) [self placeFloatingEntryButtonInWindow:window];
        else [UIView animateWithDuration:0.18 animations:^{ [self placeFloatingEntryButtonInWindow:window]; }];
    }
}
- (void)install {
    [self.settingsEntry install:NULL];
    [self refreshVisibleSettings];
    self.floatingEntryUnitX = self.entryPreferences.floatingEntryUnitX;
    self.floatingEntryUnitY = self.entryPreferences.floatingEntryUnitY;
    self.floatingEntryPlacementSet = self.entryPreferences.floatingEntryPlacementSet;
    if (!self.entryPreferences.floatingEntryEnabled) {
        [self.button removeFromSuperview]; self.button = nil; return;
    }
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSString *title = self.capture.preview ? @"预览" : ([self.sendProbe.diagnostics[@"armed"] boolValue] ? @"观察" : @"同步");
    [self.button setTitle:title forState:UIControlStateNormal];
    self.button.hidden = self.presented.presentingViewController != nil || self.smallGroupSession.busy;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow || window.windowLevel != UIWindowLevelNormal || !window.rootViewController) continue;
            if (self.button.superview == window) {
                [self placeFloatingEntryButtonInWindow:window];
                self.button.hidden = self.presented.presentingViewController != nil || self.smallGroupSession.busy;
                return;
            }
            [self.button removeFromSuperview];
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            [button setTitle:title forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
            button.titleLabel.adjustsFontForContentSizeCategory = YES;
            button.backgroundColor = UIColor.secondarySystemBackgroundColor; button.layer.cornerRadius = 22;
            button.accessibilityLabel = @"打开 SyncRelay 运营";
            button.accessibilityHint = @"可自由拖动位置；轻触打开运营首页";
            [button addTarget:self action:@selector(openOperations) forControlEvents:UIControlEventTouchUpInside];
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(floatingEntryDragged:)];
            pan.cancelsTouchesInView = YES;
            [button addGestureRecognizer:pan];
            button.translatesAutoresizingMaskIntoConstraints = YES; [window addSubview:button];
            self.button = button;
            [self placeFloatingEntryButtonInWindow:window];
            self.button.hidden = self.presented.presentingViewController != nil || self.smallGroupSession.busy;
            return;
        }
    }
}
- (void)open {
    [self openFromController:nil];
}
/* The idle floating entry is the operations home entry. It reuses the same
 * presenter resolution and account binding as the capsule route, so an idle
 * device reaches the home without a preview, plan, run or history. Opening the
 * home only projects state: it never arms a receiver, starts a probe, confirms
 * a plan, restores a run or sends anything. */
- (void)openOperations {
    [self openOperationsFromController:nil];
}
- (void)openOperationsFromController:(UIViewController *)controller {
    if (!NSThread.isMainThread || UIApplication.sharedApplication.applicationState != UIApplicationStateActive || self.presented.presentingViewController) return;
    NSString *account = [self.identityReader connect:NULL] ? self.identityReader.accountID : nil;
    if (!account.length) return;
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
    BOOL (^verify)(void) = ^BOOL {
        SREntry *entry = self;
        return entry && [entry.identityReader verifyAccount:account error:NULL];
    };
    /* The home routes to the existing settings panel through an explicit
     * callback bound to the account captured above. The callback re-verifies
     * that account, so a changed account refuses the old page instead of
     * silently switching to the new one. The home's own navigation controller
     * is captured weakly: the navigation owns the home and the home owns this
     * block, so a strong capture would form a retain cycle. The navigation is
     * fetched back and re-checked at call time instead. */
    __weak typeof(self) weakSelf = self;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[[UIViewController alloc] init]];
    __weak UINavigationController *weakNavigation = navigation;
    void (^openSettings)(void) = ^void {
        SREntry *entry = weakSelf;
        if (!entry) return;
        UINavigationController *current = weakNavigation;
        /* The route is only valid while it still owns the home page that
         * started it. A stale callback must not push into another stack. */
        if (!current || current != entry.presented) return;
        NSString *currentAccount = [entry.identityReader connect:NULL] ? entry.identityReader.accountID : nil;
        if (!currentAccount.length || ![currentAccount isEqual:account]) return;
        [entry openSettingsFromNavigation:current account:currentAccount verify:verify];
    };
    UIViewController *home = SRCreateOperationsHome(self.store, self.capture, self.smallGroupSession, account, verify, openSettings);
    navigation.viewControllers = @[home];
    UINavigationController *hostNavigation = [presenter isKindOfClass:UINavigationController.class] ? (UINavigationController *)presenter : presenter.navigationController;
    SRStyleSettingsNavigation(navigation, hostNavigation);
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    self.presented = navigation; self.button.hidden = YES; [self.floatingProgress hide];
    [presenter presentViewController:navigation animated:YES completion:nil];
}
/* Presents the existing settings panel on top of the operations home. The panel
 * is built from the same shared objects the entry already uses, so there is no
 * parallel state source, and its own close/draft guard semantics are kept. */
- (void)openSettingsFromNavigation:(UINavigationController *)navigation account:(NSString *)account verify:(BOOL (^)(void))verify {
    if (!NSThread.isMainThread || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (!navigation || !account.length || !verify || !verify()) return;
    /* The route is only valid for the navigation this entry still manages and
     * only while the home that started it is still the visible page of that
     * stack. The home is the root controller, so pushing a page above it does
     * not move the root; the check is on the top of the stack instead. */
    if (navigation != self.presented) return;
    UIViewController *home = navigation.viewControllers.firstObject;
    if (!home || home != navigation.topViewController) return;
    if (![home.title isEqualToString:@"SyncRelay 运营"]) return;
    /* No second settings page: the panel is located anywhere in the stack, so
     * a settings panel that is already there is recognized. */
    if ([self presentedSettingsPanel]) return;
    /* No re-entry while the stack is presenting or dismissing. */
    if (navigation.isBeingPresented || navigation.isBeingDismissed ||
        navigation.transitionCoordinator || navigation.presentedViewController) return;
    SRPanel *panel = [[SRPanel alloc] initWithStyle:UITableViewStyleGrouped]; panel.store = self.store;
    panel.capture = self.capture; panel.receiver = self.receiver; panel.sourceTimeProbe = self.sourceTimeProbe;
    panel.imageSource = self.imageSource;
    panel.imageSendProbe = self.imageSendProbe;
    panel.sendProbe = self.sendProbe;
    panel.textSendHost = self.textSendHost;
    panel.imageSendHost = self.imageSendHost;
    panel.smallGroupSession = self.smallGroupSession;
    panel.entryPreferences = self.entryPreferences; panel.settingsEntry = self.settingsEntry;
    panel.settingsFooterActive = self.settingsFooterActive;
    /* The settings panel keeps its own save, close and unsaved-draft guard. It
     * is pushed onto the home's navigation stack, so closing it returns to the
     * home instead of tearing the whole home down. */
    panel.returnsToOperationsHome = YES;
    panel.didClose = ^{};
    [navigation pushViewController:panel animated:YES];
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
    SRPanel *panel = [[SRPanel alloc] initWithStyle:UITableViewStyleGrouped]; panel.store = self.store;
    panel.capture = self.capture; panel.receiver = self.receiver; panel.sourceTimeProbe = self.sourceTimeProbe;
    panel.imageSource = self.imageSource;
    panel.imageSendProbe = self.imageSendProbe;
    panel.sendProbe = self.sendProbe;
    panel.textSendHost = self.textSendHost;
    panel.imageSendHost = self.imageSendHost;
    panel.smallGroupSession = self.smallGroupSession;
    panel.entryPreferences = self.entryPreferences; panel.settingsEntry = self.settingsEntry;
    panel.settingsFooterActive = self.settingsFooterActive;
    __weak typeof(self) weakSelf = self;
    panel.didClose = ^{ weakSelf.presented = nil; [weakSelf install]; };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:panel];
    UINavigationController *hostNavigation = [presenter isKindOfClass:UINavigationController.class] ? (UINavigationController *)presenter : presenter.navigationController;
    SRStyleSettingsNavigation(navigation, hostNavigation);
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    self.presented = navigation;
    self.button.hidden = YES;
    [presenter presentViewController:navigation animated:YES completion:nil];
}
- (void)windowChanged:(__unused NSNotification *)notification {
    if (NSThread.isMainThread) { [self install]; [self refreshFloatingProgress]; }
    else dispatch_async(dispatch_get_main_queue(), ^{ [self install]; [self refreshFloatingProgress]; });
}
- (void)becameActive:(NSNotification *)notification {
    [self.sourceTimeProbe noteApplicationActive];
    [self windowChanged:notification];
}
- (void)resigningActive:(__unused NSNotification *)notification {
    [self.sourceTimeProbe noteApplicationInactive];
    [self.smallGroupSession becameInactive]; [self updateSmallGroupState];
    [SRRuntimeLog.shared record:@"inactive" facts:@{}];
    [self.sendProbe cancelForInactivity];
    [self.textSendHost stopObservation];
    [self.imageSendHost stopObservation];
    // UIApplicationWillResignActive also fires for transient page/system
    // transitions. Do not tear down the read-only source observer here; the
    // background notification is the actual stop boundary. Manual capture and
    // send observation remain stopped by their existing lifecycle paths.
    [NSNotificationCenter.defaultCenter postNotificationName:SRRelayStateChangedNotification object:nil];
}
- (void)enteredBackground:(__unused NSNotification *)notification {
    [self.sourceTimeProbe stopForReason:SRSourceTimeProbeInactive];
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
    [NSNotificationCenter.defaultCenter addObserver:entry selector:@selector(becameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:entry selector:@selector(windowChanged:) name:UIWindowDidBecomeKeyNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:entry selector:@selector(windowChanged:) name:SRRelayStateChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:entry selector:@selector(windowChanged:) name:SREntryPreferencesChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:entry selector:@selector(resigningActive:) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:entry selector:@selector(enteredBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [entry install];
}
