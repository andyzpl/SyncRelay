"""No-send source contracts and report triage, not device compatibility tests."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from diagnose_report import analyze


class ImageSendContractTests(unittest.TestCase):
    def report(self, **overrides):
        section = dict(schema=1, state='contract_compatible_not_sent', constructorInvoked=True,
                       extensionGetterInvoked=True, wrapFieldsCompatible=True, longSelectorCompatible=True,
                       originSelectorCompatible=False, imageSetterInvoked=False, serviceResolved=False,
                       submissionAttempted=False, sendingEnabled=False)
        section.update(overrides)
        return dict(reportSchema=1, storageReady=True, imageSendPreparation=section)

    def codes(self, **overrides):
        return {row['code'] for row in analyze(self.report(**overrides))}

    def test_compatible_is_not_image_send(self):
        findings = analyze(self.report())
        item = next(row for row in findings if row['code'] == 'image_send_contract_compatible')
        self.assertIn('No image setter or send ran', item['message'])

    def test_scope_flags_cannot_be_missing_or_numeric(self):
        for key in ('imageSetterInvoked', 'serviceResolved', 'submissionAttempted', 'sendingEnabled'):
            for value in (True, None, 0, 'false'):
                self.assertIn('image_send_contract_scope_invalid', self.codes(**{key: value}))

    def test_compatibility_needs_constructor_extension_and_fields(self):
        for key in ('constructorInvoked', 'extensionGetterInvoked', 'wrapFieldsCompatible'):
            self.assertIn('image_send_contract_incomplete', self.codes(**{key: False}))
        self.assertIn('image_send_contract_incomplete', self.codes(longSelectorCompatible=False))

    def test_missing_getter_is_not_guessed_via_kvc(self):
        self.assertIn('image_extension_getter_missing', self.codes(state='extension_getter_unavailable'))
        source = (ROOT / 'Adapter/SRWeChatImageSendProbe.m').read_text(encoding='utf-8')
        for forbidden in ('valueForKey:', 'object_getIvar', 'AddMsg:', 'getService:', 'SRReadObject('):
            self.assertNotIn(forbidden, source)
        self.assertIn('class_getInstanceMethod', source)

    def test_button_is_separate_from_text_budget_and_store(self):
        source = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        action = source.split('- (void)inspectImageSendContract {', 1)[1].split('- (UIAlertController *)textTestResult:', 1)[0]
        self.assertIn('inspectForAccount:account', action)
        self.assertIn('self.ownsIdleTimer', action)
        for forbidden in ('claimTextExperiment:', 'submitDelivery:', 'submitRequest:', 'createPlan', 'readyForAccount:'):
            self.assertNotIn(forbidden, action)
        self.assertIn('report[@"imageSendPreparation"]', source)

    def test_wrong_schema_never_claims_compatible(self):
        for schema in (True, 2, '1'):
            self.assertIn('image_send_contract_schema_invalid', self.codes(schema=schema))


if __name__ == '__main__':
    unittest.main()
