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
        ('receive_invalid_sender', 'invalid_sender', 'A callback lacked a valid sender wxid.'),
        ('receive_no_server_id', 'missing_server_id', 'A callback had no non-zero server message ID.'),
        ('own_timeout', 'own_timeout', 'Own text did not gain a confirmed source ID in the observation window.'),
        ('own_conflict', 'own_conflict', 'Observed own-message fields changed; the candidate was rejected.'),
    ):
        if isinstance(counters.get(key), (int, float)) and counters[key] > 0:
            add(code, message)
    if capture.get('lastReasonCode') == 22:
        add('sender_not_selected', 'A normalized candidate was rejected by the selected-wxid filter.')
    if capture.get('lastReasonCode') == 23:
        add('type_not_selected', 'A normalized candidate was rejected by the selected message types.')
    if receiver.get('armed') and not counters.get('receive_callback') and not counters.get('outgoing_callback'):
        add('no_callback_observed', 'Waiting is armed, but neither candidate hook has been observed; this is not a compatibility verdict.')
    if capture.get('state') == 'preview':
        add('preview_ready', 'One source is frozen for preview. No relay sending is enabled.')
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
