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
        self.assertIn('stopForReason:SRSourceTimeProbeInactive', entry)
        self.assertIn('report[@"sourceTimeProbe"] = self.sourceTimeProbe.diagnostics', panel)

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


if __name__ == '__main__':
    unittest.main()
