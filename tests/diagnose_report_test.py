import unittest
from tools.diagnose_report import analyze


class ReportTests(unittest.TestCase):
    def base(self):
        return {'reportSchema': 1, 'storageReady': True,
                'draftSummary': {'sourceSelected': True, 'senderCount': 1, 'ruleCount': 1, 'dirty': False},
                'receiveCandidate': {'armed': True, 'counters': {}}, 'sourceCapture': {'state': 'waiting'}}

    def codes(self, report):
        return {item['code'] for item in analyze(report)}

    def test_missing_after_source_change(self):
        report = self.base()
        report['draftSummary'].update(senderCount=0, ruleCount=0, dirty=True)
        self.assertTrue({'missing_senders', 'missing_rules', 'unsaved_draft'} <= self.codes(report))

    def test_no_hook_is_not_proof_of_failure(self):
        self.assertIn('no_callback_observed', self.codes(self.base()))

    def test_filter_and_id_reasons(self):
        report = self.base()
        report['receiveCandidate']['counters'] = {'receive_callback': 1, 'receive_no_server_id': 1, 'own_timeout': 1}
        report['sourceCapture']['lastReasonCode'] = 22
        self.assertTrue({'missing_server_id', 'own_timeout', 'sender_not_selected'} <= self.codes(report))

    def test_unknown_and_malformed_schema(self):
        self.assertEqual(self.codes({'reportSchema': 2}), {'unsupported_schema'})
        report = self.base(); report['sourceCapture'] = 'private content'
        self.assertEqual(self.codes(report), {'invalid_report'})

    def test_no_private_fields_echoed(self):
        report = self.base(); report['private'] = 'wxid_secret secret@chatroom body'
        self.assertNotIn('secret', str(analyze(report)))


if __name__ == '__main__':
    unittest.main()
