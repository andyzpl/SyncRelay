"""Source contracts and offline report triage; not native image or device tests."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from diagnose_report import analyze


class ImageContractTests(unittest.TestCase):
    def report(self, **receiver):
        return {'reportSchema': 1, 'storageReady': True,
                'draftSummary': {'sourceSelected': True, 'senderCount': 1, 'ruleCount': 1},
                'sourceCapture': {}, 'receiveCandidate': receiver,
                'imageSource': {'schema': 1, 'state': 'idle', 'getterABICompatible': True}}

    def test_pending_never_claims_capture_or_send(self):
        report = self.report(imageState='awaiting_native_image')
        codes = {row['code'] for row in analyze(report)}
        self.assertNotIn('image_snapshot_ready', codes)
        self.assertNotIn('preview_ready', codes)

    def test_image_timeout_and_getter_failure_are_distinct(self):
        report = self.report(counters={'image_timeout': 1})
        self.assertIn('image_timeout', {row['code'] for row in analyze(report)})
        report['imageSource']['getterABICompatible'] = False
        self.assertIn('image_getter_unavailable', {row['code'] for row in analyze(report)})
        report['receiveCandidate']['imagePreparationCode'] = 3
        self.assertIn('image_storage_quota', {row['code'] for row in analyze(report)})
        report['receiveCandidate']['imagePreparationCode'] = 8
        self.assertIn('image_raster_unsupported', {row['code'] for row in analyze(report)})

    def test_image_ready_only_means_snapshot(self):
        report = self.report(imageState='snapshot_ready')
        report['sourceCapture']['state'] = 'preview'
        findings = analyze(report)
        self.assertIn('image_snapshot_ready', {row['code'] for row in findings})
        self.assertIn('image sending is not enabled', next(row['message'] for row in findings if row['code'] == 'image_snapshot_ready'))

    def test_capture_uses_frozen_sender_and_type_filters(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        capture = panel.split('- (void)beginCapture {', 1)[1]
        self.assertIn('[self.receiver armForAccount:account configuration:snapshot error:&error]', capture)
        receiver = (ROOT / 'Adapter/SRWeChatReceiver.m').read_text(encoding='utf-8')
        incoming = receiver.split('- (void)observeSession:(id)session wrap:(id)wrap {', 1)[1]
        self.assertLess(incoming.index('allowsSender:sender type:type'), incoming.index('SRPendingImage *pending'))
        outgoing = receiver.split('- (void)observeOutgoingManager:(id)manager session:(id)session wrap:(id)wrap {', 1)[1]
        self.assertLess(outgoing.index('allowsSender:account type:type'), outgoing.index('pending.wrap = wrap'))

    def test_preview_verifies_account_and_resource_on_foreground(self):
        ui = (ROOT / 'UI/SRPlanScreens.m').read_text(encoding='utf-8')
        image = ui.split('@implementation SRSourceImageScreen', 1)[1].split('@end', 1)[0]
        self.assertIn('UIApplicationWillResignActiveNotification', image)
        self.assertIn('UIApplicationDidBecomeActiveNotification', image)
        self.assertIn('self.imageView.image = nil', image)
        self.assertLess(image.index('verified = self.verifyAccount'), image.index('dataForPayload:'))
        text_host = (ROOT / 'Adapter/SRWeChatTextSendAdapter.m').read_text(encoding='utf-8')
        self.assertIn('isEqual:@"text"', text_host)


if __name__ == '__main__':
    unittest.main()
