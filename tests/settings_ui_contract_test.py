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
        self.assertIn('if (section == 0) return 13;', panel)
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
        # Only the source-time, menu ABI and menu-call rows set their own voice.
        self.assertEqual(body.count('cell.accessibilityLabel ='), 4)
        self.assertEqual(body.count('cell.accessibilityValue ='), 4)
        self.assertIn(u'cell.accessibilityLabel = @"\u6765\u6e90\u65f6\u95f4\u91c7\u6837";', body)
        self.assertIn(u'cell.accessibilityLabel = @"\u83dc\u5355 ABI \u8bca\u65ad";', body)
        self.assertIn(u'cell.accessibilityLabel = @"\u83dc\u5355\u8c03\u7528\u89c2\u5bdf\uff08\u4e34\u65f6\uff09";', body)

    def test_menu_call_observation_row_shares_one_observer_and_never_self_starts(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        self.assertIn('if (section == 0) return 13;', panel)
        self.assertIn('if (path.row == 11) [self confirmMenuCallObservation];', panel)
        self.assertIn(u'@"\u83dc\u5355\u8c03\u7528\u89c2\u5bdf\uff08\u4e34\u65f6\uff09"', panel)
        # One observer, created by the entry assembly and injected into both paths.
        self.assertEqual(panel.count('entry.menuCallObserver = [[SRMenuCallObserver alloc] init];'), 1)
        self.assertEqual(panel.count('panel.menuCallObserver = self.menuCallObserver;'), 2)
        # Cell configuration never installs or starts the observer.
        cell = panel.split(
            '- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {', 1)[1]
        cell = cell.split('\n- (', 1)[0]
        self.assertNotIn('installOnMenuClass', cell)
        self.assertNotIn('beginSampling', cell)
        # The report only projects the bounded diagnostics.
        report = panel.split('- (NSDictionary *)diagnosticReport {', 1)[1]
        report = report.split('- (void)exportDiagnosticFromController:', 1)[0]
        self.assertIn('report[@"menuCallObservation"] = self.menuCallObserver.diagnostics', report)
        self.assertNotIn('installOnMenuClass', report)
        self.assertNotIn('beginSampling', report)

    def test_menu_call_observation_control_lives_in_the_entry(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        panel_body = panel.split('@implementation SRPanel', 1)[1].split('@implementation SREntry', 1)[0]
        for forbidden in ('installOnMenuClass', 'beginSamplingWithTimeout', 'scheduleMenuCallDeadline',
                          'stopForLifecycle', 'finishSessionWithToken'):
            self.assertNotIn(forbidden, panel_body, forbidden)
        self.assertEqual(panel_body.count('self.menuCallObservationAction(self, action, observer, token)'), 1)
        entry = panel.split('@implementation SREntry', 1)[1]
        for token in ('menuCallObservationActionFromPanel:', 'finishMenuCallObservationWithToken:',
                      'scheduleMenuCallDeadline:', 'NSClassFromString(@"MMMenuController")',
                      'NSClassFromString(@"MMMenuItem")',
                      'installOnMenuClass:menuClass itemClass:itemClass error:&error',
                      'beginSamplingWithTimeout:30 eventBudget:24',
                      'finishSessionForDeadlineToken:token'):
            self.assertIn(token, entry, token)
        # The deadline timer captures the entry, never the panel.
        deadline = entry.split('- (void)scheduleMenuCallDeadline:(NSUInteger)token {', 1)[1]
        deadline = deadline.split('\n- (', 1)[0]
        self.assertIn('dispatch_after', deadline)
        self.assertIn('__weak typeof(self) weakSelf = self;', deadline)
        self.assertIn('finishMenuCallObservationWithToken:token deadline:YES', deadline)
        self.assertNotIn('SRPanel *panel', deadline)
        # Background stops recording and then attempts the safe restore.
        background = entry.split('- (void)enteredBackground:', 1)[1].split('\n- (void)', 1)[0]
        self.assertIn('[self.menuCallObserver stopForLifecycle];', background)
        self.assertIn('finishMenuCallObservationWithToken:menuToken deadline:NO', background)

    def test_menu_call_observation_actions_are_fixed_at_confirmation(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        confirm = panel.split('- (void)confirmMenuCallObservation {', 1)[1].split('\n- (', 1)[0]
        # The action, the observer and its session token are captured while the
        # alert is built, not re-derived when the button is tapped.
        self.assertIn('SRMenuCallAction action = running ? SRMenuCallActionStop', confirm)
        self.assertIn('SRMenuCallActionRestore : SRMenuCallActionStart', confirm)
        self.assertIn('NSUInteger token = observer.sessionToken;', confirm)
        self.assertIn('submitMenuCallAction:action observer:observer token:token', confirm)
        entry = panel.split('@implementation SREntry', 1)[1]
        dispatch = entry.split('- (void)menuCallObservationActionFromPanel:', 1)[1].split('\n- (', 1)[0]
        self.assertIn('if (observer != self.menuCallObserver) return;', dispatch)
        # Each confirmed action reaches exactly one branch and never falls through
        # into another action.
        for case, call in (('SRMenuCallActionStart', 'beginMenuCallObservationFromPanel'),
                           ('SRMenuCallActionStop', 'finishMenuCallObservationWithToken:token'),
                           ('SRMenuCallActionRestore', 'restoreMenuCallObservationFromPanel')):
            segment = dispatch.split('case %s:' % case, 1)[1].split('break;', 1)[0]
            self.assertIn(call, segment, case)
        self.assertEqual(dispatch.count('break;'), 3)
        # A start confirmed before a session appeared is refused, not converted.
        begin = entry.split('- (void)beginMenuCallObservationFromPanel:', 1)[1].split('\n- (', 1)[0]
        self.assertIn('if (self.menuCallObserver.sampling || self.menuCallObserver.installed)', begin)
        # A stale stop only closes the confirmed session token.
        self.assertIn('finishMenuCallObservationWithToken:token deadline:NO', dispatch)
        # A stale restore never uninstalls a running session.
        restore = entry.split('- (void)restoreMenuCallObservationFromPanel:', 1)[1].split('\n- (', 1)[0]
        self.assertIn('if (observer.sampling || !observer.installed)', restore)
        # The deadline stays in the entry and matches the 30 s session.
        deadline = entry.split('- (void)scheduleMenuCallDeadline:(NSUInteger)token {', 1)[1]
        deadline = deadline.split('\n- (', 1)[0]
        self.assertIn('30 * NSEC_PER_SEC', deadline)
        self.assertNotIn('31 * NSEC_PER_SEC', panel)

    def test_menu_call_observation_stale_confirmations_never_switch_actions(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        entry = panel.split('@implementation SREntry', 1)[1]
        dispatch = entry.split('- (void)menuCallObservationActionFromPanel:', 1)[1].split('\n- (', 1)[0]
        branches = {}
        for case in ('SRMenuCallActionStart', 'SRMenuCallActionStop', 'SRMenuCallActionRestore'):
            branches[case] = dispatch.split('case %s:' % case, 1)[1].split('break;', 1)[0]
        # start never stops or restores an existing session.
        self.assertIn('beginMenuCallObservationFromPanel', branches['SRMenuCallActionStart'])
        self.assertNotIn('finishMenuCallObservationWithToken', branches['SRMenuCallActionStart'])
        self.assertNotIn('restoreMenuCallObservationFromPanel', branches['SRMenuCallActionStart'])
        # stop only closes the confirmed token; it never starts or restores.
        self.assertIn('finishMenuCallObservationWithToken:token deadline:NO', branches['SRMenuCallActionStop'])
        self.assertNotIn('beginMenuCallObservationFromPanel', branches['SRMenuCallActionStop'])
        self.assertNotIn('restoreMenuCallObservationFromPanel', branches['SRMenuCallActionStop'])
        # restore only restores; it never starts.
        self.assertIn('restoreMenuCallObservationFromPanel', branches['SRMenuCallActionRestore'])
        self.assertNotIn('beginMenuCallObservationFromPanel', branches['SRMenuCallActionRestore'])
        self.assertNotIn('finishMenuCallObservationWithToken', branches['SRMenuCallActionRestore'])
        # A session that appeared after the confirmation blocks the start branch.
        begin = entry.split('- (void)beginMenuCallObservationFromPanel:', 1)[1].split('\n- (', 1)[0]
        guard = begin.split('if (self.menuCallObserver.sampling || self.menuCallObserver.installed)', 1)[1]
        guard = guard.split('return;', 1)[0]
        self.assertNotIn('uninstall', guard)
        self.assertNotIn('stopSampling', guard)
        # An old restore never uninstalls a running session and is a no-op once
        # the interceptors are already restored.
        restore = entry.split('- (void)restoreMenuCallObservationFromPanel:', 1)[1].split('\n- (', 1)[0]
        self.assertIn('if (observer.sampling || !observer.installed)', restore)
        self.assertIn('[observer uninstall]', restore)

    def test_menu_call_observation_rejects_stale_tokens_before_any_action(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        entry = panel.split('@implementation SREntry', 1)[1]
        dispatch = entry.split('- (void)menuCallObservationActionFromPanel:', 1)[1].split('\n- (', 1)[0]
        # The token guard sits after the identity check and before the switch.
        self.assertLess(dispatch.index('if (observer != self.menuCallObserver) return;'),
                        dispatch.index('if (token != observer.sessionToken)'))
        self.assertLess(dispatch.index('if (token != observer.sessionToken)'),
                        dispatch.index('switch (action)'))
        guard = dispatch.split('if (token != observer.sessionToken)', 1)[1].split('switch (action)', 1)[0]
        # Refusal only refreshes and returns: no side effect of any action.
        for forbidden in ('installOnMenuClass', 'beginSampling', 'stopSampling',
                          'uninstall', 'finishMenuCallObservation', 'restoreMenuCallObservation',
                          'beginMenuCallObservation'):
            self.assertNotIn(forbidden, guard, forbidden)
        self.assertIn('return;', guard)
        # Equality (not "token > 0") is what admits the first 0 == 0 start and a
        # stopped-but-not-replaced session's own stop/restore.
        self.assertIn('if (token != observer.sessionToken)', dispatch)
        self.assertNotIn('token == 0', dispatch)
        self.assertNotIn('token > 0', dispatch)
        # The guard is token-based, so a newer session that already stopped but
        # still holds the interceptors also rejects an old restore intent.
        self.assertNotIn('sampling', guard)
        # The three fixed branches are still isolated behind the guard.
        for case in ('SRMenuCallActionStart', 'SRMenuCallActionStop', 'SRMenuCallActionRestore'):
            self.assertIn('case %s:' % case, dispatch, case)
        self.assertEqual(dispatch.count('break;'), 3)

    def test_menu_call_observation_restore_path_and_safe_start_failure(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        entry = panel.split('@implementation SREntry', 1)[1]
        restore = entry.split('- (void)restoreMenuCallObservationFromPanel:', 1)[1].split('\n- (', 1)[0]
        self.assertIn('observer != self.menuCallObserver', restore)
        self.assertIn('[observer uninstall]', restore)
        self.assertIn(u'\u62e6\u622a\u5c1a\u672a\u6062\u590d', restore)
        begin = entry.split('- (void)beginMenuCallObservationFromPanel:', 1)[1]
        begin = begin.split('\n- (void)finishMenuCallObservationWithToken', 1)[0]
        # A failed begin only cleans an idle installation of ours.
        self.assertIn('if (!self.menuCallObserver.sampling) [self.menuCallObserver uninstall];', begin)
        self.assertIn('menuCallPanelIsCurrent', begin)

    def test_menu_observation_and_other_work_are_mutually_exclusive(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        allowed = panel.split('- (BOOL)menuCallObservationAllowed {', 1)[1]
        allowed = allowed.split('\n- (', 1)[0]
        for token in ('sourceTimeProbe.active', 'smallGroupSession.busy', 'textCountdown',
                      'imageCountdown', 'singleTextSendEnabled', 'singleImageSendEnabled',
                      'sendProbe.diagnostics', 'capture.status'):
            self.assertIn(token, allowed, token)
        for method in ('- (void)beginCapture {', '- (void)toggleSourceTimeProbe {',
                       '- (void)beginSendProbe {', '- (BOOL)allowLegacyExperiment {'):
            body = panel.split(method, 1)[1].split('\n- (', 1)[0]
            self.assertIn('menuCallObservationActive', body, method)
        self.assertGreaterEqual(panel.count('!panel.menuCallObservationActive'), 1)
        self.assertGreaterEqual(panel.count('!entry.menuCallObservationActive'), 3)

    def test_library_menu_entry_reads_back_through_the_verified_service(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        entry = panel.split('void SRInstallPanelEntry', 1)[1]
        for token in ('configureReadbackProvider:', 'configureEpochProvider:',
                      'NSClassFromString(@"MMContext")', 'NSClassFromString(@"CMessageMgr")',
                      '@"currentContext"', '@"getService:"'):
            self.assertIn(token, entry, token)

    def test_library_menu_entry_has_an_explicit_opt_in_switch(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        self.assertIn('if (path.row == 12) {', panel)
        self.assertIn(u'@"\u83dc\u5355\u5165\u5e93\uff08\u957f\u6309\u6587\u5b57\uff09"', panel)
        self.assertIn('UISwitch *toggle = [[UISwitch alloc] init];', panel)
        self.assertIn('[toggle addTarget:self action:@selector(libraryMenuEntryToggled:)', panel)
        self.assertIn('self.entryPreferences.libraryMenuEntryEnabled = toggle.isOn;', panel)
        # Off by default and independent of the temporary observer session.
        self.assertNotIn('libraryMenuEntryEnabled = YES', panel)

    def test_library_menu_entry_is_wired_independently_of_the_call_observer(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        self.assertIn('#import "Core/SRLibraryIntake.h"', panel)
        entry = panel.split('void SRInstallPanelEntry', 1)[1]
        for token in ('SRMessageMenuHook alloc', 'initWithIntake:[SRLibraryIntake intakeForStore:store]',
                      'SRMenuBuildHook alloc', '[entry.libraryMenuBuildHook install:NULL]',
                      'NSClassFromString(@"MMMenuController")',
                      'NSClassFromString(@"MMRichTextCoverView")',
                      'NSClassFromString(@"TextMessageCellView")',
                      'NSClassFromString(@"MMMenuItem")'):
            self.assertIn(token, entry, token)
        # The library switch and the temporary observer stay separate objects.
        self.assertIn('@property(nonatomic, strong) SRMessageMenuHook *libraryMenuHook;', panel)
        self.assertIn('@property(nonatomic, strong) SRMenuBuildHook *libraryMenuBuildHook;', panel)
        self.assertNotIn('menuCallObserver = entry.libraryMenuHook', panel)

    def test_menu_call_observation_does_not_touch_the_intake_hook(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        # The library menu hook is a separate capability. The temporary observer
        # wiring must not construct it or share its state.
        observer = panel.split('- (void)menuCallObservationActionFromPanel:', 1)[1]
        observer = observer.split('\n- (', 1)[0]
        self.assertNotIn('initWithIntake:', observer)
        self.assertNotIn('libraryMenuHook', observer)
        self.assertNotIn('libraryMenuEntryEnabled = YES', panel)
        self.assertNotIn('MSHookMessageEx', panel)


if __name__ == '__main__':
    unittest.main()
