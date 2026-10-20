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
        report['receiveCandidate'].update(directionEvidenceSchema=99, directionSamples=[])
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

    def test_phone_style_signature_failure_is_not_id_mismatch(self):
        report = self.direction(after={'fromState': 2, 'toState': 2, 'senderState': 2,
            'wrapClassCode': 1, 'messageType': 1, 'fromIsAccount': False, 'toIsAccount': False})
        self.assertIn('direction_instance_signature_rejected', self.codes(report))
        self.assertNotIn('direction_account_unmatched', self.codes(report))

    def test_runtime_recovery_schema_and_preview(self):
        report = self.direction(after={'fromState': 7, 'toState': 7, 'fromInstanceSignatureState': 2,
            'fromIsAccount': True, 'toIsSource': True})
        report['receiveCandidate'].update(directionEvidenceSchema=2, counters={'outgoing_callback': 1})
        report['sourceCapture']['state'] = 'preview'
        self.assertTrue({'declared_string_read_recovered', 'preview_ready'} <= self.codes(report))
        self.assertNotIn('direction_getter_failed', self.codes(report))

    def test_integer_boolean_flags(self):
        report = self.direction(after={'fromState': 7, 'toState': 7, 'fromEqualsTo': 1,
            'fromIsAccount': 0, 'toIsAccount': 0})
        self.assertTrue({'direction_same_endpoint', 'direction_account_unmatched'} <= self.codes(report))
        report['receiveCandidate']['directionSamples'][0]['after']['fromEqualsTo'] = '1'
        self.assertNotIn('direction_same_endpoint', self.codes(report))

    def test_manual_observation_reports_progress_without_claiming_delivery(self):
        report = self.base()
        report['manualSendObservation'] = {
            'observerOnly': True, 'sendingEnabled': False,
            'state': 'stopped', 'observedOutgoing': 1,
            'lookupMisses': 0, 'identityConflicts': 0,
            'droppedSamplesOrCallbacks': 0,
            'deliveryOutcome': 'not_determined',
            'samples': [
                {'source': 'after_add', 'localIDPresent': True,
                 'serverIDPresent': False, 'statusCode': 1},
                {'source': 'local_readback', 'localIDPresent': True,
                 'serverIDPresent': False, 'statusCode': 1},
                {'source': 'local_readback', 'localIDPresent': True,
                 'serverIDPresent': True, 'statusCode': 2},
            ],
        }
        self.assertTrue({'manual_outgoing_observed', 'manual_local_readback',
            'manual_server_id_transition', 'manual_status_changed',
            'manual_delivery_not_determined'} <= self.codes(report))
        self.assertNotIn('manual_no_outgoing_observed', self.codes(report))

    def test_manual_observation_errors_are_bounded_and_private(self):
        report = self.base()
        report['manualSendObservation'] = {
            'observerOnly': False, 'sendingEnabled': True,
            'state': 'stopped', 'observedOutgoing': 0,
            'lookupMisses': 1, 'identityConflicts': 2,
            'droppedSamplesOrCallbacks': 3,
            'deliveryOutcome': 'confirmed',
            'samples': ['private message', {'source': 'local_readback',
                'serverIDPresent': False, 'body': 'wxid_secret'}],
        }
        codes = self.codes(report)
        self.assertTrue({'manual_observation_not_read_only', 'manual_no_outgoing_observed',
            'manual_lookup_miss', 'manual_identity_conflict', 'manual_samples_dropped',
            'manual_delivery_outcome_unexpected'} <= codes)
        self.assertNotIn('private', str(analyze(report)))
        self.assertNotIn('wxid_secret', str(analyze(report)))

    def test_manual_observation_malformed_section(self):
        report = self.base()
        report['manualSendObservation'] = 'private observation'
        self.assertIn('invalid_manual_observation', self.codes(report))


if __name__ == '__main__':
    unittest.main()
