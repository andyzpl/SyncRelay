#import "SRPanel.h"
#import "Core/SRStore.h"
#import "Core/SRSelection.h"
#import "Core/SRConfiguration.h"
#import "Adapter/SRWeChatReader.h"

static void SRAlert(UIViewController *controller, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

@interface SRPicker : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, strong) SRSelection *selection;
@property(nonatomic, copy) NSArray<NSDictionary *> *visibleRows;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic) BOOL multiple;
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
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
        NSMutableArray *actions = [NSMutableArray array];
        for (NSNumber *count in @[@100, @200, @(NSUIntegerMax), @0]) {
            NSString *title = [count unsignedIntegerValue] == NSUIntegerMax ? @"全选全部可选项" :
                ([count unsignedIntegerValue] == 0 ? @"清空选择" : [NSString stringWithFormat:@"选前 %@ 个", count]);
            __weak typeof(self) weakSelf = self;
            [actions addObject:[UIAction actionWithTitle:title image:nil identifier:nil handler:^(__unused UIAction *action) {
                [weakSelf.selection selectFirst:count.unsignedIntegerValue]; [weakSelf refresh];
            }]];
        }
        self.navigationItem.leftItemsSupplementBackButton = YES;
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"批量" menu:[UIMenu menuWithTitle:@"按完整可选列表选择，不受搜索过滤影响" children:actions]];
    }
    [self refresh];
}
- (void)refresh {
    self.visibleRows = [self.selection rowsMatching:self.search.searchBar.text ?: @""];
    self.navigationItem.prompt = [NSString stringWithFormat:@"可选 %lu · 已选 %lu · 搜索结果 %lu", (unsigned long)self.selection.rows.count,
        (unsigned long)self.selection.selectedRows.count, (unsigned long)self.visibleRows.count];
    self.navigationItem.rightBarButtonItem.enabled = self.selection.selectedRows.count > 0;
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
    if (!self.selection.selectedRows.count) return;
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
    self.title = @"同步转发";
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 64;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存草稿" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    self.reader = [[SRWeChatReader alloc] initWithVersion:version classResolver:^Class(NSString *name) { return NSClassFromString(name); }];
    self.draft = [SRConfiguration emptyDraft];
    [self loadAccount];
}
- (void)loadAccount {
    NSError *error = nil;
    self.ready = [self.reader connect:&error];
    self.account = self.reader.accountID;
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
        self.status = error.localizedDescription ?: @"请先重新读取账号";
        [self refresh]; SRAlert(self, @"操作已停止", self.status); return NO;
    }
    return YES;
}
- (void)refresh {
    self.navigationItem.rightBarButtonItem.enabled = self.ready;
    self.navigationItem.prompt = self.dirty ? @"有未保存的修改" : @"0.2.0 · 只读适配与配置草稿";
    [self.tableView reloadData];
}
- (void)changed { self.dirty = YES; [self refresh]; }
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
    SRAlert(self, @"草稿已保存", @"下次打开会恢复该账号的来源、类型和目标分组。保存不会创建发送任务。" );
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 4; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 3;
    if (section == 1) return 4;
    if (section == 2) return 1;
    return [self.draft[@"rules"] count] + 1;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"适配状态", @"消息来源", @"发送节拍", @"目标分组"][section];
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return self.status;
    if (section == 1) return @"发送者以微信原始 wxid 匹配，昵称只用于辨认。本版仅配置，尚未捕获或发送消息。";
    if (section == 2) return @"下限至少 10 秒；上下限相同则固定间隔。随机节拍不代表平台允许或保证发送成功。";
    return @"已分配群在新增分组时自动排除。这里只保存草稿；尚未提供开始、重试或重新执行按钮。";
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
        if (path.row == 2) { cell.textLabel.text = @"查看适配诊断"; cell.detailTextLabel.text = @"仅版本与接口签名，不含成员或消息内容"; }
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
    } else {
        NSArray *rules = self.draft[@"rules"];
        if (path.row == (NSInteger)rules.count) { cell.textLabel.text = @"添加目标分组"; cell.detailTextLabel.text = @"选 100 / 200 个，或全选可选群"; }
        else { NSDictionary *rule = rules[path.row]; cell.textLabel.text = rule[@"name"]; cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 个群 · 点击查看或移除分组", (unsigned long)[rule[@"targets"] count]]; }
    }
    if (path.section > 0 && !self.ready) cell.textLabel.textColor = UIColor.tertiaryLabelColor;
    return cell;
}
- (void)typeChanged:(UISwitch *)toggle {
    if (![self checkAccount]) { [self refresh]; return; }
    NSMutableArray *types = [self.draft[@"types"] mutableCopy];
    NSString *type = toggle.tag == 2 ? @"text" : @"image";
    if (toggle.on) [types addObject:type]; else [types removeObject:type];
    if (!types.count) { toggle.on = YES; SRAlert(self, @"至少保留一种类型", @"请选择文字、图片或两者。"); return; }
    self.draft[@"types"] = types; [self changed];
}
- (void)picker:(NSString *)title rows:(NSArray *)rows selected:(NSArray *)selected excluded:(NSSet *)excluded multiple:(BOOL)multiple completion:(void (^)(NSArray *))completion {
    SRPicker *picker = [[SRPicker alloc] initWithStyle:UITableViewStyleInsetGrouped];
    picker.title = title; picker.multiple = multiple;
    picker.note = [self.reader.warnings componentsJoinedByString:@"\n"];
    picker.selection = [[SRSelection alloc] initWithRows:rows excludedIDs:excluded selectedIDs:[NSSet setWithArray:[selected valueForKey:@"id"]]];
    __weak typeof(self) weakSelf = self;
    picker.completion = ^(NSArray *chosen) { if ([weakSelf checkAccount]) completion(chosen); };
    [self.navigationController pushViewController:picker animated:YES];
}
- (void)chooseSource {
    NSError *error = nil; NSArray *groups = [self.reader groups:&error];
    if (!groups) { SRAlert(self, @"无法读取群", error.localizedDescription); return; }
    __weak typeof(self) weakSelf = self;
    [self picker:@"选择母群" rows:groups selected:@[] excluded:NSSet.set multiple:NO completion:^(NSArray *chosen) {
        if ([chosen[0][@"id"] isEqual:weakSelf.draft[@"sourceGroup"][@"id"]]) return;
        void (^apply)(void) = ^{ weakSelf.draft[@"sourceGroup"] = chosen[0]; weakSelf.draft[@"senders"] = @[]; weakSelf.draft[@"rules"] = @[]; [weakSelf changed]; };
        if ([weakSelf.draft[@"rules"] count] || [weakSelf.draft[@"senders"] count]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"更换母群？" message:@"将清空当前发送者和目标分组，避免沿用错误来源。保存前不会改变旧草稿。" preferredStyle:UIAlertControllerStyleAlert];
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
    [self picker:@"指定发送者 · wxid" rows:members selected:self.draft[@"senders"] excluded:NSSet.set multiple:YES completion:^(NSArray *chosen) {
        weakSelf.draft[@"senders"] = chosen; [weakSelf changed];
    }];
}
- (void)addRule {
    if (![self.draft[@"sourceGroup"] count]) { SRAlert(self, @"先选择母群", @"目标群必须排除母群。"); return; }
    NSError *error = nil; NSArray *groups = [self.reader groups:&error];
    if (!groups) { SRAlert(self, @"无法读取群", error.localizedDescription); return; }
    NSMutableSet *excluded = [NSMutableSet setWithObject:self.draft[@"sourceGroup"][@"id"]];
    for (NSDictionary *rule in self.draft[@"rules"]) [excluded addObjectsFromArray:[rule[@"targets"] valueForKey:@"id"]];
    __weak typeof(self) weakSelf = self;
    [self picker:@"选择目标群" rows:groups selected:@[] excluded:excluded multiple:YES completion:^(NSArray *chosen) {
        NSMutableArray *rules = [weakSelf.draft[@"rules"] mutableCopy];
        NSUInteger number = rules.count + 1;
        NSString *name = [NSString stringWithFormat:@"规则 %lu", (unsigned long)number];
        NSSet *names = [NSSet setWithArray:[rules valueForKey:@"name"]];
        while ([names containsObject:name]) name = [NSString stringWithFormat:@"规则 %lu", (unsigned long)++number];
        [rules addObject:@{@"id": NSUUID.UUID.UUIDString, @"name": name, @"targets": chosen}];
        weakSelf.draft[@"rules"] = rules; [weakSelf changed];
    }];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:rule[@"name"] message:@"此分组尚未执行。移除后，其中的群可重新分配。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"查看目标" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self picker:rule[@"name"] rows:rule[@"targets"] selected:@[] excluded:NSSet.set multiple:NO completion:^(NSArray *chosen) {
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
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 0) {
        if (path.row == 1) {
            if (self.dirty) { SRAlert(self, @"有未保存的修改", @"请先保存，或关闭并放弃修改后重新打开。"); return; }
            [self loadAccount];
        }
        if (path.row == 2) [self showDiagnostics];
        return;
    }
    if (![self checkAccount]) return;
    if (path.section == 1 && path.row == 0) [self chooseSource];
    if (path.section == 1 && path.row == 1) [self chooseSenders];
    if (path.section == 2) [self editInterval];
    if (path.section == 3) {
        if (path.row == (NSInteger)[self.draft[@"rules"] count]) [self addRule]; else [self showRule:path.row];
    }
}
@end

@interface SREntry : NSObject
@property(nonatomic, strong) SRStore *store;
@property(nonatomic, strong) UIButton *button;
@property(nonatomic, weak) UINavigationController *presented;
@end
@implementation SREntry
- (void)install {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.button.hidden = self.presented.presentingViewController != nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow || window.windowLevel != UIWindowLevelNormal || !window.rootViewController) continue;
            if (self.button.superview == window) return;
            [self.button removeFromSuperview];
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            [button setTitle:@"同步" forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
            button.titleLabel.adjustsFontForContentSizeCategory = YES;
            button.backgroundColor = UIColor.secondarySystemBackgroundColor; button.layer.cornerRadius = 22;
            button.accessibilityLabel = @"打开 SyncRelay 同步转发设置";
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
    if (self.presented.presentingViewController) return;
    UIViewController *presenter = ((UIWindow *)self.button.superview).rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter || presenter.isBeingDismissed || presenter.isBeingPresented || [presenter isKindOfClass:UIAlertController.class]) return;
    SRPanel *panel = [[SRPanel alloc] initWithStyle:UITableViewStyleInsetGrouped]; panel.store = self.store;
    __weak typeof(self) weakSelf = self;
    panel.didClose = ^{ weakSelf.button.hidden = NO; };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:panel];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    self.presented = navigation;
    self.button.hidden = YES;
    [presenter presentViewController:navigation animated:YES completion:nil];
}
- (void)windowChanged:(__unused NSNotification *)notification { [self install]; }
@end

void SRInstallPanelEntry(SRStore *store) {
    NSCAssert(NSThread.isMainThread, @"UI entry must be installed on main thread");
    static SREntry *entry;
    if (entry) return;
    entry = [[SREntry alloc] init]; entry.store = store;
    [NSNotificationCenter.defaultCenter addObserver:entry selector:@selector(windowChanged:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:entry selector:@selector(windowChanged:) name:UIWindowDidBecomeKeyNotification object:nil];
    [entry install];
}
