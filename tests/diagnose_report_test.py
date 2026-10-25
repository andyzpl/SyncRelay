import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import diagnose_report
from tools.diagnose_report import (analyze, compare_source_time_snapshots,
                                   compare_source_time_stop_snapshots)


class ReportTests(unittest.TestCase):
    def base(self):
        return {'reportSchema': 1, 'storageReady': True,
                'draftSummary': {'sourceSelected': True, 'senderCount': 1, 'ruleCount': 1, 'dirty': False},
                'receiveCandidate': {'armed': True, 'counters': {}}, 'sourceCapture': {'state': 'waiting'}}

    def codes(self, report):
        return {item['code'] for item in analyze(report)}

    def pair_provenance(self, before, after):
        for report, generated_at, sequence in ((before, 1000, 1), (after, 1001, 2)):
            report['build'] = {'plugin': 'test-probe', 'commit': 'a' * 40, 'ciRun': '1'}
            report['generatedAt'] = generated_at
            report['runtimeLog'] = {'events': [
                {'event': 'boot', 'session': 'test-session', 'sequence': sequence}]}

    def source_time_pair(self, stopped=False):
        before = self.base()
        before['sourceTimeProbe'] = self.probe()
        before['sourceCapture'] = {'state': 'idle'}
        before['imageSource'] = {'reads': 0}
        before['sendingEnabled'] = False
        before['receiveCandidate'].update(imageReads=0, receiverGeneration=9)
        after = json.loads(json.dumps(before))
        if stopped:
            after['sourceTimeProbe'].update(active=False, state='stopped')
            after['receiveCandidate'].update(armed=False, receiverGeneration=10)
        self.pair_provenance(before, after)
        return before, after

    def pair_comparator(self, stopped):
        return (compare_source_time_stop_snapshots, 'source_time_stop_pair_',
                'source_time_same_round_samples_retained_after_stop') if stopped else (
                    compare_source_time_snapshots, 'source_time_pair_',
                    'source_time_page_switch_pair_consistent')

    def test_missing_after_source_change(self):
        report = self.base()
        report['draftSummary'].update(senderCount=0, ruleCount=0, dirty=True)
        self.assertTrue({'missing_senders', 'missing_rules', 'unsaved_draft'} <= self.codes(report))

    def test_no_hook_is_not_proof_of_failure(self):
        self.assertIn('no_callback_observed', self.codes(self.base()))

    def test_session_rejection_details_are_fixed_and_redacted(self):
        report = self.base()
        report['receiveCandidate'].update(
            counters={'receive_callback': 1, 'receive_wrong_session': 1},
            sessionRejections={'receive_other_string': 1})
        self.assertIn('session_rejection_details', self.codes(report))
        report['receiveCandidate']['sessionRejections'] = {
            'receive_other_string': 'private@chatroom'}
        self.assertIn('session_rejections_invalid', self.codes(report))
        self.assertNotIn('private@chatroom', str(analyze(report)))

    def test_filter_and_id_reasons(self):
        report = self.base()
        report['receiveCandidate']['counters'] = {'receive_callback': 1, 'receive_no_server_id': 1, 'own_timeout': 1}
        report['sourceCapture']['lastReasonCode'] = 22
        self.assertTrue({'missing_server_id', 'own_timeout', 'sender_not_selected'} <= self.codes(report))

    def test_unknown_and_malformed_schema(self):
        self.assertEqual(self.codes({'reportSchema': 2}), {'unsupported_schema'})
        report = self.base(); report['sourceCapture'] = 'private content'
        self.assertEqual(self.codes(report), {'invalid_report'})

    def test_database_schema_version_is_bounded_and_distinct_from_report_schema(self):
        report = self.base()
        self.assertIn('database_schema_unverified', self.codes(report))
        self.assertNotIn('database_schema_invalid', self.codes(report))
        report['schemaVersion'] = 14
        self.assertNotIn('database_schema_invalid', self.codes(report))

    def test_storage_readiness_must_be_a_boolean_before_schema_interpretation(self):
        malformed_values = (None, 0, 1, 2, 'false', 'true', [], {})
        for value in malformed_values:
            with self.subTest(value=value):
                report = self.base()
                report.update(storageReady=value, schemaVersion=14)
                codes = self.codes(report)
                self.assertIn('storage_readiness_invalid', codes)
                message = next(item['message'] for item in analyze(report)
                               if item['code'] == 'storage_readiness_invalid')
                self.assertIn('JSON boolean true/false', message)
                self.assertNotIn('storage_unavailable', codes)
                self.assertNotIn('database_schema_invalid', codes)
                self.assertNotIn('database_schema_unverified', codes)

        report = self.base()
        report.pop('storageReady')
        report['schemaVersion'] = 14
        codes = self.codes(report)
        self.assertIn('storage_readiness_invalid', codes)
        self.assertNotIn('database_schema_invalid', codes)

    def test_historical_migration_field_is_ignored(self):
        report = self.base()
        report['schemaVersion'] = 14
        report['migrationDiagnostics'] = {'sourceVersion': 11, 'targetVersion': 14}
        self.assertIn('migration_diagnostics_ignored', self.codes(report))
        self.assertNotIn('migration_legacy_row_counts_unchanged', self.codes(report))

    def test_unavailable_storage_expects_a_null_schema_without_a_second_failure(self):
        report = self.base()
        report['storageReady'] = False
        report['schemaVersion'] = None
        self.assertIn('storage_unavailable', self.codes(report))
        self.assertNotIn('database_schema_invalid', self.codes(report))
        report.pop('schemaVersion')
        self.assertNotIn('database_schema_invalid', self.codes(report))
        self.assertNotIn('database_schema_unverified', self.codes(report))
        for value in (14, 0, '14', True):
            report['schemaVersion'] = value
            self.assertIn('database_schema_invalid', self.codes(report))

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

    def probe(self, active=True, state='sampling', round=2, generation=9):
        return {'schema': 1, 'observerOnly': True, 'textOnly': False, 'deliveredTextOnly': True,
                'active': active, 'state': state, 'round': round, 'sampleLimit': 16,
                'durationLimit': 120, 'getterDeclaredReturnEncoding': 'I',
                'getterDeclarationScope': 'configured_wrap_class',
                'actualWrapABIObserved': False, 'prefilteredCallbacksObserved': False,
                'sourceTimeSemanticsVerified': False, 'imageReadinessObserved': False,
                'sendingEnabled': False, 'samples': [], 'hookSampleLimit': 16,
                'hookScope': 'selected_source_text_image_before_readiness_filters',
                'hookSamples': [], 'receiverGeneration': generation}

    def source_time_row(self, hook=False, ordinal=1):
        row = {'ordinal': ordinal, 'messageOrdinal': ordinal, 'round': 2,
               'receiverGeneration': 9, 'selfSource': False, 'createdAt': 103,
               'receivedAt': 104, 'listeningSince': 101.5}
        if hook:
            row.update(messageType=1, path='receive', serverIDPresent=True,
                       correlationScope='server', actualGetterEncoding='I')
        else:
            row.update(deliveredAt=105, deliveryClockRollback=False,
                       relationship='after_boundary', strictPolicyWouldAccept=True)
        return row

    def test_source_time_probe_lifecycle_and_capabilities_are_bounded(self):
        report = self.base()
        report['sourceTimeProbe'] = self.probe()
        codes = self.codes(report)
        self.assertTrue({'source_time_sampling_active'} <= codes)
        self.assertNotIn('source_time_probe_scope_invalid', codes)
        report['sourceTimeProbe']['sendingEnabled'] = True
        self.assertIn('source_time_probe_scope_invalid', self.codes(report))
        report['sourceTimeProbe']['sendingEnabled'] = False
        report['sourceTimeProbe']['active'] = False
        self.assertIn('source_time_probe_lifecycle_invalid', self.codes(report))
        report['sourceTimeProbe'].update(active=True, state='sampling', sendingEnabled=False,
            sourceTimeSemanticsVerified=True, imageReadinessObserved=True)
        self.assertIn('source_time_probe_capability_invalid', self.codes(report))
        report['sourceTimeProbe'].update(sourceTimeSemanticsVerified=False, imageReadinessObserved=False,
            inactivePending=True, inactiveGraceLimit=2, resumedAfterInactive=False)
        self.assertNotIn('source_time_probe_lifecycle_invalid', self.codes(report))
        report['sourceTimeProbe']['inactivePending'] = False
        self.assertNotIn('source_time_probe_lifecycle_invalid', self.codes(report))
        report['sourceTimeProbe']['resumedAfterInactive'] = True
        self.assertNotIn('source_time_probe_lifecycle_invalid', self.codes(report))
        report['sourceTimeProbe']['inactivePending'] = True
        self.assertIn('source_time_probe_lifecycle_invalid', self.codes(report))
        report['sourceTimeProbe'].update(inactivePending=False, resumedAfterInactive=False)
        report['sourceTimeProbe']['inactivePending'] = True
        report['sourceTimeProbe']['active'] = False
        self.assertIn('source_time_probe_lifecycle_invalid', self.codes(report))
        report['sourceTimeProbe'].update(active=True, inactivePending=False, inactiveGraceLimit=3)
        self.assertIn('source_time_probe_lifecycle_invalid', self.codes(report))
        report['sourceTimeProbe']['inactiveGraceLimit'] = 2
        report['sourceTimeProbe']['resumedAfterInactive'] = 'private flag'
        self.assertIn('source_time_probe_lifecycle_invalid', self.codes(report))
        report['sourceTimeProbe']['resumedAfterInactive'] = False
        del report['sourceTimeProbe']['inactivePending']
        self.assertIn('source_time_probe_lifecycle_invalid', self.codes(report))
        report['sourceTimeProbe']['inactivePending'] = False
        report['sourceTimeProbe']['samples'] = 'private message'
        self.assertIn('source_time_probe_samples_invalid', self.codes(report))
        self.assertNotIn('private message', str(analyze(report)))

    def test_source_time_text_evidence_is_not_semantic_certification(self):
        report = self.base()
        probe = report['sourceTimeProbe'] = self.probe(active=False, state='stopped')
        probe['samples'] = [
            {'ordinal': 1, 'messageOrdinal': 1, 'round': 2, 'receiverGeneration': 9,
             'selfSource': False, 'createdAt': 100, 'receivedAt': 102.5,
             'listeningSince': 101.5, 'deliveredAt': 102.7,
             'deliveryClockRollback': False, 'relationship': 'older_than_boundary',
             'strictPolicyWouldAccept': False},
            {'ordinal': 2, 'messageOrdinal': 2, 'round': 2, 'receiverGeneration': 9,
             'selfSource': False, 'createdAt': 103, 'receivedAt': 103.5,
             'listeningSince': 101.5, 'deliveredAt': 103.7,
             'deliveryClockRollback': False, 'relationship': 'after_boundary',
             'strictPolicyWouldAccept': True},
        ]
        codes = self.codes(report)
        self.assertTrue({'source_time_text_samples_observed', 'source_time_older_than_boundary_observed',
                         'source_time_after_boundary_observed', 'source_time_samples_retained_after_stop'} <= codes)
        self.assertNotIn('source_time_semantics_verified', codes)
        self.assertFalse(probe['sourceTimeSemanticsVerified'])

    def test_source_time_hook_metadata_is_not_image_readiness(self):
        report = self.base()
        probe = report['sourceTimeProbe'] = self.probe(active=False, state='stopped')
        probe['actualWrapABIObserved'] = probe['prefilteredCallbacksObserved'] = True
        probe['hookSamples'] = [
            {'ordinal': 1, 'messageOrdinal': 1, 'round': 2, 'receiverGeneration': 9,
             'messageType': 3, 'selfSource': True, 'path': 'receive',
             'serverIDPresent': False, 'correlationScope': 'none',
             'actualGetterEncoding': 'I', 'createdAt': 100, 'receivedAt': 101.5,
             'listeningSince': 99.5},
        ]
        codes = self.codes(report)
        self.assertTrue({'source_time_hook_metadata_observed', 'source_time_image_metadata_observed',
                         'source_time_self_without_server_id_observed',
                         'source_time_image_readiness_unobserved'} <= codes)
        self.assertNotIn('source_time_semantics_verified', codes)

    def test_source_time_malformed_hooks_and_flags(self):
        report = self.base()
        probe = report['sourceTimeProbe'] = self.probe()
        probe['actualWrapABIObserved'] = probe['prefilteredCallbacksObserved'] = True
        probe['hookSamples'] = [{'ordinal': 1, 'messageType': 49, 'path': 'private message'}]
        codes = self.codes(report)
        self.assertTrue({'source_time_probe_hooks_invalid', 'source_time_probe_capability_invalid'} <= codes)
        self.assertNotIn('private message', str(analyze(report)))

    def test_source_time_corrupt_numbers_and_enum_containers_do_not_raise(self):
        for hook in (False, True):
            section = 'hookSamples' if hook else 'samples'
            invalid_code = 'source_time_probe_hooks_invalid' if hook else 'source_time_probe_samples_invalid'
            fields = ('createdAt', 'receivedAt', 'listeningSince') + (() if hook else ('deliveredAt',))
            updates = [{key: value} for key in fields
                       for value in (10 ** 400, float('inf'), float('nan'), 'private-time')]
            updates += [{'actualGetterEncoding' if hook else 'relationship': value}
                        for value in ([], {}, ['private-value'])]
            for update in updates:
                with self.subTest(hook=hook, update=update):
                    report = self.base()
                    probe = report['sourceTimeProbe'] = self.probe()
                    probe[section] = [dict(self.source_time_row(hook), **update)]
                    findings = analyze(report)
                    self.assertIn(invalid_code, {item['code'] for item in findings})
                    self.assertNotIn('private-', str(findings))

    def test_self_local_id_correlation_requires_exact_anonymous_match(self):
        report = self.base()
        probe = report['sourceTimeProbe'] = self.probe(active=False, state='stopped')
        probe['actualWrapABIObserved'] = probe['prefilteredCallbacksObserved'] = True
        probe['hookSamples'] = [
            {'ordinal': 1, 'messageOrdinal': 1, 'round': 2, 'receiverGeneration': 9,
             'messageType': 1, 'selfSource': True, 'path': 'receive',
             'serverIDPresent': False, 'correlationScope': 'local',
             'actualGetterEncoding': 'I', 'createdAt': 103, 'receivedAt': 103.5,
             'listeningSince': 101.5},
        ]
        probe['samples'] = [
            {'ordinal': 1, 'messageOrdinal': 1, 'hookMessageOrdinal': 1,
             'round': 2, 'receiverGeneration': 9, 'selfSource': True,
             'createdAt': 103, 'receivedAt': 103.5, 'listeningSince': 101.5,
             'deliveredAt': 104.7, 'deliveryClockRollback': False,
             'relationship': 'after_boundary', 'strictPolicyWouldAccept': True},
        ]
        codes = self.codes(report)
        self.assertIn('source_time_self_local_id_readback_correlated', codes)
        self.assertNotIn('source_time_self_local_id_correlation_incomplete', codes)
        self.assertNotIn('source_time_semantics_verified', codes)
        self.assertFalse(probe['sourceTimeSemanticsVerified'])

        invalid_updates = (
            {'round': 3}, {'receiverGeneration': 8}, {'messageType': 3},
            {'selfSource': False}, {'correlationScope': 'server'},
            {'serverIDPresent': True}, {'actualGetterEncoding': 'incompatible'},
            {'actualGetterEncoding': 'missing'},
        )
        for update in invalid_updates:
            hook = dict(probe['hookSamples'][0], **update)
            probe['hookSamples'] = [hook]
            codes = self.codes(report)
            self.assertNotIn('source_time_self_local_id_readback_correlated', codes)
            self.assertIn('source_time_self_local_id_correlation_incomplete', codes)

        probe['hookSamples'] = [probe['hookSamples'][0]]
        for update in ({'hookMessageOrdinal': 2}, {'hookMessageOrdinal': '1'},
                       {'selfSource': False}, {'relationship': 'older_than_boundary'},
                       {'strictPolicyWouldAccept': False}, {'createdAt': None}):
            sample = dict(probe['samples'][0], **update)
            probe['samples'] = [sample]
            codes = self.codes(report)
            self.assertNotIn('source_time_self_local_id_readback_correlated', codes)

    def test_self_correlation_does_not_use_raw_identifier_fields(self):
        report = self.base()
        probe = report['sourceTimeProbe'] = self.probe(active=False, state='stopped')
        probe['actualWrapABIObserved'] = probe['prefilteredCallbacksObserved'] = True
        probe['hookSamples'] = [
            {'ordinal': 1, 'messageOrdinal': 1, 'round': 2, 'receiverGeneration': 9,
             'messageType': 1, 'selfSource': True, 'path': 'receive',
             'serverIDPresent': False, 'correlationScope': 'local',
             'actualGetterEncoding': 'I', 'createdAt': 103, 'receivedAt': 103.5,
             'listeningSince': 101.5, 'localID': 'private-local-id',
             'serverID': 'private-server-id'},
        ]
        probe['samples'] = [
            {'ordinal': 1, 'messageOrdinal': 1, 'hookMessageOrdinal': 1,
             'round': 2, 'receiverGeneration': 9, 'selfSource': True,
             'createdAt': 103, 'receivedAt': 103.5, 'listeningSince': 101.5,
             'deliveredAt': 104.7, 'deliveryClockRollback': False,
             'relationship': 'after_boundary', 'strictPolicyWouldAccept': True,
             'localID': 'private-local-id', 'serverID': 'private-server-id'},
        ]
        result = str(analyze(report))
        self.assertIn('source_time_self_local_id_readback_correlated', result)
        self.assertNotIn('private-local-id', result)
        self.assertNotIn('private-server-id', result)

    def test_page_switch_pair_requires_same_active_round_and_retention(self):
        before = self.base()
        before['sourceTimeProbe'] = self.probe()
        before['sourceCapture'] = {'state': 'idle'}
        before['imageSource'] = {'reads': 0}
        before['sendingEnabled'] = False
        before['receiveCandidate'].update(imageReads=0, receiverGeneration=9)
        after = self.base()
        after['sourceTimeProbe'] = self.probe()
        after['sourceCapture'] = {'state': 'idle'}
        after['imageSource'] = {'reads': 0}
        after['sendingEnabled'] = False
        after['receiveCandidate'].update(imageReads=0, receiverGeneration=9)
        self.pair_provenance(before, after)
        self.assertEqual({item['code'] for item in compare_source_time_snapshots(before, after)},
                         {'source_time_page_switch_pair_consistent'})

        after['sourceTimeProbe']['state'] = 'environment_blocked'
        self.assertIn('source_time_pair_environment_blocked',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        after['sourceTimeProbe']['state'] = 'sampling'
        after['sourceTimeProbe']['inactivePending'] = True
        self.assertIn('source_time_pair_inactive_pending',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        after['sourceTimeProbe']['inactivePending'] = False
        after['sourceTimeProbe']['round'] = 3
        self.assertIn('source_time_pair_round_changed',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        after['sourceTimeProbe']['round'] = 2
        after['receiveCandidate']['receiverGeneration'] = 10
        self.assertIn('source_time_pair_generation_changed',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        after['receiveCandidate']['receiverGeneration'] = 9
        before['receiveCandidate']['counters'] = {'receiver_stopped': 1}
        after['receiveCandidate']['counters'] = {'receiver_stopped': 1}
        self.assertNotIn('source_time_pair_receiver_stopped',
                         {item['code'] for item in compare_source_time_snapshots(before, after)})
        before['receiveCandidate']['counters'] = {}
        after['receiveCandidate']['counters'] = {'receiver_stopped': 1}
        self.assertIn('source_time_pair_receiver_stopped',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        after['receiveCandidate']['counters'] = {}
        after['sourceCapture']['state'] = 'waiting'
        self.assertIn('source_time_pair_capture_not_idle',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})

    def test_page_switch_pair_rejects_invalid_round_and_generation(self):
        before = self.base()
        before['sourceTimeProbe'] = self.probe()
        before['sourceCapture'] = {'state': 'idle'}
        before['imageSource'] = {'reads': 0}
        before['sendingEnabled'] = False
        before['receiveCandidate'].update(imageReads=0, receiverGeneration=9)
        after = self.base()
        after['sourceTimeProbe'] = self.probe()
        after['sourceCapture'] = {'state': 'idle'}
        after['imageSource'] = {'reads': 0}
        after['sendingEnabled'] = False
        after['receiveCandidate'].update(imageReads=0, receiverGeneration=9)
        self.pair_provenance(before, after)

        after['sourceTimeProbe']['round'] = '2'
        self.assertIn('source_time_pair_round_invalid',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        after['sourceTimeProbe']['round'] = 2
        after['receiveCandidate']['receiverGeneration'] = '9'
        self.assertIn('source_time_pair_generation_invalid',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        del before['receiveCandidate']['receiverGeneration']
        del after['receiveCandidate']['receiverGeneration']
        self.assertIn('source_time_pair_generation_invalid',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})

    def test_page_switch_pair_rejects_lost_or_mutated_samples(self):
        before = self.base()
        probe = before['sourceTimeProbe'] = self.probe()
        probe['samples'] = [
            {'ordinal': 1, 'messageOrdinal': 1, 'round': 2, 'receiverGeneration': 9,
             'selfSource': False, 'createdAt': 100, 'receivedAt': 101.5,
             'listeningSince': 99.5, 'deliveredAt': 101.7,
             'deliveryClockRollback': False, 'relationship': 'after_boundary',
             'strictPolicyWouldAccept': True},
        ]
        before['sourceCapture'] = {'state': 'idle'}
        before['imageSource'] = {'reads': 0}
        before['sendingEnabled'] = False
        before['receiveCandidate'].update(imageReads=0, receiverGeneration=9)
        after = {key: (value.copy() if isinstance(value, dict) else value) for key, value in before.items()}
        after['sourceTimeProbe'] = {key: (value.copy() if isinstance(value, list) else value)
                                    for key, value in probe.items()}
        self.pair_provenance(before, after)
        after['sourceTimeProbe']['samples'] = []
        self.assertIn('source_time_pair_samples_lost',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        after['sourceTimeProbe']['samples'] = [dict(probe['samples'][0], createdAt=101)]
        self.assertIn('source_time_pair_samples_changed',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        after['sourceTimeProbe']['samples'] = [dict(probe['samples'][0], deliveredAt=101.8)]
        self.assertIn('source_time_pair_samples_changed',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        after['sourceTimeProbe']['samples'] = probe['samples']
        after['imageSource']['reads'] = 1
        self.assertIn('source_time_pair_image_reads_changed',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        after['imageSource']['reads'] = 0
        after['sendingEnabled'] = True
        self.assertIn('source_time_pair_sending_not_disabled',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        after['sendingEnabled'] = False
        after['receiveCandidate']['imageReads'] = 1
        self.assertIn('source_time_pair_image_reads_changed',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        after['receiveCandidate']['imageReads'] = 0
        del after['sendingEnabled']
        self.assertIn('source_time_pair_sending_not_disabled',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})
        after['sendingEnabled'] = False
        del after['receiveCandidate']['imageReads']
        self.assertIn('source_time_pair_image_reads_changed',
                      {item['code'] for item in compare_source_time_snapshots(before, after)})

    def test_stop_pair_requires_same_round_retention_and_disarmed_receiver(self):
        before = self.base()
        probe = before['sourceTimeProbe'] = self.probe()
        probe['samples'] = [
            {'ordinal': 1, 'messageOrdinal': 1, 'round': 2, 'receiverGeneration': 9,
             'selfSource': False, 'createdAt': 100, 'receivedAt': 101.5,
             'listeningSince': 99.5, 'deliveredAt': 101.7,
             'deliveryClockRollback': False, 'relationship': 'older_than_boundary',
             'strictPolicyWouldAccept': False},
        ]
        probe['hookSamples'] = [
            {'ordinal': 1, 'messageOrdinal': 1, 'round': 2, 'receiverGeneration': 9,
             'messageType': 1, 'selfSource': False, 'path': 'receive',
             'serverIDPresent': True, 'correlationScope': 'server',
             'actualGetterEncoding': 'I', 'createdAt': 100, 'receivedAt': 101.5,
             'listeningSince': 99.5},
        ]
        before['sourceCapture'] = {'state': 'idle'}
        before['imageSource'] = {'reads': 0}
        before['sendingEnabled'] = False
        before['receiveCandidate'].update(imageReads=0, receiverGeneration=9)
        after = self.base()
        after['sourceTimeProbe'] = self.probe(active=False, state='stopped')
        after['sourceTimeProbe']['samples'] = [dict(probe['samples'][0])]
        after['sourceTimeProbe']['hookSamples'] = [dict(probe['hookSamples'][0])]
        after['sourceCapture'] = {'state': 'idle'}
        after['imageSource'] = {'reads': 0}
        after['sendingEnabled'] = False
        after['receiveCandidate'].update(armed=False, imageReads=0, receiverGeneration=10)
        self.pair_provenance(before, after)
        self.assertEqual({item['code'] for item in compare_source_time_stop_snapshots(before, after)},
                         {'source_time_same_round_samples_retained_after_stop'})

        after['sourceTimeProbe']['round'] = 3
        self.assertIn('source_time_stop_pair_round_changed',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})
        after['sourceTimeProbe']['round'] = 2
        after['sourceTimeProbe']['samples'][0]['deliveredAt'] = 101.8
        self.assertIn('source_time_stop_pair_samples_changed',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})
        after['sourceTimeProbe']['samples'][0]['deliveredAt'] = 101.7
        before['sourceTimeProbe']['inactivePending'] = True
        self.assertIn('source_time_stop_pair_before_inactive_pending',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})
        before['sourceTimeProbe']['inactivePending'] = False
        after['receiveCandidate']['receiverGeneration'] = 10
        after['receiveCandidate']['armed'] = True
        self.assertIn('source_time_stop_pair_receiver_still_armed',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})
        after['receiveCandidate']['armed'] = False
        after['sourceTimeProbe']['samples'] = []
        self.assertIn('source_time_stop_pair_samples_lost',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})

    def test_stop_pair_rejects_wrong_lifecycle_and_unsafe_snapshots(self):
        before = self.base()
        before['sourceTimeProbe'] = self.probe()
        before['sourceCapture'] = {'state': 'idle'}
        before['imageSource'] = {'reads': 0}
        before['sendingEnabled'] = False
        before['receiveCandidate'].update(imageReads=0, receiverGeneration=9)
        after = self.base()
        after['sourceTimeProbe'] = self.probe(active=False, state='stopped')
        after['sourceCapture'] = {'state': 'idle'}
        after['imageSource'] = {'reads': 0}
        after['sendingEnabled'] = False
        after['receiveCandidate'].update(armed=False, imageReads=0, receiverGeneration=10)
        self.pair_provenance(before, after)
        after['sourceTimeProbe']['active'] = True
        self.assertIn('source_time_stop_pair_after_not_stopped',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})
        after['sourceTimeProbe']['active'] = False
        for state in ('inactive', 'environment_blocked', 'receiver_stopped', 'time_limit',
                      'sample_limit', 'configuration_changed', 'account_invalidated',
                      'clock_invalid', 'context_unavailable'):
            after['sourceTimeProbe']['state'] = state
            self.assertIn('source_time_stop_pair_after_not_manual_stop',
                          {item['code'] for item in compare_source_time_stop_snapshots(before, after)})
        after['sourceTimeProbe']['state'] = 'stopped'
        after['sourceCapture']['state'] = 'waiting'
        self.assertIn('source_time_stop_pair_capture_not_idle',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})
        after['sourceCapture']['state'] = 'idle'
        after['imageSource']['reads'] = 1
        self.assertIn('source_time_stop_pair_image_reads_changed',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})
        after['imageSource']['reads'] = 0
        del after['sendingEnabled']
        self.assertIn('source_time_stop_pair_sending_not_disabled',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})

    def test_stop_pair_rejects_invalid_round_armed_and_generation(self):
        before = self.base()
        before['sourceTimeProbe'] = self.probe()
        before['sourceCapture'] = {'state': 'idle'}
        before['imageSource'] = {'reads': 0}
        before['sendingEnabled'] = False
        before['receiveCandidate'].update(imageReads=0, receiverGeneration=9)
        after = self.base()
        after['sourceTimeProbe'] = self.probe(active=False, state='stopped')
        after['sourceCapture'] = {'state': 'idle'}
        after['imageSource'] = {'reads': 0}
        after['sendingEnabled'] = False
        after['receiveCandidate'].update(armed=False, imageReads=0, receiverGeneration=10)
        self.pair_provenance(before, after)

        after['sourceTimeProbe']['round'] = '2'
        self.assertIn('source_time_stop_pair_round_invalid',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})
        after['sourceTimeProbe']['round'] = 2
        before['receiveCandidate']['armed'] = False
        self.assertIn('source_time_stop_pair_before_receiver_not_armed',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})
        before['receiveCandidate']['armed'] = True
        after['receiveCandidate']['armed'] = 1
        self.assertIn('source_time_stop_pair_receiver_still_armed',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})
        after['receiveCandidate']['armed'] = False
        after['receiveCandidate']['receiverGeneration'] = '10'
        self.assertIn('source_time_stop_pair_generation_invalid',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})
        after['receiveCandidate']['receiverGeneration'] = 9
        self.assertIn('source_time_stop_pair_generation_not_advanced',
                      {item['code'] for item in compare_source_time_stop_snapshots(before, after)})

    def test_pairs_reject_different_or_unverified_builds(self):
        for stopped in (False, True):
            compare, prefix, success = self.pair_comparator(stopped)
            for key in ('plugin', 'commit', 'ciRun'):
                with self.subTest(stopped=stopped, key=key):
                    before, after = self.source_time_pair(stopped)
                    after['build'][key] = {'plugin': 'other-probe', 'commit': 'b' * 40,
                                           'ciRun': '2'}[key]
                    codes = {item['code'] for item in compare(before, after)}
                    self.assertIn(prefix + 'build_changed', codes)
                    self.assertNotIn(success, codes)
                    for value in (None, '', 1, 'working-tree', 'local'):
                        before['build'][key] = after['build'][key] = value
                        self.assertIn(prefix + 'build_unverified',
                                      {item['code'] for item in compare(before, after)})
            for value in (None, [], {}):
                before, after = self.source_time_pair(stopped)
                after['build'] = value
                self.assertIn(prefix + 'build_unverified',
                              {item['code'] for item in compare(before, after)})

    def test_pairs_reject_cross_launch_round_number_collisions(self):
        for stopped in (False, True):
            compare, prefix, success = self.pair_comparator(stopped)
            before, after = self.source_time_pair(stopped)
            after['runtimeLog']['events'][0]['session'] = 'private-other-launch'
            findings = compare(before, after)
            codes = {item['code'] for item in findings}
            self.assertIn(prefix + 'session_changed', codes)
            self.assertNotIn(success, codes)
            self.assertNotIn('private-other-launch', str(findings))

    def test_pairs_require_one_current_launch_not_persisted_history(self):
        invalid_logs = (None, {}, {'events': []}, {'events': 'private-log'},
            {'events': [None]}, {'events': [{'previousLaunch': True, 'session': 'old'}]},
            {'events': [{'event': 'boot', 'sequence': 1}]},
            {'events': [{'session': '', 'sequence': 1}]},
            {'events': [{'session': 'one', 'sequence': True}]},
            {'events': [{'session': 'one', 'sequence': 0}]},
            {'events': [{'session': 'one', 'sequence': 1, 'previousLaunch': 'false'}]},
            {'events': [{'session': 'one', 'sequence': 1}, {'session': 'two', 'sequence': 2}]},
            {'events': [{'session': 'one', 'sequence': 2}, {'session': 'one', 'sequence': 1}]})
        for stopped in (False, True):
            compare, prefix, success = self.pair_comparator(stopped)
            for log in invalid_logs:
                with self.subTest(stopped=stopped, log=log):
                    before, after = self.source_time_pair(stopped)
                    after['runtimeLog'] = log
                    findings = compare(before, after)
                    codes = {item['code'] for item in findings}
                    self.assertIn(prefix + 'session_unverified', codes)
                    self.assertNotIn(success, codes)
                    self.assertNotIn('private-log', str(findings))

    def test_pairs_reject_invalid_reversed_or_duplicate_export_times(self):
        for stopped in (False, True):
            compare, prefix, success = self.pair_comparator(stopped)
            for value in (None, True, '1001', 0, -1, float('inf'), float('nan'), 10 ** 400):
                with self.subTest(stopped=stopped, value=value):
                    before, after = self.source_time_pair(stopped)
                    after['generatedAt'] = value
                    self.assertIn(prefix + 'export_time_invalid',
                                  {item['code'] for item in compare(before, after)})
            for value in (999, 1000):
                before, after = self.source_time_pair(stopped)
                after['generatedAt'] = value
                codes = {item['code'] for item in compare(before, after)}
                self.assertIn(prefix + 'export_order_invalid', codes)
                self.assertNotIn(success, codes)

    def test_pairs_require_integer_report_and_probe_schema_versions(self):
        for stopped in (False, True):
            compare, prefix, success = self.pair_comparator(stopped)
            for section in (None, 'sourceTimeProbe'):
                for value in (True, 1.0):
                    with self.subTest(stopped=stopped, section=section, value=value):
                        before, after = self.source_time_pair(stopped)
                        for report in (before, after):
                            (report if section is None else report[section])[
                                'reportSchema' if section is None else 'schema'] = value
                        findings = compare(before, after)
                        self.assertIn(prefix + 'invalid', {item['code'] for item in findings})
                        self.assertNotIn(success, {item['code'] for item in findings})
                        if section is None:
                            self.assertEqual({'unsupported_schema'}, self.codes(before))

    def test_pairs_validate_bounded_sample_rows_before_retention(self):
        for stopped in (False, True):
            compare, prefix, success = self.pair_comparator(stopped)
            for hook in (False, True):
                section = 'hookSamples' if hook else 'samples'
                row = self.source_time_row(hook)
                invalid_rows = [None, 1, 'private-sample', {},
                                dict(row, createdAt=10 ** 400), dict(row, receivedAt=float('nan')),
                                dict(row, **{'actualGetterEncoding' if hook else 'relationship': []})]
                if hook:
                    invalid_rows.append(dict(row, messageType=True))
                arrays = [[row] for row in invalid_rows]
                arrays.append([self.source_time_row(hook, ordinal) for ordinal in range(1, 18)])
                for index, rows in enumerate(arrays):
                    with self.subTest(stopped=stopped, hook=hook, case=index):
                        before, after = self.source_time_pair(stopped)
                        before['sourceTimeProbe'][section] = rows
                        after['sourceTimeProbe'][section] = rows
                        findings = compare(before, after)
                        codes = {item['code'] for item in findings}
                        self.assertIn(prefix + 'samples_invalid', codes)
                        self.assertNotIn(success, codes)
                        self.assertNotIn('private-sample', str(findings))

    def test_pairs_reject_cross_round_generation_ordinal_and_boundary_evidence(self):
        for stopped in (False, True):
            compare, prefix, success = self.pair_comparator(stopped)
            for hook in (False, True):
                section = 'hookSamples' if hook else 'samples'
                row = self.source_time_row(hook)
                arrays = [[dict(row, **update)] for update in
                          ({'round': 3}, {'receiverGeneration': 10}, {'ordinal': 2})]
                arrays += [[row, dict(row)],
                           [row, dict(self.source_time_row(hook, 2), listeningSince=102.5)]]
                for index, rows in enumerate(arrays):
                    with self.subTest(stopped=stopped, hook=hook, case=index):
                        before, after = self.source_time_pair(stopped)
                        before['sourceTimeProbe'][section] = after['sourceTimeProbe'][section] = rows
                        codes = {item['code'] for item in compare(before, after)}
                        self.assertIn(prefix + 'samples_invalid', codes)
                        self.assertNotIn(success, codes)
            before, after = self.source_time_pair(stopped)
            before['sourceTimeProbe']['samples'] = [self.source_time_row()]
            after['sourceTimeProbe']['samples'] = [self.source_time_row()]
            after['sourceTimeProbe']['hookSamples'] = [dict(self.source_time_row(True), listeningSince=102.5)]
            self.assertIn(prefix + 'samples_invalid',
                          {item['code'] for item in compare(before, after)})

    def test_pairs_reject_unsafe_scope_and_malformed_lifecycle_state(self):
        updates = ({'observerOnly': False}, {'sendingEnabled': True},
                   {'observerOnly': 'private-scope'}, {'sourceTimeSemanticsVerified': True},
                   {'imageReadinessObserved': True}, {'imageReadinessObserved': None})
        for stopped in (False, True):
            compare, prefix, success = self.pair_comparator(stopped)
            for snapshot in (0, 1):
                for update in updates:
                    with self.subTest(stopped=stopped, snapshot=snapshot, update=update):
                        pair = self.source_time_pair(stopped)
                        pair[snapshot]['sourceTimeProbe'].update(update)
                        findings = compare(*pair)
                        codes = {item['code'] for item in findings}
                        self.assertIn(prefix + 'scope_invalid', codes)
                        self.assertNotIn(success, codes)
                        self.assertNotIn('private-scope', str(findings))
            for state in ([], {}, ['private-state']):
                with self.subTest(stopped=stopped, state=state):
                    before, after = self.source_time_pair(stopped)
                    after['sourceTimeProbe']['state'] = state
                    findings = compare(before, after)
                    codes = {item['code'] for item in findings}
                    self.assertIn(prefix + ('after_not_stopped' if stopped else 'not_active'), codes)
                    self.assertNotIn(success, codes)
                    self.assertNotIn('private-state', str(findings))

    def test_pairs_allow_valid_appended_samples_and_preserve_original_generation_on_stop(self):
        for stopped in (False, True):
            compare, _, success = self.pair_comparator(stopped)
            before, after = self.source_time_pair(stopped)
            for hook in (False, True):
                section = 'hookSamples' if hook else 'samples'
                before['sourceTimeProbe'][section] = [self.source_time_row(hook)]
                after['sourceTimeProbe'][section] = [self.source_time_row(hook), self.source_time_row(hook, 2)]
            for report in (before, after):
                report['sourceTimeProbe'].update(observerOnly=1, sendingEnabled=0,
                    sourceTimeSemanticsVerified=0, imageReadinessObserved=0,
                    actualWrapABIObserved=True, prefilteredCallbacksObserved=True)
            self.assertEqual({success}, {item['code'] for item in compare(before, after)})
            if stopped:
                self.assertEqual(10, after['receiveCandidate']['receiverGeneration'])
                self.assertEqual(9, after['sourceTimeProbe']['samples'][0]['receiverGeneration'])

    def test_pairs_allow_trimmed_logs_but_not_rewound_sequences(self):
        for stopped in (False, True):
            compare, prefix, success = self.pair_comparator(stopped)
            before, after = self.source_time_pair(stopped)
            before['runtimeLog']['events'] = [
                {'previousLaunch': True, 'session': 'ignored-old-session', 'sequence': 999},
                {'session': 'test-session', 'sequence': 299},
                {'session': 'test-session', 'sequence': 300}]
            after['runtimeLog']['events'] = [{'session': 'test-session', 'sequence': 301}]
            self.assertEqual({success}, {item['code'] for item in compare(before, after)})
            after['runtimeLog']['events'][0]['sequence'] = 300
            self.assertEqual({success}, {item['code'] for item in compare(before, after)})
            after['runtimeLog']['events'][0]['sequence'] = 299
            codes = {item['code'] for item in compare(before, after)}
            self.assertIn(prefix + 'log_rewound', codes)
            self.assertNotIn(success, codes)

    def run_cli(self, *arguments):
        output = io.StringIO()
        with mock.patch('sys.argv', ['diagnose_report.py', *map(str, arguments)]), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            diagnose_report.main()
        return json.loads(output.getvalue())

    def test_cli_analyzes_one_report_and_compares_a_pair(self):
        before = self.base()
        before['sourceTimeProbe'] = self.probe()
        before['sourceCapture'] = {'state': 'idle'}
        before['imageSource'] = {'reads': 0}
        before['sendingEnabled'] = False
        before['receiveCandidate'].update(imageReads=0, receiverGeneration=9)
        after = self.base()
        after['sourceTimeProbe'] = self.probe()
        after['sourceCapture'] = {'state': 'idle'}
        after['imageSource'] = {'reads': 0}
        after['sendingEnabled'] = False
        after['receiveCandidate'].update(imageReads=0, receiverGeneration=9)
        self.pair_provenance(before, after)
        with tempfile.TemporaryDirectory() as directory:
            before_path = Path(directory) / 'before.json'
            after_path = Path(directory) / 'after.json'
            before_path.write_text(json.dumps(before), encoding='utf-8')
            after_path.write_text(json.dumps(after), encoding='utf-8')
            single = self.run_cli(before_path)
            self.assertIn('source_time_sampling_active', {item['code'] for item in single})
            pair = self.run_cli('--pair', before_path, after_path)
            self.assertEqual([{'code': 'source_time_page_switch_pair_consistent',
                               'message': pair[0]['message']}], pair)
            self.assertIn('local lifecycle evidence', pair[0]['message'])
            stopped = self.base()
            stopped['sourceTimeProbe'] = self.probe(active=False, state='stopped')
            stopped['sourceCapture'] = {'state': 'idle'}
            stopped['imageSource'] = {'reads': 0}
            stopped['sendingEnabled'] = False
            stopped['receiveCandidate'].update(armed=False, imageReads=0, receiverGeneration=10)
            self.pair_provenance(before, stopped)
            stopped_path = Path(directory) / 'stopped.json'
            stopped_path.write_text(json.dumps(stopped), encoding='utf-8')
            stop_pair = self.run_cli('--stop-pair', before_path, stopped_path)
            self.assertEqual([{'code': 'source_time_same_round_samples_retained_after_stop',
                               'message': stop_pair[0]['message']}], stop_pair)
            self.assertIn('local lifecycle and retention evidence', stop_pair[0]['message'])

    def test_cli_rejects_ambiguous_or_missing_arguments(self):
        before = self.base()
        before['sourceTimeProbe'] = self.probe()
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'report.json'
            report.write_text(json.dumps(before), encoding='utf-8')
            for arguments in ((), (report, '--pair', report, report),
                              ('--pair', report), (report, report),
                              ('--stop-pair', report), (report, '--stop-pair', report, report)):
                with self.subTest(arguments=arguments), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as raised:
                        diagnose_report.main() if not arguments else self.run_cli(*arguments)
                    self.assertEqual(2, raised.exception.code)

    def test_cli_returns_fixed_findings_for_corrupt_source_time_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            before_path, after_path = Path(directory) / 'before.json', Path(directory) / 'after.json'
            for stopped in (False, True):
                before, after = self.source_time_pair(stopped)
                for report in (before, after):
                    report['sourceTimeProbe']['samples'] = [None]
                    report['privateField'] = 'private-body-wxid-path'
                before_path.write_text(json.dumps(before), encoding='utf-8')
                after_path.write_text(json.dumps(after), encoding='utf-8')
                findings = self.run_cli('--stop-pair' if stopped else '--pair', before_path, after_path)
                _, prefix, success = self.pair_comparator(stopped)
                codes = {item['code'] for item in findings}
                self.assertIn(prefix + 'samples_invalid', codes)
                self.assertNotIn(success, codes)
                self.assertNotIn('private-body-wxid-path', str(findings))
            before['sourceTimeProbe']['samples'] = [dict(self.source_time_row(), createdAt=10 ** 400)]
            before_path.write_text(json.dumps(before), encoding='utf-8')
            findings = self.run_cli(before_path)
            self.assertIn('source_time_probe_samples_invalid', {item['code'] for item in findings})
            self.assertNotIn('private-body-wxid-path', str(findings))


if __name__ == '__main__':
    unittest.main()
