"""Image experiment source/triage regressions, not UIKit or device tests."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from diagnose_report import analyze


class ImageExperimentContractTests(unittest.TestCase):
    def codes(self, **section):
        candidate = dict(schema=1, batchSendingEnabled=False, submissionAttempted=False,
                         imageSetterInvoked=False, deliveryOutcome='not_submitted')
        candidate.update(section)
        return {item['code'] for item in analyze(dict(reportSchema=1, storageReady=True,
                                                     singleImageSendCandidate=candidate))}

    def test_service_contract_parity_does_not_modify_text_host(self):
        text = (ROOT / 'Adapter/SRWeChatTextSendHost.m').read_text()
        image = (ROOT / 'Adapter/SRWeChatImageSendHost.m').read_text()
        for start, end in [('static const char *SRHostType', 'static char SRHostInitializerType'),
                           ('- (BOOL)validateManager:', '- (BOOL)readyForAccount:')]:
            self.assertEqual(text.split(start, 1)[1].split(end, 1)[0],
                             image.split(start, 1)[1].split(end, 1)[0])

    def test_setter_side_effects_do_not_claim_submission(self):
        codes = self.codes(imageSetterInvoked=True, state='blocked')
        self.assertTrue({'image_setter_invoked', 'image_not_submitted', 'image_experiment_blocked'} <= codes)
        self.assertNotIn('image_host_invoked', codes)

    def test_submission_never_claims_delivery(self):
        codes = self.codes(imageSetterInvoked=True, submissionAttempted=True, deliveryOutcome='confirmed',
                           serverIDPresent=True, imageContentVerified=True)
        self.assertTrue({'image_host_invoked', 'image_delivery_uncertain', 'image_delivery_outcome_invalid'} <= codes)

    def test_malformed_sections_and_private_fields_not_echoed(self):
        for key in ('submissionAttempted', 'imageSetterInvoked'):
            self.assertIn('invalid_image_candidate', self.codes(**{key: 'false'}))
        report = dict(reportSchema=1, storageReady=True, singleImageSendCandidate='private body',
                      singleImageExperimentHistory='wxid_secret')
        findings = analyze(report)
        self.assertTrue({'invalid_image_candidate', 'invalid_image_history'} <= {r['code'] for r in findings})
        self.assertNotIn('private body', str(findings))
        self.assertNotIn('wxid_secret', str(findings))

    def test_idle_interface_check_does_not_request_receive_samples(self):
        report = dict(reportSchema=1, storageReady=True, receiveCandidate=dict(armed=False,
                      directionEvidenceSchema=2, directionSamples=[], counters={}))
        self.assertNotIn('direction_details_missing', {row['code'] for row in analyze(report)})

    def test_ui_claims_before_image_write_and_keeps_single_target(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        action = panel.split('- (void)beginSingleImageSend {', 1)[1].split('- (void)beginSingleTextSend {', 1)[0]
        self.assertLess(action.index('claimImageExperiment:'), action.index('submitRequest:request'))
        for required in ('multiple:NO', 'SRPacingConfigure', 'SRPacingResume', 'SRPacingReady',
                         'self.textSendHost.diagnostics', 'panel.ownsIdleTimer = YES',
                         'panel.capture.preview isEqual:source', 'currentGroups', 'cancelImageExperiment'):
            self.assertIn(required, action)
        self.assertNotIn('startRule:', action)
        self.assertNotIn('submitDelivery:', action)

    def test_material_is_scoped_static_and_not_a_host_path(self):
        source = (ROOT / 'Adapter/SRWeChatImageMaterial.m').read_text()
        for required in ('validPayload:', 'dataForPayload:', 'source:source', 'UIImageJPEGRepresentation',
                         'UIImageOrientationUp', '16000000ULL', '8192'):
            self.assertIn(required, source)
        for forbidden in ('contentsOfFile:', 'URLWithString:', 'valueForKey:', 'object_getIvar'):
            self.assertNotIn(forbidden, source)

    def test_preflight_precedes_idle_claim_and_does_not_require_it(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        action = panel.split('- (void)beginSingleImageSend {', 1)[1].split('- (void)beginSingleTextSend {', 1)[0]
        self.assertLess(action.index('readyForAccount:account'), action.index('panel.ownsIdleTimer = YES'))
        environment = panel.split('self.imageSendHost = [[SRWeChatImageSendHost alloc]', 1)[1].split('materialLoader:', 1)[0]
        self.assertIn('panel.singleImageSendEnabled', environment)
        self.assertNotIn('panel.ownsIdleTimer', environment)


if __name__ == '__main__':
    unittest.main()
