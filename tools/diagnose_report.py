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
        ('own_timeout', 'own_timeout', 'Own text did not gain a confirmed source ID in the observation window.'),
        ('own_conflict', 'own_conflict', 'Observed own-message fields changed; the candidate was rejected.'),
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
        add('preview_ready', 'One source is frozen for preview. No relay sending is enabled.')

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
