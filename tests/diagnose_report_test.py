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

    def test_text_experiment_invocation_never_proves_delivery(self):
        report = self.base()
        report['singleTextSendCandidate'] = {'schema': 1, 'batchSendingEnabled': False,
            'submissionAttempted': True, 'observing': True, 'serverIDPresent': True,
            'deliveryOutcome': 'uncertain', 'problem': '', 'lookupMisses': 1}
        report['singleTextExperimentHistory'] = {'claimed': True, 'deliveryOutcome': 'uncertain', 'automaticRetry': False}
        self.assertTrue({'text_host_invoked', 'text_delivery_uncertain', 'text_observing',
            'text_server_association', 'text_lookup_miss', 'text_attempt_claimed'} <= self.codes(report))
        report['singleTextSendCandidate']['deliveryOutcome'] = 'confirmed'
        report['singleTextExperimentHistory']['automaticRetry'] = True
        self.assertTrue({'text_delivery_outcome_invalid', 'text_claim_policy_invalid'} <= self.codes(report))

    def test_text_experiment_abi_account_and_duplicate_gates(self):
        report = self.base()
        candidate = report['singleTextSendCandidate'] = {'schema': 1, 'batchSendingEnabled': 0,
            'submissionAttempted': 0, 'state': 'blocked', 'problem': 'initializer_abi_incompatible'}
        self.assertTrue({'text_not_submitted', 'text_abi_blocked'} <= self.codes(report))
        candidate['problem'] = 'account_or_environment_changed'
        self.assertIn('text_environment_changed', self.codes(report))
        candidate['problem'] = 'one_attempt_per_launch'
        self.assertIn('text_attempt_already_used', self.codes(report))

    def test_text_experiment_malformed_and_private_data_not_echoed(self):
        report = self.base()
        report['singleTextSendCandidate'] = 'private message'
        report['singleTextExperimentHistory'] = 'wxid_secret'
        self.assertTrue({'invalid_text_candidate', 'invalid_text_history'} <= self.codes(report))
        report['singleTextSendCandidate'] = {'schema': 1, 'batchSendingEnabled': False,
            'problem': 'wxid_secret', 'identityConflicts': 1, 'payload': 'private message'}
        self.assertIn('text_identity_conflict', self.codes(report))
        self.assertNotIn('wxid_secret', str(analyze(report)))
        self.assertNotIn('private message', str(analyze(report)))

    def test_observed_64bit_initializer_block_in_old_build(self):
        report = self.base()
        report['build'] = {'plugin': '0.2.10'}
        candidate = report['singleTextSendCandidate'] = {'schema': 1, 'batchSendingEnabled': False,
            'submissionAttempted': False, 'state': 'blocked', 'problem': 'initializer_abi_incompatible',
            'deliveryOutcome': 'not_submitted', 'methods': [
                {'selector': 'initWithMsgType:', 'encoding': '@24@0:8q16', 'available': 1}]}
        report['singleTextExperimentHistory'] = {'claimed': 0, 'deliveryOutcome': 'not_submitted', 'automaticRetry': False}
        self.assertTrue({'text_not_submitted', 'text_abi_blocked', 'text_initializer_width_mismatch'} <= self.codes(report))
        self.assertNotIn('text_host_invoked', self.codes(report))
        self.assertNotIn('text_attempt_claimed', self.codes(report))
        candidate['methods'][0]['encoding'] = '@24@0:8d16'
        self.assertNotIn('text_initializer_width_mismatch', self.codes(report))
        candidate['methods'][0]['encoding'] = '@24@0:8q16'
        report['build']['plugin'] = '0.2.11'
        self.assertNotIn('text_initializer_width_mismatch', self.codes(report))

    def test_initializer_evidence_malformed_is_not_a_width_diagnosis(self):
        report = self.base()
        report['build'] = 'private content'
        candidate = report['singleTextSendCandidate'] = {'schema': 1, 'batchSendingEnabled': False,
            'state': 'blocked', 'problem': 'initializer_abi_incompatible', 'methods': ['private content']}
        self.assertNotIn('text_initializer_width_mismatch', self.codes(report))
        report['build'] = {'plugin': '0.2.10'}
        candidate['methods'] = 'private content'
        self.assertNotIn('text_initializer_width_mismatch', self.codes(report))
        self.assertNotIn('private content', str(analyze(report)))

    def test_old_manager_block_needs_concrete_evidence_not_initializer_change(self):
        report = self.base()
        candidate = report['singleTextSendCandidate'] = {'schema': 1, 'batchSendingEnabled': False,
            'abiValidated': True, 'submissionAttempted': False, 'state': 'blocked',
            'problem': 'message_manager_abi_incompatible', 'initializerCallType': 'q'}
        report['singleTextExperimentHistory'] = {'claimed': True, 'deliveryOutcome': 'uncertain', 'automaticRetry': False}
        self.assertTrue({'text_not_submitted', 'text_attempt_claimed',
            'text_concrete_manager_details_required'} <= self.codes(report))
        self.assertNotIn('text_initializer_width_mismatch', self.codes(report))
        candidate['abiValidated'] = False
        self.assertNotIn('text_concrete_manager_details_required', self.codes(report))

    def test_concrete_signature_and_service_identity_are_distinct(self):
        report = self.base()
        candidate = report['singleTextSendCandidate'] = {'schema': 1, 'batchSendingEnabled': False,
            'abiValidated': True, 'submissionAttempted': False, 'state': 'blocked', 'serviceEvidenceSchema': 1,
            'problem': 'concrete_add_abi_incompatible', 'serviceChecks': {'preflight': {
                'contextClassCode': 1, 'managerClassCode': 2, 'contextReadFailed': False, 'serviceReadFailed': False,
                'add': {'issue': 'return_type'}, 'lookup': {'issue': 'compatible'}}}}
        self.assertTrue({'text_concrete_add_abi_blocked', 'text_named_concrete_abi_differ'} <= self.codes(report))
        self.assertNotIn('text_service_identity_blocked', self.codes(report))
        candidate['serviceChecks']['pre_submit'] = {'contextClassCode': 1, 'managerClassCode': 4,
            'lookup': {'issue': 'second_argument'}}
        self.assertIn('text_service_identity_blocked', self.codes(report))
        self.assertNotIn('text_concrete_lookup_abi_blocked', self.codes(report))

    def test_old_unrelated_service_is_not_proven_incompatible_proxy(self):
        report = self.base()
        report['singleTextSendCandidate'] = {'schema': 1, 'batchSendingEnabled': False,
            'abiValidated': True, 'submissionAttempted': False, 'state': 'blocked', 'serviceEvidenceSchema': 1,
            'problem': 'service_identity_rejected', 'serviceChecks': {'preflight': {
                'contextClassCode': 1, 'managerClassCode': 3, 'add': {'issue': 'missing_method'},
                'lookup': {'issue': 'missing_method'}}}}
        self.assertTrue({'text_not_submitted', 'text_service_identity_blocked',
                         'text_service_wrapper_details_required'} <= self.codes(report))
        self.assertNotIn('text_concrete_add_abi_blocked', self.codes(report))
        self.assertNotIn('text_named_concrete_abi_differ', self.codes(report))

    def test_forwarding_contract_accepted_is_not_delivery(self):
        report = self.base()
        report['singleTextSendCandidate'] = {'schema': 1, 'batchSendingEnabled': False,
            'abiValidated': True, 'submissionAttempted': False, 'state': 'ready', 'serviceEvidenceSchema': 2,
            'serviceChecks': {'preflight': {'contextClassCode': 1, 'managerClassCode': 3,
                'route': 'forwarding_proxy', 'forwarding': {'accepted': 1}, 'add': {'issue': 'missing_method'}}}}
        self.assertIn('text_service_forwarding_validated', self.codes(report))
        self.assertNotIn('text_service_identity_blocked', self.codes(report))
        self.assertNotIn('text_host_invoked', self.codes(report))
        self.assertNotIn('text_concrete_add_abi_blocked', self.codes(report))
        report['singleTextSendCandidate']['observationServiceCheckFailed'] = True
        self.assertIn('text_observation_contract_changed', self.codes(report))

    def test_forwarding_contract_rejected_or_malformed_stays_blocked(self):
        report = self.base()
        candidate = report['singleTextSendCandidate'] = {'schema': 1, 'batchSendingEnabled': False,
            'submissionAttempted': False, 'state': 'blocked', 'serviceEvidenceSchema': 2,
            'serviceChecks': {'preflight': {'contextClassCode': 1, 'managerClassCode': 3,
                'route': 'rejected', 'forwarding': {'accepted': False, 'queryFailed': True}}}}
        self.assertIn('text_service_forwarding_unverified', self.codes(report))
        self.assertNotIn('text_service_forwarding_validated', self.codes(report))
        candidate['serviceChecks']['preflight']['forwarding'] = 'private proxy body'
        self.assertIn('text_service_identity_blocked', self.codes(report))
        self.assertNotIn('private proxy body', str(analyze(report)))

    def test_persistent_claim_is_not_attributed_to_current_source(self):
        report = self.base()
        report['singleTextExperimentHistory'] = {'claimed': True, 'deliveryOutcome': 'uncertain', 'automaticRetry': False}
        findings = analyze(report)
        message = next(item['message'] for item in findings if item['code'] == 'text_attempt_claimed')
        self.assertIn('account-level', message)
        self.assertIn('earlier source', message)

    def test_service_resolution_failure_is_not_a_host_invocation(self):
        report = self.base()
        report['singleTextSendCandidate'] = {'schema': 1, 'batchSendingEnabled': False,
            'submissionAttempted': False, 'state': 'blocked', 'serviceEvidenceSchema': 1, 'serviceChecks': {
                'preflight': {'contextClassCode': 1, 'managerClassCode': 0, 'serviceReadFailed': True}}}
        self.assertTrue({'text_service_identity_blocked', 'text_service_resolution_failed'} <= self.codes(report))
        self.assertNotIn('text_host_invoked', self.codes(report))

    def test_service_evidence_malformed_and_private_values_are_not_echoed(self):
        report = self.base()
        candidate = report['singleTextSendCandidate'] = {'schema': 1, 'batchSendingEnabled': False,
            'serviceEvidenceSchema': 1, 'serviceChecks': 'private content'}
        self.assertIn('text_service_evidence_invalid', self.codes(report))
        candidate['serviceChecks'] = {'preflight': {'managerClassCode': 'wxid_secret',
            'add': {'issue': 'private content', 'arguments': ['private content']}},
            'private content': {'managerClassCode': 4}}
        self.assertNotIn('text_service_identity_blocked', self.codes(report))
        self.assertNotIn('text_concrete_add_abi_blocked', self.codes(report))
        self.assertNotIn('wxid_secret', str(analyze(report)))
        self.assertNotIn('private content', str(analyze(report)))


if __name__ == '__main__':
    unittest.main()
