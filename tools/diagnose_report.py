"""Offline triage of a redacted SyncRelay report. Never imports or executes report data."""
import argparse
import json
from pathlib import Path


def analyze(report):
    if not isinstance(report, dict) or report.get('reportSchema') != 1:
        return [{'code': 'unsupported_schema', 'message': 'Unknown report schema; use a matching diagnostic build.'}]
    result = []

    def add(code, message):
        result.append({'code': code, 'message': message})

    def flag(value):
        return bool(value) if type(value) in (bool, int) and value in (0, 1) else None

    draft = report.get('draftSummary', {})
    receiver = report.get('receiveCandidate', {})
    capture = report.get('sourceCapture', {})
    if not all(isinstance(value, dict) for value in (draft, receiver, capture)):
        return [{'code': 'invalid_report', 'message': 'Diagnostic sections are not objects.'}]
    if not report.get('storageReady'):
        add('storage_unavailable', 'Storage is unavailable; capture and rules are disabled.')
    if not draft.get('sourceSelected'):
        add('missing_source', 'Select a source group.')
    if not draft.get('senderCount'):
        add('missing_senders', 'Select source wxids again after changing the source group.')
    if not draft.get('ruleCount'):
        add('missing_rules', 'Create at least one non-empty target rule before waiting.')
    if draft.get('dirty'):
        add('unsaved_draft', 'Save the current draft before waiting.')
    counters = receiver.get('counters', {})
    if not isinstance(counters, dict):
        counters = {}
    for key, code, message in (
        ('receive_wrong_session', 'session_mismatch', 'Receive callbacks were rejected by the session check; inspect adapter semantics.'),
        ('receive_wrong_direction', 'direction_mismatch', 'From/to checks rejected callbacks; do not guess the sender.'),
        ('outgoing_wrong_direction', 'outgoing_direction_mismatch', 'Own-message callbacks were rejected before server-ID observation.'),
        ('receive_invalid_sender', 'invalid_sender', 'A callback lacked a valid sender wxid.'),
        ('receive_no_server_id', 'missing_server_id', 'A callback had no non-zero server message ID.'),
        ('own_timeout', 'own_timeout', 'Own message did not gain a confirmed source ID in the observation window.'),
        ('own_conflict', 'own_conflict', 'Observed own-message fields changed; the candidate was rejected.'),
        ('receive_sender_filtered', 'receiver_sender_filtered', 'Receiver rejected an unselected wxid before reading media/body.'),
        ('receive_type_filtered', 'receiver_type_filtered', 'Receiver rejected an unselected or unsupported message type before preparing media.'),
        ('image_timeout', 'image_timeout', 'Native image was not ready within 30 seconds; no image was captured or sent. Load it in the source group and capture a newly sent image.'),
        ('image_conflict', 'image_source_conflict', 'Account/source identity changed during image preparation; the image was rejected.'),
        ('image_failed', 'image_preparation_failed', 'Native image getter or owned raster validation failed; inspect imageSource. No image was sent.'),
    ):
        if isinstance(counters.get(key), (int, float)) and counters[key] > 0:
            add(code, message)
    direction_mismatch = any(isinstance(counters.get(key), (int, float)) and counters[key] > 0
                             for key in ('receive_wrong_direction', 'outgoing_wrong_direction'))
    if direction_mismatch or receiver.get('directionEvidenceSchema') == 2:
        samples = receiver.get('directionSamples')
        schema = receiver.get('directionEvidenceSchema')
        if type(schema) is not int or schema not in (1, 2):
            add('direction_details_required', 'This report has no supported direction evidence; reproduce using a matching diagnostic build.')
        elif not isinstance(samples, list) or not samples:
            add('direction_details_missing', 'No bounded direction sample was completed; export immediately after reproducing.')
        else:
            evidence = set()
            relation_keys = ('wrapClassCode', 'fromState', 'toState', 'senderState', 'fromIsAccount', 'fromIsSource',
                             'toIsAccount', 'toIsSource', 'senderIsAccount', 'fromEqualsTo')
            for sample in samples[:12]:
                if not isinstance(sample, dict) or sample.get('path') not in ('receive', 'outgoing'):
                    continue
                before, after = sample.get('before'), sample.get('after')
                if not isinstance(before, dict) or not isinstance(after, dict):
                    continue
                if any(type(before.get(key)) in (int, bool) and type(after.get(key)) in (int, bool)
                       and before[key] != after[key] for key in relation_keys):
                    evidence.add('direction_relationships_changed')
                if after.get('wrapClassCode') == 3:
                    evidence.add('direction_unexpected_wrap')
                states = (after.get('fromState'), after.get('toState'))
                if any(type(state) is int and state in (1, 2, 3, 5) for state in states):
                    evidence.add('direction_getter_failed')
                if schema == 1 and after.get('fromState') == 2 and after.get('toState') == 2:
                    evidence.add('direction_instance_signature_rejected')
                if schema == 2 and any(after.get(field + 'State') == 7 and
                                      after.get(field + 'InstanceSignatureState') == 2 for field in ('from', 'to', 'sender')):
                    evidence.add('declared_string_read_recovered')
                if any(type(state) is int and state in (0, 4, 6) for state in states):
                    evidence.add('direction_endpoint_empty')
                if states == (7, 7):
                    if flag(after.get('fromEqualsTo')) is True:
                        evidence.add('direction_same_endpoint')
                    if flag(after.get('fromIsAccount')) is False and flag(after.get('toIsAccount')) is False:
                        evidence.add('direction_account_unmatched')
                    if flag(after.get('fromIsSource')) is False and flag(after.get('toIsSource')) is False:
                        evidence.add('direction_source_unmatched')
            for code, message in (
                ('direction_relationships_changed', 'Pre/post-original direction relationships differ; inspect host-side field changes without accepting pre-call data.'),
                ('direction_unexpected_wrap', 'A sampled object is not the expected message class or a subclass; inspect its actual getter contract.'),
                ('direction_getter_failed', 'A sampled endpoint getter is missing, incompatible, failed, or non-string.'),
                ('direction_instance_signature_rejected', 'Instance-reflection signatures rejected both endpoints before values were read; false relation flags are not ID-mismatch evidence.'),
                ('declared_string_read_recovered', 'A runtime-validated string getter was read despite incompatible instance-reflection metadata; source identity checks still apply.'),
                ('direction_endpoint_empty', 'A sampled endpoint is absent, nil, or empty; do not infer an identity.'),
                ('direction_same_endpoint', 'A sampled from/to pair contains the same non-empty string.'),
                ('direction_account_unmatched', 'Neither sampled endpoint equals the verified account; inspect account identity and version semantics.'),
                ('direction_source_unmatched', 'Neither sampled endpoint equals the selected source although the hook session matched it.'),
            ):
                if code in evidence:
                    add(code, message)
    if capture.get('lastReasonCode') == 22:
        add('sender_not_selected', 'A normalized candidate was rejected by the selected-wxid filter.')
    if capture.get('lastReasonCode') == 23:
        add('type_not_selected', 'A normalized candidate was rejected by the selected message types.')
    if receiver.get('armed') and not counters.get('receive_callback') and not counters.get('outgoing_callback'):
        add('no_callback_observed', 'Waiting is armed, but neither candidate hook has been observed; this is not a compatibility verdict.')
    if capture.get('state') == 'preview':
        add('preview_ready', 'One source is frozen for preview. Preview alone does not submit a message.')
    image = report.get('imageSource')
    if image is not None:
        if not isinstance(image, dict) or image.get('schema') != 1:
            add('image_schema_invalid', 'Image source diagnostics have an unsupported schema.')
        else:
            if image.get('getterABICompatible') is False:
                add('image_getter_unavailable', 'CMessageWrap class image getter is missing or ABI-incompatible; do not use guessed paths as fallback.')
            if image.get('state') == 'result_not_image':
                add('image_result_invalid', 'Native image getter returned an object that was not a UIImage.')
            if receiver.get('imageState') == 'snapshot_ready':
                add('image_snapshot_ready', 'An owned image snapshot passed preparation. Verify actual preview manually; image sending is not enabled.')
            preparation = receiver.get('imagePreparationCode')
            if type(preparation) is int and preparation == 3:
                add('image_storage_quota', 'Owned image storage reached its quota; existing plan images were not evicted.')
            if type(preparation) is int and preparation == 8:
                add('image_raster_unsupported', 'Native raster dimensions or animated image exceeded this static-snapshot capture contract.')

    # The manual send probe is deliberately observational. Keep its findings
    # separate from receive-candidate counters so a local/server ID change can
    # never be interpreted as delivery confirmation.
    manual = report.get('manualSendObservation')
    if manual is not None:
        if not isinstance(manual, dict):
            add('invalid_manual_observation', 'Manual send observation is not an object.')
        else:
            if manual.get('observerOnly') is not True or manual.get('sendingEnabled') is not False:
                add('manual_observation_not_read_only', 'Manual send observation is not marked as observer-only; do not use it for sending decisions.')
            samples = manual.get('samples', [])
            if not isinstance(samples, list):
                add('manual_samples_invalid', 'Manual send observation samples are not a list.')
                samples = []
            else:
                samples = [sample for sample in samples if isinstance(sample, dict)]

            observed = manual.get('observedOutgoing')
            if isinstance(observed, (int, float)) and not isinstance(observed, bool) and observed > 0:
                add('manual_outgoing_observed', 'A matching outgoing callback was observed after the host send path; this is not a send-success count.')
            elif manual.get('state') in ('stopped', 'expired', 'inactive', 'account_changed'):
                add('manual_no_outgoing_observed', 'The manual observation ended without a matching outgoing callback.')

            readbacks = [sample for sample in samples if sample.get('source') == 'local_readback']
            if readbacks:
                add('manual_local_readback', 'A bounded exact-local-ID readback was attempted; mismatches are not substituted with another message.')

            server_seen_false = False
            server_transition = False
            statuses = []
            for sample in samples:
                server_present = sample.get('serverIDPresent')
                if type(server_present) is bool:
                    if server_present and server_seen_false:
                        server_transition = True
                    elif not server_present:
                        server_seen_false = True
                status = sample.get('statusCode')
                if isinstance(status, (int, float)) and not isinstance(status, bool):
                    statuses.append(status)
            if server_transition:
                add('manual_server_id_transition', 'The bounded samples changed from no server ID to a non-zero server ID; this proves association progress, not delivery.')
            if len(set(statuses)) > 1:
                add('manual_status_changed', 'The host status code changed during observation; its numeric meaning is not inferred.')

            for key, code, message in (
                ('lookupMisses', 'manual_lookup_miss', 'An exact local-ID readback did not match; inspect the host readback contract without scanning history.'),
                ('identityConflicts', 'manual_identity_conflict', 'A local/server ID conflict was observed; do not associate the sample with another message.'),
                ('droppedSamplesOrCallbacks', 'manual_samples_dropped', 'The bounded observation queue or sample limit was exceeded; the report is incomplete.'),
            ):
                value = manual.get(key)
                if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0:
                    add(code, message)
            if manual.get('deliveryOutcome') == 'not_determined':
                add('manual_delivery_not_determined', 'Delivery remains unknown by design; keep any future active-send result in a pending-verification state.')
            elif manual.get('deliveryOutcome') is not None:
                add('manual_delivery_outcome_unexpected', 'The manual observation contains a delivery outcome other than not_determined; do not trust it without a new schema.')

    candidate = report.get('singleTextSendCandidate')
    if candidate is not None:
        if not isinstance(candidate, dict) or type(candidate.get('schema')) is not int or candidate['schema'] != 1:
            add('invalid_text_candidate', 'The single-text candidate has no supported diagnostic schema.')
        else:
            if flag(candidate.get('batchSendingEnabled')) is not False:
                add('text_batch_gate_invalid', 'Batch sending is not marked disabled; stop this experimental build.')
            if flag(candidate.get('submissionAttempted')) is True:
                add('text_host_invoked', 'One host invocation was attempted. Do not resend this source, even after restart.')
                if candidate.get('deliveryOutcome') == 'uncertain':
                    add('text_delivery_uncertain', 'Target delivery is unknown; local/server IDs and host status codes are not delivery receipts.')
                else:
                    add('text_delivery_outcome_invalid', 'An invoked experimental send is not marked uncertain; do not treat it as successful.')
            elif candidate.get('state') == 'blocked':
                add('text_not_submitted', 'The single-text host was blocked before invocation.')
            if flag(candidate.get('observing')) is True:
                add('text_observing', 'Exact-local-ID observation is still active; export again after it ends.')
            if flag(candidate.get('observationServiceCheckFailed')) is True:
                add('text_observation_contract_changed', 'A later observation stopped because the service contract changed. Stored pre-submit snapshots describe the earlier check, not the changed contract; delivery remains unknown and must not be retried.')
            if flag(candidate.get('serverIDPresent')) is True:
                add('text_server_association', 'A non-zero server ID was associated, not a verified delivery receipt.')
            problem = candidate.get('problem')
            service_schema = candidate.get('serviceEvidenceSchema')
            if type(service_schema) is int and service_schema in (1, 2):
                checks = candidate.get('serviceChecks')
                if not isinstance(checks, dict):
                    add('text_service_evidence_invalid', 'Concrete service evidence is not an object; use a matching diagnostic build.')
                else:
                    evidence = set()
                    for phase in ('preflight', 'pre_submit'):
                        check = checks.get(phase)
                        if not isinstance(check, dict):
                            continue
                        manager_code = check.get('managerClassCode')
                        direct = type(manager_code) is int and manager_code in (1, 2)
                        forwarding = check.get('forwarding') if service_schema == 2 else None
                        forwarded = (isinstance(forwarding, dict) and check.get('route') == 'forwarding_proxy'
                                     and flag(forwarding.get('accepted')) is True)
                        if ((type(check.get('contextClassCode')) is int and check['contextClassCode'] in (0, 3, 4))
                                or (type(manager_code) is int and manager_code in (0, 3, 4) and not forwarded)):
                            evidence.add('text_service_identity_blocked')
                        if type(manager_code) is int and manager_code == 3:
                            if service_schema == 1:
                                evidence.add('text_service_wrapper_details_required')
                            elif forwarded:
                                evidence.add('text_service_forwarding_validated')
                            else:
                                evidence.add('text_service_forwarding_unverified')
                        if any(flag(check.get(key)) is True for key in ('contextReadFailed', 'serviceReadFailed')):
                            evidence.add('text_service_resolution_failed')
                        for key in ('add', 'lookup'):
                            method = check.get(key)
                            if (direct and isinstance(method, dict) and method.get('issue') in
                                    ('missing_method', 'argument_count', 'return_type', 'first_argument', 'second_argument')):
                                evidence.add('text_concrete_' + key + '_abi_blocked')
                                if flag(candidate.get('abiValidated')) is True and key == 'add':
                                    evidence.add('text_named_concrete_abi_differ')
                    for code, message in (
                        ('text_service_identity_blocked', 'The context/service is absent, a class object, or an unrelated instance without a validated forwarding contract.'),
                        ('text_service_wrapper_details_required', 'The retrieved service has a different runtime class. Missing declared methods alone do not rule out a proxy; this older report has no forwarding-contract evidence.'),
                        ('text_service_forwarding_unverified', 'The returned service did not satisfy the complete forwarding contract; do not remove identity/ABI checks or unwrap the service.'),
                        ('text_service_forwarding_validated', 'The service forwarding contract matched the named ABI. This is capability evidence only, not proof of invocation or delivery.'),
                        ('text_service_resolution_failed', 'A read-only context/service lookup failed; do not infer a send failure.'),
                        ('text_concrete_add_abi_blocked', 'The actual service AddMsg signature failed a specific runtime check; no signature bypass is allowed.'),
                        ('text_concrete_lookup_abi_blocked', 'The actual service exact-ID lookup signature is incompatible; sending remains blocked.'),
                        ('text_named_concrete_abi_differ', 'The named class passed but the concrete service AddMsg check did not. Inspect the bounded concrete evidence, not only named-class methods.'),
                    ):
                        if code in evidence:
                            add(code, message)
            elif (problem == 'message_manager_abi_incompatible' and flag(candidate.get('abiValidated')) is True
                    and flag(candidate.get('submissionAttempted')) is False):
                add('text_concrete_manager_details_required', 'The named-class ABI passed, but the later concrete-service check blocked. This old report lacks the actual service signature; install the concrete-preflight diagnostic build rather than bypassing validation.')
            if isinstance(problem, str):
                if problem.endswith('_abi_incompatible'):
                    add('text_abi_blocked', 'A required host ABI is incompatible. Do not bypass the signature gate.')
                if problem == 'initializer_abi_incompatible':
                    build = report.get('build')
                    methods = candidate.get('methods')
                    if (isinstance(build, dict) and build.get('plugin') in ('0.2.9', '0.2.10')
                            and isinstance(methods, list) and any(isinstance(method, dict)
                                and method.get('selector') == 'initWithMsgType:'
                                and method.get('encoding') in ('@24@0:8q16', '@24@0:8Q16')
                                for method in methods)):
                        add('text_initializer_width_mismatch', 'This older build only accepted a 32-bit initializer, but the host declares a 64-bit integer. Install the ABI-matched fix; do not disable validation.')
                if problem in ('account_or_environment_changed', 'observation_environment_changed'):
                    add('text_environment_changed', 'The verified account or foreground environment changed; no automatic continuation is allowed.')
                if problem == 'one_attempt_per_launch':
                    add('text_attempt_already_used', 'The process-lifetime attempt gate has been consumed; reopening the panel must not submit again.')
                if problem in ('construction_rejected', 'construction_exception', 'capability_check_exception'):
                    add('text_construction_blocked', 'Message construction/capability checks failed before a safe invocation could be established.')
                if problem in ('submission_exception', 'post_submit_identity_unavailable', 'readback_identity_conflict', 'observation_exception'):
                    add('text_requires_manual_review', 'The invocation or identity observation could not be completed reliably. Check the target and do not retry.')
            for key, code, message in (
                ('identityConflicts', 'text_identity_conflict', 'A readback identity conflict occurred; another message must not be substituted.'),
                ('lookupMisses', 'text_lookup_miss', 'An exact-local-ID lookup missed; this is not proof of non-delivery.'),
            ):
                value = candidate.get(key)
                if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0:
                    add(code, message)

    history = report.get('singleTextExperimentHistory')
    if history is not None:
        if not isinstance(history, dict):
            add('invalid_text_history', 'The persistent text experiment summary is not an object.')
        elif flag(history.get('claimed')) is True:
            add('text_attempt_claimed', 'An account-level persistent source reservation exists; it may be from an earlier source, not this report session. Preserve it and do not retry its reserved source.')
            if history.get('deliveryOutcome') != 'uncertain' or flag(history.get('automaticRetry')) is not False:
                add('text_claim_policy_invalid', 'The persistent experiment does not preserve unknown delivery/no-retry policy.')
    if not result:
        add('insufficient_evidence', 'No specific cause is proven; reproduce once and export immediately before restarting.')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    if args.report.stat().st_size > 2 * 1024 * 1024:
        parser.error('Report exceeds the 2 MiB diagnostic limit')
    try:
        report = json.loads(args.report.read_text(encoding='utf-8-sig'))
    except (ValueError, UnicodeError) as error:
        parser.error('Invalid JSON report: ' + type(error).__name__)
    print(json.dumps(analyze(report), indent=2, ensure_ascii=True))


if __name__ == '__main__':
    main()
