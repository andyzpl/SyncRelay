"""Offline triage of a redacted SyncRelay report. Never imports or executes report data."""
import argparse
import json
import math
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
    storage_ready = report.get('storageReady')
    if not storage_ready:
        add('storage_unavailable', 'Storage is unavailable; capture and rules are disabled.')
    database_schema = report.get('schemaVersion', ...)
    # Older reports did not include this field. Keep that absence distinct from
    # an explicitly reported, incompatible version. When storage failed, null
    # is the expected version value and storage_unavailable already covers it.
    if storage_ready and database_schema is ...:
        add('database_schema_unverified',
            'The report does not include a database schema version; do not use it as schema evidence.')
    elif storage_ready and (type(database_schema) is not int or database_schema != 14):
        add('database_schema_invalid',
            'The database schema is not the expected schema 14; do not migrate, downgrade or delete data from this report.')
    elif not storage_ready and database_schema is not ... and database_schema is not None:
        add('database_schema_invalid',
            'Storage is unavailable but the report claims a database schema; do not migrate, downgrade or delete data from this report.')
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
    has_direction_activity = (receiver.get('armed') is True or bool(receiver.get('directionSamples')) or
                              any(type(counters.get(key)) is int and counters[key] > 0
                                  for key in ('receive_callback', 'outgoing_callback')))
    if direction_mismatch or receiver.get('directionEvidenceSchema') == 2 and has_direction_activity:
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
    probe = report.get('sourceTimeProbe')
    if probe is not None:
        if not isinstance(probe, dict):
            add('source_time_probe_invalid', 'The source-time probe section is not an object.')
        elif type(probe.get('schema')) is not int or probe['schema'] != 1:
            add('source_time_probe_schema_invalid', 'The source-time probe uses an unsupported schema.')
        else:
            probe_states = {'off', 'sampling', 'stopped', 'inactive', 'configuration_changed',
                            'account_invalidated', 'environment_blocked', 'receiver_stopped',
                            'clock_invalid', 'time_limit', 'sample_limit', 'context_unavailable'}
            relationships = {'older_than_boundary', 'after_boundary', 'same_second',
                             'future_or_different_units', 'missing_or_invalid',
                             'receive_clock_rollback'}
            getter_encodings = {'i', 'I', 'q', 'Q', 'l', 'L', 'missing', 'incompatible'}
            scope_values = {'server', 'local', 'none'}
            active = flag(probe.get('active'))
            state = probe.get('state')
            inactive_pending = flag(probe.get('inactivePending'))
            inactive_grace = probe.get('inactiveGraceLimit')
            if active is None or not isinstance(state, str) or state not in probe_states:
                add('source_time_probe_lifecycle_invalid', 'The source-time probe lifecycle fields are malformed.')
            elif active and state != 'sampling':
                add('source_time_probe_lifecycle_invalid', 'An active source-time probe is not in the sampling state.')
            elif not active and state == 'sampling':
                add('source_time_probe_lifecycle_invalid', 'A non-active source-time probe still reports sampling.')
            if ('inactivePending' in probe) != ('inactiveGraceLimit' in probe):
                add('source_time_probe_lifecycle_invalid',
                    'The foreground-inactive grace fields are incomplete.')
            elif 'inactivePending' in probe:
                if inactive_pending is None or type(inactive_grace) is not int or inactive_grace != 2 or \
                        (inactive_pending and active is not True):
                    add('source_time_probe_lifecycle_invalid',
                        'The foreground-inactive grace state is malformed or outside active sampling.')
                resumed = flag(probe.get('resumedAfterInactive')) if 'resumedAfterInactive' in probe else False
                if resumed is None or (resumed and inactive_pending):
                    add('source_time_probe_lifecycle_invalid',
                        'The foreground-inactive resume flag is malformed or inconsistent.')
            if flag(probe.get('observerOnly')) is not True or flag(probe.get('sendingEnabled')) is not False:
                add('source_time_probe_scope_invalid',
                    'The source-time probe is not marked observer-only with sending disabled.')
            for key in ('sourceTimeSemanticsVerified', 'imageReadinessObserved'):
                if flag(probe.get(key)) is not False:
                    add('source_time_probe_capability_invalid',
                        'A source-time capability is marked verified without the required device evidence.')

            samples = probe.get('samples')
            hooks = probe.get('hookSamples')
            if not isinstance(samples, list) or len(samples) > 16:
                add('source_time_probe_samples_invalid', 'Text samples are missing or exceed the bounded limit.')
                samples = []
            if not isinstance(hooks, list) or len(hooks) > 16:
                add('source_time_probe_hooks_invalid', 'Hook samples are missing or exceed the bounded limit.')
                hooks = []

            valid_samples = []
            for sample in samples:
                valid = isinstance(sample, dict)
                if valid:
                    ordinal, message_ordinal = sample.get('ordinal'), sample.get('messageOrdinal')
                    valid = (type(ordinal) is int and 1 <= ordinal <= 16 and
                             (message_ordinal is None or (type(message_ordinal) is int and message_ordinal >= 1)) and
                             (sample.get('hookMessageOrdinal') is None or
                              (type(sample.get('hookMessageOrdinal')) is int and
                               1 <= sample['hookMessageOrdinal'] <= 16)) and
                             type(sample.get('round')) is int and sample['round'] >= 0 and
                             type(sample.get('receiverGeneration')) is int and sample['receiverGeneration'] >= 0 and
                             flag(sample.get('selfSource')) is not None and
                             (sample.get('createdAt') is None or
                              (type(sample.get('createdAt')) in (int, float) and
                               math.isfinite(sample['createdAt']))) and
                             all(type(sample.get(key)) in (int, float) and math.isfinite(sample[key]) and sample[key] > 0
                                 for key in ('receivedAt', 'listeningSince', 'deliveredAt')) and
                             flag(sample.get('deliveryClockRollback')) is not None and
                             sample.get('relationship') in relationships and
                             flag(sample.get('strictPolicyWouldAccept')) is not None)
                if valid:
                    valid_samples.append(sample)
                else:
                    add('source_time_probe_samples_invalid', 'A text sample is malformed or outside its fixed schema.')

            valid_hooks = []
            for hook in hooks:
                valid = isinstance(hook, dict)
                if valid:
                    ordinal, message_ordinal = hook.get('ordinal'), hook.get('messageOrdinal')
                    valid = (type(ordinal) is int and 1 <= ordinal <= 16 and
                             (message_ordinal is None or (type(message_ordinal) is int and message_ordinal >= 1)) and
                             type(hook.get('round')) is int and hook['round'] >= 0 and
                             type(hook.get('receiverGeneration')) is int and hook['receiverGeneration'] >= 0 and
                             hook.get('messageType') in (1, 3) and
                             flag(hook.get('selfSource')) is not None and
                             hook.get('path') in ('receive', 'outgoing') and
                             flag(hook.get('serverIDPresent')) is not None and
                             hook.get('correlationScope') in scope_values and
                             hook.get('actualGetterEncoding') in getter_encodings and
                             (hook.get('createdAt') is None or
                              (type(hook.get('createdAt')) in (int, float) and
                               math.isfinite(hook['createdAt']))) and
                             all(type(hook.get(key)) in (int, float) and math.isfinite(hook[key]) and hook[key] > 0
                                 for key in ('receivedAt', 'listeningSince')))
                if valid:
                    valid_hooks.append(hook)
                else:
                    add('source_time_probe_hooks_invalid', 'A hook sample is malformed or outside its fixed schema.')

            observed_abi = flag(probe.get('actualWrapABIObserved'))
            observed_prefilter = flag(probe.get('prefilteredCallbacksObserved'))
            if observed_abi is None or observed_prefilter is None:
                add('source_time_probe_capability_invalid',
                    'The source-time observation flags are missing or malformed.')
            elif bool(valid_hooks) != observed_abi or bool(valid_hooks) != observed_prefilter:
                add('source_time_probe_capability_invalid',
                    'The source-time observation flags do not match the bounded hook samples.')

            if active:
                add('source_time_sampling_active',
                    'Sampling is active in this snapshot; this alone does not prove page-switch persistence.')
            if valid_samples:
                add('source_time_text_samples_observed',
                    'Bounded text evidence is present; relationship values are local observations, not host-semantic verification.')
                if any(sample.get('relationship') == 'older_than_boundary' for sample in valid_samples):
                    add('source_time_older_than_boundary_observed',
                        'At least one text sample predates the listening boundary; inspect the strict policy flag rather than treating arrival time as creation time.')
                if any(sample.get('relationship') == 'after_boundary' for sample in valid_samples):
                    add('source_time_after_boundary_observed',
                        'At least one text sample follows the listening boundary; this is evidence, not proof of the host clock unit.')
                if any(sample.get('relationship') == 'same_second' for sample in valid_samples):
                    add('source_time_same_second_observed',
                        'At least one text sample shares the boundary second; the strict policy result remains authoritative for this local run.')
                if any(sample.get('relationship') == 'future_or_different_units' for sample in valid_samples):
                    add('source_time_future_or_unit_mismatch_observed',
                        'A text creation value is ahead of the first callback; do not infer a clock unit or accept the source.')
                if any(sample.get('relationship') == 'missing_or_invalid' for sample in valid_samples):
                    add('source_time_missing_created_at_observed',
                        'A text sample has no valid creation value; do not substitute callback time.')
                if not active:
                    add('source_time_samples_retained_after_stop',
                        'The report retains bounded samples after sampling stopped; this is retention evidence, not a new callback.')
            matched = set()
            if valid_hooks:
                add('source_time_hook_metadata_observed',
                    'Bounded pre-readiness hook metadata is present; this is not complete ABI or source-time verification.')
                if any(hook.get('messageType') == 3 for hook in valid_hooks):
                    add('source_time_image_metadata_observed',
                        'A type-3 early callback was observed; image resource readiness is still not established.')
                if any(flag(hook.get('selfSource')) is True and flag(hook.get('serverIDPresent')) is False
                       for hook in valid_hooks):
                    add('source_time_self_without_server_id_observed',
                        'A self-source hook lacked a server ID; a later server-ID transition must be observed separately.')
                for sample in valid_samples:
                    ordinal = sample.get('hookMessageOrdinal')
                    if not (type(ordinal) is int and flag(sample.get('selfSource')) is True and
                            sample.get('relationship') == 'after_boundary' and
                            flag(sample.get('strictPolicyWouldAccept')) is True and
                            sample.get('createdAt') is not None):
                        continue
                    for hook in valid_hooks:
                        if (hook.get('messageOrdinal') == ordinal and hook.get('round') == sample.get('round') and
                                hook.get('receiverGeneration') == sample.get('receiverGeneration') and
                                hook.get('messageType') == 1 and flag(hook.get('selfSource')) is True and
                                hook.get('path') in ('receive', 'outgoing') and
                                hook.get('correlationScope') == 'local' and
                                flag(hook.get('serverIDPresent')) is False and
                                hook.get('actualGetterEncoding') != 'missing' and
                                hook.get('actualGetterEncoding') != 'incompatible'):
                            matched.add(ordinal)
                if matched:
                    add('source_time_self_local_id_readback_correlated',
                        'A self-source text delivery was correlated to its earlier local-ID hook by the '
                        'same in-process ID and anonymous ordinal. The delivery has a valid after-boundary '
                        'creation time and strict acceptance; this is correlation evidence, not complete '
                        'host-semantic certification.')
            delivered_ordinals = {sample.get('hookMessageOrdinal') for sample in valid_samples
                                  if flag(sample.get('selfSource')) is True and
                                  type(sample.get('hookMessageOrdinal')) is int}
            if delivered_ordinals - matched:
                add('source_time_self_local_id_correlation_incomplete',
                    'A self-source delivery carried a hook ordinal but no complete matching local-ID '
                    'hook with the required round, generation, type, getter and boundary evidence.')
            if valid_hooks and any(hook.get('messageType') == 3 for hook in valid_hooks) and \
                    flag(probe.get('imageReadinessObserved')) is not True:
                add('source_time_image_readiness_unobserved',
                    'Image metadata was observed, but the passive image-readiness evidence is absent.')
    appmsg = receiver.get('appMessageProbe')
    if appmsg is not None:
        failure_states = {'empty_content', 'content_unavailable', 'too_large', 'too_complex',
                          'unsupported_structure', 'sender_prefix_mismatch', 'unsafe_xml',
                          'invalid_xml', 'ambiguous_fields', 'invalid_subtype'}
        presence_keys = ('hasTitle', 'hasURL', 'hasAttachment', 'hasAttachmentID',
                         'hasFileExtension', 'hasTotalLength')
        if not isinstance(appmsg, dict) or type(appmsg.get('schema')) is not int or appmsg['schema'] != 1:
            add('app_message_probe_invalid', 'Unsupported app-message structural probe schema.')
        elif flag(appmsg.get('observerOnly')) is not True or flag(appmsg.get('relayable')) is not False:
            add('app_message_probe_scope_invalid', 'App-message evidence is not marked as observer-only/non-relayable. Do not use it to submit messages.')
        else:
            samples = appmsg.get('samples')
            attempts, dropped = appmsg.get('attempts'), appmsg.get('dropped')
            valid = (isinstance(samples, list) and len(samples) <= 16 and
                     type(attempts) is int and 0 <= attempts <= 16 and len(samples) <= attempts and
                     type(dropped) is int and 0 <= dropped <= 2**64 - 1)
            kinds, states = set(), set()
            for sample in samples[:16] if isinstance(samples, list) else []:
                if not isinstance(sample, dict) or not isinstance(sample.get('state'), str):
                    valid = False
                    continue
                state = sample['state']
                if state == 'parsed':
                    subtype = sample.get('subtype')
                    if type(subtype) is not int or not 0 <= subtype <= 2**32 - 1:
                        valid = False
                        continue
                    kind = {5: 'link', 6: 'file'}.get(subtype, 'other')
                    if sample.get('kindHint') != kind or any(flag(sample.get(key)) is None for key in presence_keys):
                        valid = False
                        continue
                    kinds.add(kind)
                elif state not in failure_states or 'subtype' in sample or 'kindHint' in sample:
                    valid = False
                states.add(state)
            if not valid:
                add('app_message_probe_invalid', 'App-message samples or counters violate the bounded structural schema; no subtype classification is inferred.')
            else:
                if 'parsed' in states:
                    add('app_message_subtypes_observed', 'Selected type-49 callbacks yielded structural appmsg subtypes. Counts are callbacks, not unique messages; payload, media readiness and sending remain unverified.')
                if 'link' in kinds:
                    add('app_message_link_hint', 'An appmsg subtype-5 link candidate was observed. URL presence is not URL validation, preview, capture or relay support.')
                if 'file' in kinds:
                    add('app_message_file_hint', 'An appmsg subtype-6 file candidate was observed. Attachment fields do not prove that a local file exists or can be sent.')
                if 'other' in kinds:
                    add('app_message_other_subtype', 'An unimplemented appmsg subtype was observed; it must remain non-relayable.')
                if 'content_unavailable' in states:
                    add('app_message_content_unavailable', 'The declared content getter failed or returned nil/non-string. No KVC, ivar or alternate media getter fallback ran.')
                if states & (failure_states - {'content_unavailable'}):
                    add('app_message_parse_rejected', 'App-message XML was empty, unsupported, ambiguous, unsafe, malformed or over limits. No raw XML or parser error text is echoed.')
                if dropped:
                    add('app_message_probe_dropped', 'The per-arm app-message probe limit was reached; excess callbacks did not read XML.')
                if attempts and not samples:
                    add('app_message_no_stable_sample', 'App-message callbacks were reserved but no stable sample is present; queued or invalidated context is not proof of getter failure.')
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
                add('image_snapshot_ready', 'An owned image snapshot passed preparation. Verify actual preview manually; preparation or preview alone does not send an image.')
            preparation = receiver.get('imagePreparationCode')
            if type(preparation) is int and preparation == 3:
                add('image_storage_quota', 'Owned image storage reached its quota; existing plan images were not evicted.')
            if type(preparation) is int and preparation == 8:
                add('image_raster_unsupported', 'Native raster dimensions or animated image exceeded this static-snapshot capture contract.')

    image_send = report.get('imageSendPreparation')
    if image_send is not None:
        if not isinstance(image_send, dict) or type(image_send.get('schema')) is not int or image_send['schema'] != 1:
            add('image_send_contract_schema_invalid', 'Unsupported image send contract inspection schema.')
        elif any(image_send.get(key) is not False for key in ('imageSetterInvoked', 'serviceResolved', 'submissionAttempted', 'sendingEnabled')):
            add('image_send_contract_scope_invalid', 'This inspection is not marked as unsent/no-image-write; do not infer compatibility or delivery.')
        elif image_send.get('state') == 'contract_compatible_not_sent':
            if (image_send.get('constructorInvoked') is True and image_send.get('extensionGetterInvoked') is True and
                    image_send.get('wrapFieldsCompatible') is True and
                    (image_send.get('longSelectorCompatible') is True or image_send.get('originSelectorCompatible') is True)):
                add('image_send_contract_compatible', 'An unsent type-3 wrap and extension setter ABIs passed inspection. No image setter or send ran; image construction/data and delivery remain unverified.')
            else:
                add('image_send_contract_incomplete', 'Image contract report claims compatibility without all required inspection evidence.')
        elif image_send.get('state') == 'extension_getter_unavailable':
            add('image_extension_getter_missing', 'The evidence-named extension has no declared object getter. KVC/ivar fallback was not attempted; inspect the actual contract before adding one.')
        elif image_send.get('state') not in ('not_checked', None):
            add('image_send_contract_blocked', 'Image contract inspection stopped. Inspect fixed state and normalized method ABI fields; no image write or send was performed.')

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

    image_candidate = report.get('singleImageSendCandidate')
    if image_candidate is not None:
        if (not isinstance(image_candidate, dict) or type(image_candidate.get('schema')) is not int or
                image_candidate['schema'] != 1 or flag(image_candidate.get('batchSendingEnabled')) is not False or
                flag(image_candidate.get('submissionAttempted')) is None or flag(image_candidate.get('imageSetterInvoked')) is None):
            add('invalid_image_candidate', 'Unsupported or malformed single-image experiment diagnostics.')
        else:
            invoked = flag(image_candidate.get('submissionAttempted')) is True
            loaded = flag(image_candidate.get('imageSetterInvoked')) is True
            if loaded:
                add('image_setter_invoked', 'The native image setter ran or was attempted; host media writes are possible even if submission was later blocked. Do not retry or delete guessed host paths.')
            if invoked:
                add('image_host_invoked', 'A single-image host submission was attempted. Local/server IDs and status are not image-content or delivery proof.')
                add('image_delivery_uncertain', 'Check the single authorized target manually; no automatic retry is allowed.')
                if image_candidate.get('deliveryOutcome') != 'uncertain':
                    add('image_delivery_outcome_invalid', 'This experiment has no reliable delivery receipt and must not automatically claim confirmation.')
            else:
                add('image_not_submitted', 'No image submission call is recorded for this host session.')
            if image_candidate.get('observing') is True:
                add('image_observing', 'Bounded exact-local-ID observation is active; keep the app in the foreground or explicitly stop it. Stopping cannot retract submission.')
            if image_candidate.get('observationServiceCheckFailed') is True:
                add('image_observation_service_changed', 'Service ABI/identity changed during image observation; observation stopped without retry.')
            for key, code in (('lookupMisses', 'image_lookup_miss'), ('identityConflicts', 'image_identity_conflict')):
                value = image_candidate.get(key)
                if type(value) is int and value > 0:
                    add(code, 'Exact image identity observation has misses or conflicts; do not substitute another message or infer non-delivery.')
            if image_candidate.get('state') == 'blocked':
                add('image_experiment_blocked', 'The image experiment stopped. Inspect sanitized stage/service fields; retain its persistent reservation, including after native loading without submission.')

    image_history = report.get('singleImageExperimentHistory')
    if image_history is not None:
        if not isinstance(image_history, dict):
            add('invalid_image_history', 'The image experiment reservation summary is not an object.')
        elif flag(image_history.get('claimed')) is True:
            add('image_attempt_claimed', 'A persistent image source reservation exists, possibly from an earlier session. It survives restart and must not be retried.')
            if image_history.get('deliveryOutcome') != 'uncertain' or flag(image_history.get('automaticRetry')) is not False:
                add('image_claim_policy_invalid', 'The image reservation must preserve unknown delivery and no automatic retry.')

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


def compare_source_time_snapshots(before, after):
    """Compare two bounded snapshots from the same active source-time round."""
    result = []

    def add(code, message):
        result.append({'code': code, 'message': message})

    def flag(value):
        return bool(value) if type(value) in (bool, int) and value in (0, 1) else None

    def snapshot(report):
        if not isinstance(report, dict) or report.get('reportSchema') != 1:
            return None, None
        probe = report.get('sourceTimeProbe')
        receiver = report.get('receiveCandidate')
        if not isinstance(probe, dict) or probe.get('schema') != 1 or not isinstance(receiver, dict):
            return None, None
        return probe, receiver

    before_probe, before_receiver = snapshot(before)
    after_probe, after_receiver = snapshot(after)
    if before_probe is None or after_probe is None:
        add('source_time_pair_invalid', 'Both snapshots must contain a schema-1 source-time probe.')
        return result
    for label, probe in (('before', before_probe), ('after', after_probe)):
        if flag(probe.get('active')) is not True or probe.get('state') != 'sampling':
            add('source_time_pair_not_active', f'The {label} snapshot is not an active sampling snapshot.')
        if 'inactivePending' in probe and flag(probe.get('inactivePending')) is not False:
            add('source_time_pair_inactive_pending',
                f'The {label} snapshot still has an unresolved foreground-inactive grace period.')
    before_round = before_probe.get('round')
    after_round = after_probe.get('round')
    if type(before_round) is not int or before_round < 0 or type(after_round) is not int or after_round < 0:
        add('source_time_pair_round_invalid',
            'The sampling round is missing or malformed in one of the snapshots.')
    elif before_round != after_round:
        add('source_time_pair_round_changed', 'The snapshots do not belong to the same sampling round.')
    before_generation = before_receiver.get('receiverGeneration')
    after_generation = after_receiver.get('receiverGeneration')
    if type(before_generation) is not int or before_generation < 0 or \
            type(after_generation) is not int or after_generation < 0:
        add('source_time_pair_generation_invalid',
            'The receiver generation is missing or malformed in one of the snapshots.')
    elif before_generation != after_generation:
        add('source_time_pair_generation_changed', 'The receiver generation changed between snapshots.')
    if flag(before_receiver.get('armed')) is not True or flag(after_receiver.get('armed')) is not True:
        add('source_time_pair_receiver_not_armed', 'The receiver was not armed in both snapshots.')
    before_counters = before_receiver.get('counters', {})
    after_counters = after_receiver.get('counters', {})
    if not isinstance(before_counters, dict):
        before_counters = {}
    if not isinstance(after_counters, dict):
        after_counters = {}
    before_stops = before_counters.get('receiver_stopped', 0)
    after_stops = after_counters.get('receiver_stopped', 0)
    if type(before_stops) is not int or type(after_stops) is not int or after_stops > before_stops:
        add('source_time_pair_receiver_stopped', 'A receiver stop occurred between the paired snapshots.')
    if before_probe.get('state') == 'environment_blocked' or after_probe.get('state') == 'environment_blocked':
        add('source_time_pair_environment_blocked', 'An environment-blocked state appears in the pair.')
    before_samples = before_probe.get('samples')
    after_samples = after_probe.get('samples')
    before_hooks = before_probe.get('hookSamples')
    after_hooks = after_probe.get('hookSamples')
    if not all(isinstance(value, list) for value in (before_samples, after_samples, before_hooks, after_hooks)):
        add('source_time_pair_samples_invalid', 'The paired sample arrays are malformed.')
    else:
        if len(after_samples) < len(before_samples) or len(after_hooks) < len(before_hooks):
            add('source_time_pair_samples_lost', 'A later snapshot contains fewer bounded samples than the earlier one.')
        # The diagnostics arrays are rebuilt from internal copies. Compare the
        # bounded evidence fields, not private IDs or dictionary ordering.
        stable_keys = ('ordinal', 'messageOrdinal', 'hookMessageOrdinal', 'round', 'receiverGeneration',
                       'selfSource', 'createdAt', 'receivedAt', 'listeningSince', 'deliveredAt',
                       'deliveryClockRollback', 'relationship', 'strictPolicyWouldAccept')
        hook_keys = stable_keys + ('messageType', 'path', 'serverIDPresent', 'correlationScope',
                                   'actualGetterEncoding')

        def stable(rows, keys):
            return [{key: row.get(key) for key in keys} for row in rows if isinstance(row, dict)]

        if stable(after_samples[:len(before_samples)], stable_keys) != stable(before_samples, stable_keys) or \
                stable(after_hooks[:len(before_hooks)], hook_keys) != stable(before_hooks, hook_keys):
            add('source_time_pair_samples_changed', 'The earlier bounded samples were not retained in the later snapshot.')
    before_capture = before.get('sourceCapture', {}) if isinstance(before, dict) else {}
    after_capture = after.get('sourceCapture', {}) if isinstance(after, dict) else {}
    if not isinstance(before_capture, dict) or not isinstance(after_capture, dict) or \
            before_capture.get('state') != 'idle' or after_capture.get('state') != 'idle':
        add('source_time_pair_capture_not_idle', 'Manual capture is not idle in both snapshots.')
    before_image = before.get('imageSource', {}) if isinstance(before, dict) else {}
    after_image = after.get('imageSource', {}) if isinstance(after, dict) else {}
    before_candidate = before.get('receiveCandidate', {}) if isinstance(before, dict) else {}
    after_candidate = after.get('receiveCandidate', {}) if isinstance(after, dict) else {}
    image_read_counts = (
        before_image.get('reads') if isinstance(before_image, dict) else None,
        after_image.get('reads') if isinstance(after_image, dict) else None,
        before_candidate.get('imageReads') if isinstance(before_candidate, dict) else None,
        after_candidate.get('imageReads') if isinstance(after_candidate, dict) else None,
    )
    if not all(type(value) is int and value >= 0 for value in image_read_counts) or \
            before_image.get('reads') != after_image.get('reads') or \
            before_candidate.get('imageReads') != after_candidate.get('imageReads'):
        add('source_time_pair_image_reads_changed', 'Image-source reads changed during the paired observation.')
    before_sending = flag(before.get('sendingEnabled'))
    after_sending = flag(after.get('sendingEnabled'))
    if before_sending is not False or after_sending is not False:
        add('source_time_pair_sending_not_disabled', 'Sending must be explicitly disabled in both snapshots.')
    if not result:
        add('source_time_page_switch_pair_consistent',
            'Both snapshots remain active in the same round with no receiver stop, environment block, sample loss, capture, image read, or send activity. This is local lifecycle evidence, not host-semantic certification.')
    return result


def compare_source_time_stop_snapshots(before, after):
    """Compare an active snapshot with the later stopped snapshot of the same round."""
    result = []

    def add(code, message):
        result.append({'code': code, 'message': message})

    def flag(value):
        return bool(value) if type(value) in (bool, int) and value in (0, 1) else None

    def snapshot(report):
        if not isinstance(report, dict) or report.get('reportSchema') != 1:
            return None, None
        probe = report.get('sourceTimeProbe')
        receiver = report.get('receiveCandidate')
        if not isinstance(probe, dict) or probe.get('schema') != 1 or not isinstance(receiver, dict):
            return None, None
        return probe, receiver

    before_probe, before_receiver = snapshot(before)
    after_probe, after_receiver = snapshot(after)
    if before_probe is None or after_probe is None:
        add('source_time_stop_pair_invalid', 'Both snapshots must contain a schema-1 source-time probe.')
        return result
    if flag(before_probe.get('active')) is not True or before_probe.get('state') != 'sampling':
        add('source_time_stop_pair_before_not_active', 'The before snapshot is not active sampling.')
    if 'inactivePending' in before_probe and flag(before_probe.get('inactivePending')) is not False:
        add('source_time_stop_pair_before_inactive_pending',
            'The before snapshot still has an unresolved foreground-inactive grace period.')
    stopped_states = {'stopped', 'inactive', 'configuration_changed', 'account_invalidated',
                      'environment_blocked', 'receiver_stopped', 'clock_invalid',
                      'time_limit', 'sample_limit', 'context_unavailable'}
    after_state = after_probe.get('state')
    if flag(after_probe.get('active')) is not False or after_state not in stopped_states:
        add('source_time_stop_pair_after_not_stopped',
            'The after snapshot is not a recognized stopped or inactive state.')
    elif after_state != 'stopped':
        add('source_time_stop_pair_after_not_manual_stop',
            'The after snapshot did not end through the explicit manual stop action.')
    before_round = before_probe.get('round')
    after_round = after_probe.get('round')
    if type(before_round) is not int or before_round < 0 or type(after_round) is not int or after_round < 0:
        add('source_time_stop_pair_round_invalid',
            'The sampling round is missing or malformed in one of the snapshots.')
    elif before_round != after_round:
        add('source_time_stop_pair_round_changed',
            'The snapshots do not belong to the same sampling round.')
    before_armed = flag(before_receiver.get('armed'))
    after_armed = flag(after_receiver.get('armed'))
    if before_armed is not True:
        add('source_time_stop_pair_before_receiver_not_armed',
            'The receiver was not explicitly armed in the active snapshot.')
    if after_armed is not False:
        add('source_time_stop_pair_receiver_still_armed',
            'The receiver is not explicitly disarmed in the stopped snapshot.')
    before_generation = before_receiver.get('receiverGeneration')
    after_generation = after_receiver.get('receiverGeneration')
    if type(before_generation) is not int or before_generation < 0 or \
            type(after_generation) is not int or after_generation < 0:
        add('source_time_stop_pair_generation_invalid',
            'The receiver generation is missing or malformed in one of the snapshots.')
    elif after_generation <= before_generation:
        add('source_time_stop_pair_generation_not_advanced',
            'The receiver generation did not advance after the active snapshot.')
    if before_probe.get('listeningSince') is not None or after_probe.get('listeningSince') is not None:
        add('source_time_stop_pair_invalid',
            'Probe-level listeningSince is not part of the fixed report schema.')

    before_samples = before_probe.get('samples')
    after_samples = after_probe.get('samples')
    before_hooks = before_probe.get('hookSamples')
    after_hooks = after_probe.get('hookSamples')
    if not all(isinstance(value, list) for value in (before_samples, after_samples, before_hooks, after_hooks)):
        add('source_time_stop_pair_samples_invalid', 'The paired sample arrays are malformed.')
    else:
        if len(after_samples) < len(before_samples) or len(after_hooks) < len(before_hooks):
            add('source_time_stop_pair_samples_lost',
                'The stopped snapshot contains fewer bounded samples than the active one.')
        stable_keys = ('ordinal', 'messageOrdinal', 'hookMessageOrdinal', 'round', 'receiverGeneration',
                       'selfSource', 'createdAt', 'receivedAt', 'listeningSince', 'deliveredAt',
                       'deliveryClockRollback', 'relationship', 'strictPolicyWouldAccept')
        hook_keys = stable_keys + ('messageType', 'path', 'serverIDPresent', 'correlationScope',
                                   'actualGetterEncoding')

        def stable(rows, keys):
            return [{key: row.get(key) for key in keys} for row in rows if isinstance(row, dict)]

        if stable(after_samples[:len(before_samples)], stable_keys) != stable(before_samples, stable_keys) or \
                stable(after_hooks[:len(before_hooks)], hook_keys) != stable(before_hooks, hook_keys):
            add('source_time_stop_pair_samples_changed',
                'The stopped snapshot did not retain the earlier bounded samples unchanged.')

    before_capture = before.get('sourceCapture', {}) if isinstance(before, dict) else {}
    after_capture = after.get('sourceCapture', {}) if isinstance(after, dict) else {}
    if not isinstance(before_capture, dict) or not isinstance(after_capture, dict) or \
            before_capture.get('state') != 'idle' or after_capture.get('state') != 'idle':
        add('source_time_stop_pair_capture_not_idle', 'Manual capture is not idle in both snapshots.')
    before_image = before.get('imageSource', {}) if isinstance(before, dict) else {}
    after_image = after.get('imageSource', {}) if isinstance(after, dict) else {}
    before_candidate = before.get('receiveCandidate', {}) if isinstance(before, dict) else {}
    after_candidate = after.get('receiveCandidate', {}) if isinstance(after, dict) else {}
    image_read_counts = (
        before_image.get('reads') if isinstance(before_image, dict) else None,
        after_image.get('reads') if isinstance(after_image, dict) else None,
        before_candidate.get('imageReads') if isinstance(before_candidate, dict) else None,
        after_candidate.get('imageReads') if isinstance(after_candidate, dict) else None,
    )
    if not all(type(value) is int and value >= 0 for value in image_read_counts) or \
            before_image.get('reads') != after_image.get('reads') or \
            before_candidate.get('imageReads') != after_candidate.get('imageReads'):
        add('source_time_stop_pair_image_reads_changed',
            'Image-source reads changed during the stop observation.')
    before_sending = flag(before.get('sendingEnabled'))
    after_sending = flag(after.get('sendingEnabled'))
    if before_sending is not False or after_sending is not False:
        add('source_time_stop_pair_sending_not_disabled',
            'Sending must be explicitly disabled in both snapshots.')
    if not result:
        add('source_time_same_round_samples_retained_after_stop',
            'The stopped snapshot retains the active snapshot\'s bounded samples in the same round, '
            'with capture idle, image reads unchanged, sending disabled, and the receiver disarmed. '
            'This is local lifecycle and retention evidence, not host-semantic certification.')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', nargs='?', type=Path,
                        help='One diagnostic report to analyze')
    parser.add_argument('--pair', nargs=2, type=Path, metavar=('BEFORE', 'AFTER'),
                        help='Compare two active snapshots from the same source-time round')
    parser.add_argument('--stop-pair', nargs=2, type=Path, metavar=('ACTIVE', 'STOPPED'),
                        help='Compare an active snapshot with the later stopped snapshot of the same round')
    args = parser.parse_args()
    if sum(value is not None for value in (args.report, args.pair, args.stop_pair)) != 1:
        parser.error('Provide exactly one report, --pair BEFORE AFTER, or --stop-pair ACTIVE STOPPED')

    def load(path):
        try:
            if path.stat().st_size > 2 * 1024 * 1024:
                parser.error('Report exceeds the 2 MiB diagnostic limit')
            return json.loads(path.read_text(encoding='utf-8-sig'))
        except (OSError, ValueError, UnicodeError) as error:
            parser.error('Invalid JSON report: ' + type(error).__name__)

    if args.pair:
        before, after = (load(path) for path in args.pair)
        findings = compare_source_time_snapshots(before, after)
    elif args.stop_pair:
        before, after = (load(path) for path in args.stop_pair)
        findings = compare_source_time_stop_snapshots(before, after)
    else:
        findings = analyze(load(args.report))
    print(json.dumps(findings, indent=2, ensure_ascii=True))


if __name__ == '__main__':
    main()
