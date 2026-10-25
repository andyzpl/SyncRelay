"""Source guards only. Native execution and real-host semantics are separate gates."""
from pathlib import Path
import shlex
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SourceTimeProbeContracts(unittest.TestCase):
    def test_probe_has_no_send_store_or_competing_hook(self):
        source = (ROOT / 'Adapter/SRSourceTimeProbe.m').read_text(encoding='utf-8')
        for forbidden in ('SRStore', 'SRSourceCapture', 'SRRunner', 'submitRequest:',
                          'offerEnvelope:', 'createPlan', 'claimNext', 'saveData:',
                          'imp_implementationWithBlock', 'method_setImplementation',
                          'class_addMethod', 'm_nsContent', '@"payload"'):
            self.assertNotIn(forbidden, source)
        self.assertIn('receiver.receivedWithTimeEvidence =', source)
        self.assertIn('self.legacyReceived(message)', source)
        self.assertIn('textOnly[@"types"] = @[@"text"]', source)
        self.assertIn('newMessagesOnly:NO', source)

    def test_receiver_can_observe_early_image_metadata_without_preparation(self):
        source = (ROOT / 'Adapter/SRWeChatReceiver.m').read_text(encoding='utf-8')
        observe = source.split('- (void)observeSession:(id)session wrap:(id)wrap timeEvidence:(NSDictionary *)evidence {',
                               1)[1].split('- (void)observeMessageType:', 1)[0]
        early = observe.index('if (![self allowsSender:sender type:type]) return;')
        image_branch = observe.index('if ([type isEqual:@3]) {')
        self.assertLess(early, image_branch)
        self.assertNotIn('probeHookType', observe)

    def test_evidence_is_bounded_unverified_and_explicitly_partial(self):
        source = (ROOT / 'Adapter/SRSourceTimeProbe.m').read_text(encoding='utf-8')
        self.assertIn('SRSampleLimit = 16', source)
        self.assertIn('SRDurationLimit = 120', source)
        for key in ('sourceTimeSemanticsVerified', 'imageReadinessObserved', 'sendingEnabled'):
            self.assertIn(f'@"{key}": @NO', source)
        self.assertIn('@"receivedAt": evidence[@"receivedAt"]', source)
        self.assertIn('@"listeningSince": evidence[@"listeningSince"]', source)
        self.assertIn('@"getterDeclarationScope": @"configured_wrap_class"', source)
        self.assertIn('@"actualWrapABIObserved": @(self.hookSamples.count > 0)', source)
        self.assertIn('@"hookSamples": [self.hookSamples copy]', source)

    def test_supplemental_hook_is_bounded_metadata_not_media_preparation(self):
        source = (ROOT / 'Adapter/SRWeChatReceiver.m').read_text(encoding='utf-8')
        begin = source.split('- (NSDictionary *)beginTimeHookForSession:', 1)[1].split('- (BOOL)acceptsTimeEvidence:', 1)[0]
        for forbidden in ('m_nsContent', 'prepareImage', 'pollImage', 'SRStore', 'AddMsg:', 'GetMsg:'):
            self.assertNotIn(forbidden, begin)
        for required in ('!self.observeTimeHook', 'reserved >= 16', 'object_getClass(wrap)',
                         'receiver.generation', 'receiver.currentAccount()', 'dispatch_get_main_queue()'):
            self.assertIn(required, begin)
        probe = (ROOT / 'Adapter/SRSourceTimeProbe.m').read_text(encoding='utf-8')
        self.assertIn('self.receiver.observeTimeHook = nil;', probe)
        raw = probe.split('- (void)receiveTimeHook:', 1)[1].split('- (NSDictionary *)diagnostics', 1)[0]
        self.assertIn('self.round != round', raw)
        self.assertNotIn('@"serverID":', raw)
        self.assertNotIn('@"localID":', raw)
        self.assertNotIn('@"correlationLocalID":', raw)

    def test_local_id_correlation_is_exact_in_memory_and_never_exported(self):
        receiver = (ROOT / 'Adapter/SRWeChatReceiver.m').read_text(encoding='utf-8')
        readback = receiver.split('- (void)pollOutgoing:', 1)[1].split('- (BOOL)imageWrap:', 1)[0]
        self.assertIn('correlated[@"correlationLocalID"] = pending.localID;', readback)
        self.assertIn('self.counters[@"time_hook_reserved"]', readback)
        self.assertLess(readback.index('ownWrap:stored matchesPending:'),
                        readback.index('correlated[@"correlationLocalID"]'))
        self.assertLess(readback.index('acceptsTimeEvidence:pending.timeEvidence'),
                        readback.index('correlated[@"correlationLocalID"]'))
        probe = (ROOT / 'Adapter/SRSourceTimeProbe.m').read_text(encoding='utf-8')
        consumer = probe.split('- (void)receiveMessage:', 1)[1].split('- (void)receiveTimeHook:', 1)[0]
        self.assertIn('@"hookMessageOrdinal":', consumer)
        diagnostics = probe.split('- (NSDictionary *)diagnostics', 1)[1]
        for key in ('localID', 'serverID', 'correlationLocalID'):
            self.assertNotIn(f'@"{key}":', diagnostics)
        self.assertNotIn('correlatedLocalIDs', diagnostics)

    def test_sampling_is_entry_owned_and_gates_production_dispatch(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        entry = panel.split('@implementation SREntry', 1)[1]
        self.assertEqual(1, entry.count('[[SRWeChatReceiver alloc]'))
        self.assertIn('initWithReceiver:self.receiver', entry)
        self.assertIn('panel.sourceTimeProbe = self.sourceTimeProbe', entry)
        tick = entry.split('- (void)updateSmallGroupState {', 1)[1].split('- (void)refreshFloatingProgress', 1)[0]
        self.assertLess(tick.index('[self.sourceTimeProbe tick]'), tick.index('[self.smallGroupSession tick]'))
        for start, end in (('self.textSendHost =', 'self.imageSendHost ='),
                           ('self.imageSendHost =', 'self.imageSendProbe ='),
                           ('self.imageSendProbe =', 'self.smallGroupSession ='),
                           ('self.smallGroupSession =', 'self.smallGroupTimer =')):
            block = entry.split(start, 1)[1].split(end, 1)[0]
            self.assertIn('!entry.sourceTimeProbe.active', block)
        probe_setup = entry.split('self.sourceTimeProbe = [[SRSourceTimeProbe', 1)[1].split('self.receiver.prepareImage', 1)[0]
        self.assertIn('UIApplicationStateBackground', probe_setup)
        self.assertNotIn('applicationState == UIApplicationStateActive', probe_setup)
        active_branch = probe_setup.split('if (entry.sourceTimeProbe.active)', 1)[1].split('SRPanel *panel', 1)[0]
        self.assertNotIn('panelIdle', active_branch)
        self.assertIn('if (!entry || UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return NO;', probe_setup)
        resigning = entry.split('- (void)resigningActive:', 1)[1].split('- (void)enteredBackground:', 1)[0]
        background = entry.split('- (void)enteredBackground:', 1)[1].split('@end', 1)[0]
        self.assertIn('noteApplicationInactive', resigning)
        self.assertNotIn('stopForReason:SRSourceTimeProbeInactive', resigning)
        self.assertIn('stopForReason:SRSourceTimeProbeInactive', background)
        self.assertIn('UIApplicationDidEnterBackgroundNotification', panel)
        self.assertIn('report[@"sourceTimeProbe"] = self.sourceTimeProbe.diagnostics', panel)
        became_active = entry.split('- (void)becameActive:', 1)[1].split('- (void)resigningActive:', 1)[0]
        self.assertIn('noteApplicationActive', became_active)
        self.assertIn('selector:@selector(becameActive:)', entry)

    def test_diagnostic_entry_preserves_manual_capture_and_lifecycle(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        for start, end in (('- (void)beginCapture {', '- (void)toggleSourceTimeProbe'),
                           ('- (void)beginSendProbe {', '- (BOOL (^)(void))planVerifier'),
                           ('- (void)inspectImageSendContract {', '- (UIAlertController *)textTestResult')):
            block = panel.split(start, 1)[1].split(end, 1)[0]
            self.assertGreaterEqual(block.count('sourceTimeProbe.active'), 2)
        self.assertIn('stopForReason:SRSourceTimeProbeConfigurationChanged', panel)
        self.assertIn('stopForReason:SRSourceTimeProbeAccountInvalidated', panel)
        close = panel.split('- (void)close {', 1)[1].split('- (void)save {', 1)[0]
        self.assertNotIn('sourceTimeProbe', close)
        self.assertIn('if (path.row == 9) [self toggleSourceTimeProbe]', panel)

    def test_probe_is_in_production_syntax_and_repeated_native_manifests(self):
        self.assertIn('Adapter/SRSourceTimeProbe.m', (ROOT / 'Makefile').read_text(encoding='utf-8'))
        syntax = (ROOT / 'tools/syntax_check.py').read_text(encoding='utf-8')
        for path in ('Adapter/SRSourceTimeProbe.m', 'tests/source_time_probe_test.m'):
            self.assertIn(path, syntax)
        workflow = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')
        commands = [shlex.split(line.strip()) for line in workflow.splitlines() if line.strip().startswith('clang ')]
        commands = [command for command in commands if 'tests/source_time_probe_test.m' in command]
        self.assertEqual(1, len(commands))
        self.assertTrue({'Adapter/SRSourceTimeProbe.m', 'Adapter/SRWeChatReceiver.m',
                         'Adapter/SRRuntime.m', 'Core/SROperationsState.c'} <= set(commands[0]))
        self.assertIn('for pass in 1 2 3; do', workflow)
        self.assertIn('            "$RUNNER_TEMP/source-time-probe-test"', workflow)

    def test_consumer_round_cannot_change_during_context_revalidation(self):
        source = (ROOT / 'Adapter/SRSourceTimeProbe.m').read_text(encoding='utf-8')
        receive = source.split('- (void)receiveMessage:', 1)[1].split('- (NSDictionary *)diagnostics', 1)[0]
        self.assertIn('NSUInteger round = self.round;', receive)
        self.assertGreaterEqual(receive.count('self.round != round'), 2)
        tick = source.split('- (void)tick {', 1)[1].split('- (void)receiveMessage:', 1)[0]
        self.assertGreaterEqual(tick.count('self.round != round'), 3)

    def test_activation_rechecks_inactive_grace_before_clearing_it(self):
        source = (ROOT / 'Adapter/SRSourceTimeProbe.m').read_text(encoding='utf-8')
        active = source.split('- (void)noteApplicationActive {', 1)[1].split('- (void)tick {', 1)[0]
        self.assertIn('now - inactiveSince >= SRInactiveGraceLimit', active)
        self.assertIn('stopForReason:SRSourceTimeProbeInactive', active)
        self.assertLess(active.index('SRInactiveGraceLimit'), active.index('self.inactivePending = NO'))
        self.assertIn('self.resumedAfterInactive = YES', active)
        self.assertLess(active.index('SRInactiveGraceLimit'), active.index('self.resumedAfterInactive = YES'))
        diagnostics = source.split('- (NSDictionary *)diagnostics {', 1)[1].split('@end', 1)[0]
        self.assertIn('@"resumedAfterInactive": @(self.resumedAfterInactive)', diagnostics)
        native = (ROOT / 'tests/source_time_probe_test.m').read_text(encoding='utf-8')
        self.assertIn('static void checkInactiveGrace(void)', native)
        grace = native.split('static void checkInactiveGrace(void) {', 1)[1].split('static void checkCapabilityAndFaults', 1)[0]
        self.assertIn('CHECK([fixture.probe.diagnostics[@"resumedAfterInactive"] boolValue]);', grace)
        self.assertIn('CHECK(![fixture.probe.diagnostics[@"resumedAfterInactive"] boolValue]);', grace)
        main = native.split('int main(void)', 1)[1]
        self.assertIn('checkBoundsAndInvalidation();', main)
        self.assertLess(main.index('checkBoundsAndInvalidation();'),
                        main.index('checkInactiveGrace();'))
        self.assertLess(main.index('checkInactiveGrace();'),
                        main.index('checkCapabilityAndFaults();'))

    def test_bounded_native_wait_blocks_return_the_declared_boolean_type(self):
        native = (ROOT / 'tests/source_time_probe_test.m').read_text(encoding='utf-8')
        self.assertIn('static BOOL waitForCondition(NSTimeInterval timeout, BOOL (^condition)(void))', native)
        calls = native.split('waitForCondition(5, ^{')[1:]
        self.assertEqual(4, len(calls))
        for call in calls:
            self.assertTrue(call.startswith(' return (BOOL)('))

    def test_inactive_clock_results_recheck_round_and_interval_before_mutation(self):
        source = (ROOT / 'Adapter/SRSourceTimeProbe.m').read_text(encoding='utf-8')
        for start, end, active in (
                ('- (void)noteApplicationInactive {', '- (void)noteApplicationActive {', '!self.active'),
                ('- (void)noteApplicationActive {', '- (void)tick {', '!self.listening'),
                ('- (void)tick {', '- (void)receiveMessage:', '!self.listening')):
            with self.subTest(method=start):
                method = source.split(start, 1)[1].split(end, 1)[0]
                clock = method.index('now = self.monotonicClock()')
                self.assertIn('self.inactiveGeneration != inactiveGeneration', method[clock:])
                guard = method.index('self.inactiveGeneration != inactiveGeneration', clock)
                self.assertLess(guard, method.index('!isfinite(now)', clock))
                self.assertIn('NSUInteger inactiveGeneration = self.inactiveGeneration;', method[:clock])
                self.assertIn('self.round != round', method[clock:guard])
                self.assertIn(active, method[clock:guard])

    def test_inactive_interval_identity_changes_on_stop_resume_and_new_inactive(self):
        source = (ROOT / 'Adapter/SRSourceTimeProbe.m').read_text(encoding='utf-8')
        for start, end in (
                ('- (void)stopWithState:', '- (void)stopForReason:'),
                ('- (void)noteApplicationInactive {', '- (void)noteApplicationActive {'),
                ('- (void)noteApplicationActive {', '- (void)tick {')):
            with self.subTest(method=start):
                method = source.split(start, 1)[1].split(end, 1)[0]
                self.assertEqual(1, method.count('self.inactiveGeneration++;'))
        diagnostics = source.split('- (NSDictionary *)diagnostics {', 1)[1]
        self.assertNotIn('inactiveGeneration', diagnostics)

    def test_native_clock_reentry_regressions_are_called(self):
        native = (ROOT / 'tests/source_time_probe_test.m').read_text(encoding='utf-8')
        main = native.split('int main(void)', 1)[1]
        for name in ('checkInactiveClockReentry', 'checkInactiveClockResume', 'checkInactiveIntervalReplacement'):
            self.assertIn(f'static void {name}(void)', native)
            self.assertEqual(1, main.count(f'{name}();'))
        reentry = native.split('static void checkInactiveClockReentry(void) {', 1)[1].split('static void checkInactiveClockResume', 1)[0]
        for required in ('entry < 3', 'restart < 2', 'outcome < 3', 'onMonotonicRead = nil',
                         'receiverGeneration', 'fixture.receiver.observeTimeHook', 'fixture.changes == changes + 1 + restart'):
            self.assertIn(required, reentry)


if __name__ == '__main__':
    unittest.main()
