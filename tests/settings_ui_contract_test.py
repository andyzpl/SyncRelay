"""Source-level UI contracts only; these do not validate UIKit rendering."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SettingsUIContractTests(unittest.TestCase):
    def test_save_uses_settings_language_without_renaming_internal_events(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        self.assertIn('initWithTitle:@"\u4fdd\u5b58" style:UIBarButtonItemStyleDone', panel)
        self.assertIn('record:@"draft_saved"', panel)
        self.assertIn('record:@"draft_save_failed"', panel)
        sources = [*sorted((ROOT / 'UI').glob('*.m')), ROOT / 'Core/SRSourceCapture.m']
        for path in sources:
            literals = re.findall(r'@"(?:[^"\\]|\\.)*"', path.read_text(encoding='utf-8'))
            with self.subTest(source=path.name):
                self.assertFalse(any('\u8349\u7a3f' in literal for literal in literals))

    def test_all_plugin_navigation_modes_explicitly_use_opaque_background(self):
        style = (ROOT / 'UI/SRNativeStyle.h').read_text(encoding='utf-8')
        navigation = style.split('static inline void SRStyleSettingsNavigation(', 1)[1]
        # Enforce the override after either the copied-host or fallback appearance path.
        self.assertRegex(navigation, r'if \(!appearance\) \{[\s\S]*?\n    \}\n(?:    //[^\n]*\n)*    \[appearance configureWithOpaqueBackground\];')
        self.assertIn('[appearance configureWithOpaqueBackground];', navigation)
        self.assertIn('appearance.backgroundEffect = nil;', navigation)
        self.assertIn('appearance.backgroundImage = nil;', navigation)
        self.assertIn('appearance.backgroundColor = SRSettingsBackground();', navigation)
        self.assertIn('navigation.navigationBar.translucent = NO;', navigation)
        for mode in ('standardAppearance', 'scrollEdgeAppearance', 'compactAppearance', 'compactScrollEdgeAppearance'):
            self.assertRegex(navigation, rf'navigation\.navigationBar\.{mode} = (?:\[appearance copy\]|appearance);')
        self.assertNotIn('host.navigationBar.standardAppearance =', navigation)
        self.assertNotIn('[UINavigationBar appearance]', navigation)

    def test_single_text_idle_claim_survives_countdown_until_host_completion(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        experiment = panel.split('- (void)beginSingleTextSend {', 1)[1].split('- (UIAlertController *)textTestResult:', 1)[0]
        self.assertIn('UIApplication.sharedApplication.idleTimerDisabled = YES;', experiment)
        countdown = experiment.split('panel.textCountdown = NO;', 1)[1].split('[panel.textSendAdapter submitDelivery:', 1)[0]
        self.assertNotIn('[panel restoreTextIdleTimer]', countdown)
        self.assertIn('[panel restoreTextIdleTimer]; panel.singleTextSendEnabled = NO;', experiment)
        cancel = panel.split('- (void)cancelTextExperiment {', 1)[1].split('\n}', 1)[0]
        self.assertLess(cancel.index('self.textGeneration++'), cancel.index('[self.textSendHost stopObservation]'))
        self.assertIn('[self restoreTextIdleTimer]', cancel)
        self.assertIn('![panel.draft isEqual:configuration]', experiment)

    def test_service_preflight_precedes_countdown_and_persistent_claim(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        experiment = panel.split('- (void)beginSingleTextSend {', 1)[1].split('- (UIAlertController *)textTestResult:', 1)[0]
        self.assertLess(experiment.index('readyForAccount:account'), experiment.index('panel.textCountdown = YES'))
        countdown = experiment.split('panel.textCountdown = NO;', 1)[1]
        self.assertLess(countdown.index('readyForAccount:account'), countdown.index('claimTextExperiment:'))
        host = (ROOT / 'Adapter/SRWeChatTextSendHost.m').read_text(encoding='utf-8')
        preflight = host.split('- (BOOL)readyForAccount:', 1)[1].split('- (BOOL)matches:', 1)[0]
        self.assertIn('resolveManagerForPhase:@"preflight"', preflight)
        self.assertNotIn('SRHostCreateTextWrap(', preflight)
        self.assertNotIn('claimTextExperiment:', preflight)

    def test_grouping_defaults_to_100_and_keeps_200_advanced(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        self.assertIn('NSUInteger size = 100;', panel)
        self.assertNotIn('chosen.count <= 100 ? 100 : 200', panel)
        self.assertIn('field.text = size.unsignedIntegerValue == 100 ? @"10" : @"0";', panel)
        self.assertIn('默认 100 群/条', panel)

    def test_source_time_row_uses_compact_copy_and_accessibility_value(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        self.assertIn('cell.textLabel.text = @"来源时间采样";', panel)
        self.assertIn('cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %lu/16"', panel)
        self.assertIn('cell.accessibilityLabel = @"来源时间采样";', panel)
        self.assertIn('cell.accessibilityValue =', panel)
        self.assertNotIn('来源时间只读采样（文字/图片元数据）', panel)

    def test_storage_readiness_exports_a_json_boolean(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        # A comparison or ternary wrapped in @(...) is an Objective-C int and
        # serializes as 0/1, which the diagnostic contract rejects, so the only
        # assignment must box literal booleans.
        assignments = [line.strip() for line in panel.splitlines()
                       if 'report[@"storageReady"]' in line]
        self.assertEqual(assignments, ['report[@"storageReady"] = self.store ? @YES : @NO;'])
        self.assertNotIn('report[@"storageReady"] = @(', panel)

    def test_floating_entry_is_draggable_and_persists_placement(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        entry = panel.split('@implementation SREntry', 1)[1]
        self.assertIn('UIPanGestureRecognizer', entry)
        self.assertIn('@selector(floatingEntryDragged:)', entry)
        self.assertIn('floatingEntryAvailableBoundsInWindow:', entry)
        self.assertIn('setFloatingEntryPlacementUnitX:', entry)
        self.assertIn('button.translatesAutoresizingMaskIntoConstraints = YES;', entry)
        self.assertNotIn('button.trailingAnchor', entry)
        self.assertNotIn('button.bottomAnchor', entry)

    def test_floating_entry_persists_free_two_axis_position(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        entry = panel.split('@implementation SREntry', 1)[1]
        self.assertIn('floatingEntryUnitX', entry)
        self.assertIn('travelX', entry)
        self.assertIn('setFloatingEntryPlacementUnitX:', entry)
        self.assertNotIn('self.floatingEntryLeftEdge ?', entry)
        preferences = (ROOT / 'Core/SREntryPreferences.m').read_text(encoding='utf-8')
        self.assertIn('SRFloatingEntryUnitXKey', preferences)
        self.assertIn('setFloatingEntryPlacementUnitX:', preferences)

    def test_floating_entry_preferences_bound_and_notify_changes(self):
        header = (ROOT / 'Core/SREntryPreferences.h').read_text(encoding='utf-8')
        source = (ROOT / 'Core/SREntryPreferences.m').read_text(encoding='utf-8')
        self.assertIn('#import <CoreGraphics/CoreGraphics.h>', header)
        self.assertIn('floatingEntryPlacementSet', header)
        self.assertIn('floatingEntryUnitX', header)
        self.assertIn('setFloatingEntryPlacementUnitX:', header)
        self.assertIn('setFloatingEntryPlacementUnitY:', header)
        self.assertIn('isfinite(unitY)', source)
        self.assertIn('MAX(0, MIN(1, unitY))', source)
        self.assertIn('SREntryPreferencesChangedNotification', source)

    def test_menu_abi_probe_separates_explicit_collection_from_read_only_latest(self):
        header = (ROOT / 'Adapter/SRMenuABIProbe.h').read_text(encoding='utf-8')
        source = (ROOT / 'Adapter/SRMenuABIProbe.m').read_text(encoding='utf-8')
        self.assertIn('- (void)collect;', header)
        self.assertIn('- (nullable NSArray<NSDictionary *> *)lastSnapshot;', header)
        collect = source.split('- (void)collect {', 1)[1].split('}', 1)[0]
        self.assertIn('self.lastSnapshot = [self snapshot];', collect)
        snapshot = source.split('- (NSArray<NSDictionary *> *)snapshot {', 1)[1]
        self.assertNotIn('lastSnapshot', snapshot.split('@end', 1)[0])

    def test_menu_abi_row_is_appended_without_an_account_gate(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        self.assertIn('if (section == 0) return 11;', panel)
        self.assertIn('if (path.row == 10) [self confirmMenuABIDiagnostic];', panel)
        # "more settings" is the logical section 0; the new row is handled before
        # the account gate, so it never touches identity or storage.
        more = panel.split('if (section == 0) {', 1)[1].split('if (![self checkAccount]) return;', 1)[0]
        self.assertIn('path.row == 10', more)
        self.assertIn(u'@"\u83dc\u5355 ABI \u8bca\u65ad"', panel)

    def test_one_shared_probe_is_injected_into_both_panel_paths(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        self.assertEqual(panel.count('entry.menuABIProbe = [[SRMenuABIProbe alloc] initWithResolver:nil];'), 1)
        self.assertEqual(panel.count('panel.menuABIProbe = self.menuABIProbe;'), 2)
        self.assertIn('@property(nonatomic, strong) SRMenuABIProbe *menuABIProbe;', panel)

    def test_confirmation_checks_liveness_and_only_the_action_collects(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        confirm = panel.split('- (void)confirmMenuABIDiagnostic {', 1)[1].split('\n- (NSDictionary *)diagnosticDraft', 1)[0]
        self.assertIn('UIAlertActionStyleCancel', confirm)
        self.assertIn('UIApplicationStateActive', confirm)
        self.assertIn('panel.viewIfLoaded.window', confirm)
        self.assertIn('panel.isBeingDismissed', confirm)
        self.assertIn('panel.navigationController.topViewController != panel', confirm)
        self.assertEqual(confirm.count('[panel.menuABIProbe collect];'), 1)
        self.assertNotIn('checkAccount', confirm)
        # Nothing else in the panel may collect: no lifecycle, refresh or report path.
        self.assertEqual(panel.count('menuABIProbe collect]'), 1)
        self.assertEqual(panel.count('menuABIProbe lastSnapshot]'), 2)

    def test_diagnostic_report_reads_latest_menu_abi_without_collecting(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        report = panel.split('- (NSDictionary *)diagnosticReport {', 1)[1].split('- (void)exportDiagnosticFromController:', 1)[0]
        self.assertIn('report[@"menuABI"] = [self menuABIDiagnostic];', report)
        self.assertNotIn('collect]', report)
        self.assertNotIn('snapshot]', report)
        diagnostic = panel.split('- (NSDictionary *)menuABIDiagnostic {', 1)[1].split('\n- (void)confirmMenuABIDiagnostic', 1)[0]
        self.assertIn('lastSnapshot', diagnostic)
        self.assertIn('@"not_run"', diagnostic)
        self.assertIn('@"collected"', diagnostic)
        for word in ('compatible', 'supported', 'passed'):
            self.assertNotIn(word, diagnostic)

    def test_reused_settings_cells_clear_accessibility_before_row_branches(self):
        source = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        # Scope to the settings panel implementation and its path-based method so
        # the earlier SRPicker data source cannot satisfy these assertions.
        panel = source.split('@implementation SRPanel', 1)[1].split('@implementation SREntry', 1)[0]
        method = panel.split(
            '- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {', 1)[1]
        body = method.split('- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:', 1)[0]
        self.assertEqual(body.count('cell.accessibilityLabel = nil;'), 1)
        self.assertEqual(body.count('cell.accessibilityValue = nil;'), 1)
        self.assertLess(body.index('cell.accessibilityLabel = nil;'), body.index('if (section == 0) {'))
        self.assertLess(body.index('cell.accessibilityValue = nil;'), body.index('if (section == 0) {'))
        # Only the source-time and menu ABI rows set a custom voice afterwards.
        self.assertEqual(body.count('cell.accessibilityLabel ='), 3)
        self.assertEqual(body.count('cell.accessibilityValue ='), 3)
        self.assertIn(u'cell.accessibilityLabel = @"\u6765\u6e90\u65f6\u95f4\u91c7\u6837";', body)
        self.assertIn(u'cell.accessibilityLabel = @"\u83dc\u5355 ABI \u8bca\u65ad";', body)


if __name__ == '__main__':
    unittest.main()
