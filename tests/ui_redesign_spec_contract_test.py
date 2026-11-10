"""Approved four-entry navigation and capsule source contracts.

These do not execute UIKit. Group pool classification has native Foundation
coverage; docking thresholds execute in capsule_geometry_test.c.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCREENS = (ROOT / 'UI/SRPlanScreens.m').read_text(encoding='utf-8')
PANEL = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
CAPSULE = (ROOT / 'UI/SRFloatingProgress.m').read_text(encoding='utf-8')
HOME = SCREENS.split('@implementation SRNavigationHomeScreen', 1)[1].split('@end', 1)[0]


class UIRedesignSpecContracts(unittest.TestCase):
    def test_home_has_exactly_the_four_approved_destinations(self):
        self.assertIn('@[@"群同步", @"消息库转发", @"群分组", @"设置"][path.row]', HOME)
        self.assertIn('section == 0 ? 1 : 4', HOME)
        self.assertIn('constraintGreaterThanOrEqualToConstant:74', SCREENS)
        for forbidden in ('runSummary:', 'confirmForCurrentAccount:', 'armForAccount:', 'startRule:', 'UISwitch'):
            self.assertNotIn(forbidden, HOME)

    def test_missing_source_hint_is_not_a_library_gate(self):
        tap = HOME.split('didSelectRowAtIndexPath:', 1)[1].split('- (void)close', 1)[0]
        self.assertIn('destination < 4 && self.openDestination', tap)
        self.assertNotIn('sourceGroup', tap)
        self.assertNotIn('self.problem', tap)
        self.assertIn('else if (![self.configuration[@"sourceGroup"][@"id"] length]) self.hintDestination = 0', HOME)

    def test_read_failure_is_not_rendered_as_zero_groups(self):
        self.assertIn('if (!self.configuration) self.problem =', HOME)
        self.assertIn('if (self.problem && (path.row == 0 || path.row == 2))', HOME)
        self.assertIn('self.configuration = nil;', HOME)
        self.assertIn('UIApplicationWillResignActiveNotification', HOME)

    def test_four_destinations_share_the_bound_navigation_and_account(self):
        route = PANEL.split('- (void)openOperationsFromController:', 1)[1].split('\n}', 1)[0]
        self.assertIn('SRCreateNavigationHome(self.store, account, verify, openDestination)', route)
        self.assertIn('if (destination == 1)', route)
        self.assertIn('SRCreateLibraryList(entry.store, account, verify, entry.smallGroupSession)', route)
        self.assertIn('SRPanelPageSource', route)
        self.assertIn('SRPanelPageGroups', route)
        self.assertIn('SRPanelPageSettings', route)
        self.assertIn('current.topViewController != entry.operationsHome', route)
        self.assertIn('![currentAccount isEqual:account]', route)
        push = PANEL.split('- (void)openSettingsFromNavigation:', 1)[1].split('\n}', 1)[0]
        self.assertIn('panel.page = page; panel.expectedAccount = account', push)

    def test_normal_pages_do_not_publish_experiment_actions(self):
        sections = PANEL.split('- (NSArray<NSDictionary *> *)pageSections', 1)[1].split('- (NSIndexPath *)modelPath', 1)[0]
        for pair in ('@[@0,@3]', '@[@0,@7]', '@[@0,@8]', '@[@0,@9]', '@[@0,@10]', '@[@0,@11]',
                     '@[@4,@3]', '@[@4,@4]', '@[@4,@5]'):
            self.assertNotIn(pair, sections)
        source = sections.split('self.page == SRPanelPageSource', 1)[1].split('self.page == SRPanelPageGroups', 1)[0]
        self.assertNotIn('@[@3,', source)
        prefs = sections.split('self.page == SRPanelPageSettings', 1)[1]
        self.assertNotIn('@[@1,', prefs)
        self.assertNotIn('@[@3,', prefs)
        self.assertNotIn('@[@4,@2]', prefs)

    def test_group_counts_come_from_one_readable_pool_not_a_fake_zero(self):
        self.assertIn('self.groupPool ? [SRGroupPlanner poolSummaryForRows:self.groupPool draft:self.draft] : nil', PANEL)
        self.assertIn('@"群池统计暂不可读取"', PANEL)
        self.assertIn('initWithItems:@[@"目标分组", @"排除的群"]', PANEL)
        self.assertIn('self.page == SRPanelPageGroups ? @"保存分组"', PANEL)
        self.assertIn('(section == 5 && path.row == 1)', PANEL)

    def test_docking_is_explicit_and_preserved_through_phase_changes(self):
        self.assertIn('SRCapsuleDockSide(desiredX', CAPSULE)
        self.assertIn('self.unitX < 0.5 ? @"›" : @"‹"', CAPSULE)
        self.assertIn('self.docked ? 90', CAPSULE)
        show = CAPSULE.split('- (void)showModel:', 1)[1].split('- (void)updatePreviewControls', 1)[0]
        self.assertIn('if (idle || accountChanged || newRun)', show)
        self.assertNotIn('self.docked = YES', show)
        self.assertIn('self.previewCollapsed = self.docked', show)
        restore = CAPSULE.split('- (void)restoreFromDock', 1)[1].split('- (void)openPressed', 1)[0]
        for forbidden in ('self.action()', 'self.openAction()', 'self.menuAction()', 'resume', 'pause'):
            self.assertNotIn(forbidden, restore)

    def test_idle_and_activity_use_one_control_and_keep_display_preferences(self):
        install = PANEL.split('- (void)install {', 1)[1].split('\n}', 1)[0]
        self.assertNotIn('UIButton', install)
        self.assertIn('[self.button removeFromSuperview]; self.button = nil', install)
        self.assertIn('self.floatingProgress.positionChanged =', PANEL)
        self.assertIn('[weakSelf.entryPreferences setFloatingEntryPlacementUnitX:unitX unitY:unitY]', PANEL)
        self.assertIn('setInitialPositionUnitX:self.entryPreferences.floatingEntryUnitX', PANEL)

    def test_idle_uses_sync_pill_without_execution_controls(self):
        idle = CAPSULE.split('if (idle) {', 1)[1].split('return;', 1)[0]
        self.assertIn('self.countLabel.text = @"同步"', idle)
        self.assertIn('self.actionButton.hidden = YES', idle)
        self.assertNotIn('self.action()', idle)
        self.assertNotIn('self.countLabel.text = @"S"', CAPSULE)

    def test_owned_navigation_preserves_root_and_dirty_guard(self):
        navigation = (ROOT / 'UI/SRNavigationController.m').read_text(encoding='utf-8')
        for expected in ('navigation.topViewController != controller', 'stack.count < 2',
                         'stack.count - 1', 'sr_hasUnsavedChanges', 'sr_requestClose',
                         'weakSelf.topViewController == weakPage'):
            self.assertIn(expected, navigation)
        self.assertNotIn('interactivePopGestureRecognizer.enabled = NO', PANEL)
        self.assertIn('@interface SRPanel : UITableViewController <SRNavigationBackGuard>', PANEL)
        self.assertIn('SRNavigationController alloc', PANEL)

    def test_native_navigation_cases_cover_the_reported_return_failure(self):
        native = (ROOT / 'tests/ios/SRNavigationTests.m').read_text(encoding='utf-8')
        for expected in ('destination < 4', 'settings.dirty = YES', 'settings.closeRequests == 2',
                         '!SRPopPluginPage(settings, NO)', 'navigation.topViewController == home'):
            self.assertIn(expected, native)

    def test_capsule_commands_recheck_displayed_run_and_action(self):
        refresh = PANEL.split('- (void)refreshFloatingProgress {', 1)[1].split('- (void)ignorePreviewForAccount:', 1)[0]
        self.assertIn('if (!account.length) { [self.floatingProgress hide]; return; }', refresh)
        action = PANEL.split('self.floatingProgress.action = ^{', 1)[1].split('\n    };', 1)[0]
        self.assertIn('verifyAccount:account', action)
        self.assertIn('currentRunID isEqual:boundRun', action)
        self.assertIn('![live[@"action"] isEqual:boundAction]', action)
        self.assertIn('resumeRun:boundRun account:account', action)

    def test_home_reference_columns_and_typography_are_explicit(self):
        cell = SCREENS.split('@implementation SRHomeNavigationCell', 1)[1].split('@end', 1)[0]
        for expected in ('constant:14', 'constant:-14', 'constraintEqualToConstant:30', 'constant:18',
                         'systemFontOfSize:18', 'SRSettingsFont(14,', 'layer.cornerRadius = 12',
                         'self.minimumHeight.constant = hint ? 44 : 74', 'self.divider.hidden = last',
                         'self.summary.hidden = !summary.length'):
            self.assertIn(expected, cell)
        self.assertIn('UITableViewCellSeparatorStyleNone', HOME)
        self.assertIn('adjustsFontForContentSizeCategory = YES', cell)

    def test_settings_keeps_three_inset_groups_and_existing_actions(self):
        sections = PANEL.split('if (self.page == SRPanelPageSettings) return @[', 1)[1].split('];', 1)[0]
        self.assertEqual(sections.count('@"title"'), 3)
        for title in ('转发设置', '显示', '维护与关于'):
            self.assertIn(f'@"{title}"', sections)
        self.assertIn('SRPanel *panel = [[SRPanel alloc] initWithStyle:UITableViewStyleInsetGrouped]', PANEL)
        for removed in ('@[@0,@1]', '@[@0,@5]'):
            self.assertNotIn(removed, sections)

    def test_feedback_cleanup_keeps_live_values_and_unsaved_warning(self):
        footer = PANEL.split('titleForFooterInSection:(NSInteger)section {', 1)[1].split('section = SRPanelSection', 1)[0]
        self.assertIn('section == 0 && self.dirty', footer)
        self.assertIn('修改尚未保存', footer)
        self.assertIn('self.page == SRPanelPageSettings) return nil', footer)
        self.assertNotIn('保存只更新来源条件', footer)
        self.assertNotIn('持续监听尚未开放', footer)
        self.assertIn('self.page == SRPanelPageSettings && section != 2) cell.detailTextLabel.text = nil', PANEL)
        self.assertIn('self.draft[@"minimum"], self.draft[@"maximum"]', PANEL)

    def test_tertiary_pages_and_multiline_footer_share_native_style(self):
        library = (ROOT / 'UI/SRLibraryScreens.m').read_text(encoding='utf-8')
        for screen in ('SRLibraryItemScreen', 'SRMediaResourcesScreen', 'SRTargetPickerScreen'):
            self.assertIn(f'{screen} alloc] initWithStyle:UITableViewStyleInsetGrouped', library)
        style = (ROOT / 'UI/SRNativeStyle.h').read_text(encoding='utf-8')
        self.assertIn('table.sectionFooterHeight = UITableViewAutomaticDimension', style)
        self.assertNotIn('self.tableView.sectionFooterHeight = 18', PANEL)
        native = (ROOT / 'tests/ios/SRNavigationTests.m').read_text(encoding='utf-8')
        self.assertIn('CGRectGetMinY(text) >= CGRectGetMaxY(row)', native)
        self.assertIn('needed.height <= CGRectGetHeight(text)', native)

    def test_message_detail_projects_stored_content_before_forwarding(self):
        library = (ROOT / 'UI/SRLibraryScreens.m').read_text(encoding='utf-8')
        detail = library.split('@implementation SRLibraryItemScreen', 1)[1].split('@end', 1)[0]
        for text in ('消息详情', '消息内容', '本次转发', '目标分组', '预计目标', '选择分组转发', '版本与记录'):
            self.assertIn(f'@"{text}"', detail)
        self.assertIn('self.recordsOnly ? 3 : 2', detail)
        self.assertIn('return [self messageCellAtIndexPath:path]', detail)
        self.assertIn('[self.view addSubview:button]', detail)
        self.assertIn('constraintEqualToAnchor:button.topAnchor constant:-12', detail)
        prompt = detail.split('- (void)promptForward {', 1)[1].split('\n}', 1)[0]
        self.assertIn('![self verified]', prompt)
        self.assertIn('topViewController != self', prompt)
        self.assertIn('SRCreateTargetPicker', prompt)
        for forbidden in ('createLibraryTaskForAccount:', 'startLibraryTask:'):
            self.assertNotIn(forbidden, prompt)
        native = (ROOT / 'tests/ios/SRNavigationTests.m').read_text(encoding='utf-8')
        self.assertIn('store.reads == reads && button.hidden', native)
        self.assertIn('CGRectGetMaxY(table.frame) <= CGRectGetMinY(button.frame)', native)

    def test_result_close_is_bound_to_one_durable_terminal_run(self):
        close = PANEL.split('self.floatingProgress.closeResultAction =', 1)[1].split('self.floatingProgress.action =', 1)[0]
        for expected in ('verifyAccount:account', 'entry.smallGroupSession.busy',
                         'entry.displayedProgressRun isEqual:resultRun',
                         'summaryForRun:resultRun', 'live[@"account"] isEqual:account',
                         'entry.dismissedResultRun = resultRun'):
            self.assertIn(expected, close)
        for forbidden in ('cancelRun:', 'endRun:', 'finishContent:', 'resumeRun:', 'saveConfiguration:', 'startRule:'):
            self.assertNotIn(forbidden, close)
        self.assertIn('@"completed": @"本次执行结束"', CAPSULE)
        self.assertNotIn('@"本组完成"', CAPSULE)

    def test_result_record_reads_the_bound_run_and_reuses_core_counts(self):
        record = SCREENS.split('UIViewController *SRCreateRunResultRecord(', 1)[1].split('@interface', 1)[0]
        for expected in ('verifyAccount && verifyAccount()', 'summaryForRun:run',
                         'row[@"account"] isEqual:account', 'SRRunDescription(card)',
                         'SRCreateReadOnlyText(@"本次转发记录", body, verifyAccount)'):
            self.assertIn(expected, record)
        for forbidden in ('startRule:', 'resumeRun:', 'cancelRun:', 'finishContent:', 'saveConfiguration:'):
            self.assertNotIn(forbidden, record)

    def test_native_uikit_harness_is_separate_from_macos_evidence(self):
        harness = (ROOT / 'tests/ios/SRFloatingProgressTests.m').read_text(encoding='utf-8')
        for expected in ('UIApplicationMain', 'UIGestureRecognizerStateCancelled',
                         'SRVisualModel(@"idle")', 'SRVisualModel(@"running")',
                         'CGRectEqualToRect(dock, view.frame)', 'commands == 1',
                         'next[@"uiRunID"] = @"next-run"'):
            self.assertIn(expected, harness)
        self.assertNotIn('SRFloatingProgressTests.m', (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
