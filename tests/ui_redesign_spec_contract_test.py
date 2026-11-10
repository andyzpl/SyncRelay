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
        self.assertIn('page == SRPanelPageSettings ? UITableViewStyleInsetGrouped', PANEL)
        for removed in ('@[@0,@1]', '@[@0,@5]'):
            self.assertNotIn(removed, sections)

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
