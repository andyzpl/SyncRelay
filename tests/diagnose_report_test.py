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

    def direction(self, before=None, after=None):
        report = self.base()
        report['receiveCandidate'].update(directionEvidenceSchema=1,
            counters={'outgoing_callback': 1, 'outgoing_wrong_direction': 1},
            directionSamples=[{'path': 'outgoing', 'before': before or {}, 'after': after or {}}])
        return report

    def test_old_report_requires_details_not_filter_bypass(self):
        report = self.base()
        report['receiveCandidate']['counters'] = {'receive_callback': 1, 'receive_wrong_direction': 1}
        self.assertIn('direction_details_required', self.codes(report))
        report['receiveCandidate'].update(directionEvidenceSchema=2, directionSamples=[])
        self.assertIn('direction_details_required', self.codes(report))

    def test_pre_post_and_endpoint_relations(self):
        report = self.direction({'fromIsAccount': True}, {'fromIsAccount': False, 'toIsAccount': False,
            'fromState': 7, 'toState': 7, 'fromEqualsTo': True})
        self.assertTrue({'direction_relationships_changed', 'direction_same_endpoint',
            'direction_account_unmatched', 'outgoing_direction_mismatch'} <= self.codes(report))

    def test_getter_failure_and_empty_are_distinct(self):
        self.assertIn('direction_getter_failed', self.codes(self.direction(after={'fromState': 2})))
        self.assertNotIn('direction_account_unmatched', self.codes(self.direction(after={'fromState': 2})))
        self.assertIn('direction_endpoint_empty', self.codes(self.direction(after={'fromState': 4})))
        self.assertIn('direction_unexpected_wrap', self.codes(self.direction(after={'wrapClassCode': 3})))

    def test_malformed_samples_and_private_fields_are_not_echoed(self):
        report = self.direction(after={'fromState': 'wxid_secret', 'body': 'private message'})
        report['receiveCandidate']['directionSamples'].extend(['private message', {'path': 'secret'}])
        self.assertNotIn('secret', str(analyze(report)))
        self.assertNotIn('private message', str(analyze(report)))
        report['receiveCandidate']['directionSamples'] = []
        self.assertIn('direction_details_missing', self.codes(report))


if __name__ == '__main__':
    unittest.main()
