"""Source contracts for the source-time metadata carried by a captured snapshot.

These parse Objective-C source as text. They confirm the guards that keep the
two time stages separate, the round binding fail-closed, the metadata redacted
and the persisted snapshot JSON-only. They do NOT execute native code and do
NOT prove real-host time semantics: the complementary native behaviour tests
live in tests/receive_test.m, tests/source_time_probe_test.m and
tests/relay_pipeline_test.m.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CAPTURE = (ROOT / 'Core/SRSourceCapture.m').read_text(encoding='utf-8')
MESSAGE = (ROOT / 'Core/SRSourceMessage.m').read_text(encoding='utf-8')
PROBE = (ROOT / 'Adapter/SRSourceTimeProbe.m').read_text(encoding='utf-8')
SCREENS = (ROOT / 'UI/SRPlanScreens.m').read_text(encoding='utf-8')
PROJECTION = (ROOT / 'Core/SRRunProjection.m').read_text(encoding='utf-8')
PANEL = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')


def method_body(source, signature):
    idx = source.index(signature)
    rest = source[idx + len(signature):]
    match = re.search(r"\n[-+]\s*\(", rest)
    return rest[:match.start()] if match else rest


class AllowlistContracts(unittest.TestCase):
    def test_allowlist_is_numeric_only_and_rejects_booleans(self):
        self.assertIn('CFBooleanGetTypeID', MESSAGE)
        self.assertIn('isfinite(number)', MESSAGE)
        body = method_body(MESSAGE, '+ (NSDictionary *)allowlistedTimeEvidence:(NSDictionary *)evidence {')
        for leaked in ('correlationLocalID', 'listeningSince', 'privateXML', 'payload', 'm_nsContent',
                       'messageID', 'sender', 'group', 'account'):
            self.assertNotIn(leaked, body)
        # A missing value is omitted, never fabricated.
        self.assertIn('if (receivedAt) allowed[@"receivedAt"] = receivedAt;', body)
        self.assertIn('if (![evidence isKindOfClass:NSDictionary.class] || ![evidence[@"schema"] isEqual:@1]) return nil;', body)

    def test_receiver_semantics_are_not_redefined(self):
        # receivedAt is still the hook's first-observation time, produced once
        # per callback by the receiver. Capture must never restamp it.
        receiver = (ROOT / 'Adapter/SRWeChatReceiver.m').read_text(encoding='utf-8')
        self.assertIn('@"receivedAt": @(received)', receiver)
        self.assertIn('NSTimeInterval received = [self observationTime];', receiver)
        for source in (CAPTURE, MESSAGE):
            self.assertNotIn('capturedAt', source)
            self.assertNotIn('captured_at', source)


class CaptureTimeMetadataContracts(unittest.TestCase):
    def test_freeze_clock_is_read_once_at_acceptance(self):
        body = method_body(CAPTURE, '- (BOOL)offerEnvelope:(NSDictionary *)envelope evidence:(NSDictionary *)evidence {')
        self.assertEqual(body.count('[self freezeClock]'), 1)
        # Identity and round gates precede the freeze; the merge is frozen as one snapshot.
        self.assertLess(body.index('matchesEnvelope:'), body.index('[self freezeClock]'))
        self.assertIn('merged[@"sourceTime"]', body)
        self.assertIn('[SRSourceMessage frozenJSON:merged]', body)
        self.assertLess(body.index('self.captured = frozen;'), body.index('self.waiting = NO;'))

    def test_round_binding_never_compares_the_two_counters(self):
        bind = method_body(CAPTURE, '- (void)bindReceiverGeneration:(NSNumber *)generation {')
        self.assertIn('self.receiverRound =', bind)
        body = method_body(CAPTURE, '- (BOOL)offerEnvelope:(NSDictionary *)envelope evidence:(NSDictionary *)evidence {')
        self.assertIn('if (self.receiverRound && generation &&', body)
        self.assertIn('self.receiverRound.unsignedIntegerValue != generation.unsignedIntegerValue', body)
        # The capture generation is a different counter and must not take part.
        self.assertNotIn('self.generation != generation', body)
        self.assertNotIn('generation != self.generation', body)
        # A new arm starts unbound instead of inheriting a stale round.
        arm = method_body(CAPTURE, '- (BOOL)armForAccount:(NSString *)account configuration:(NSDictionary *)configuration error:(NSError **)error {')
        self.assertIn('self.receiverRound = nil;', arm)

    def test_metadata_is_versioned_numeric_and_json_safe(self):
        metadata = CAPTURE.split('static NSDictionary *SRSourceTimeMetadata(', 1)[1].split('\n}', 1)[0]
        self.assertIn('@"schema": @1', metadata)
        self.assertIn('@"unit": @"unix_seconds"', metadata)
        for key in ('receivedAt', 'previewFrozenAt', 'createdAt'):
            self.assertIn(f'@"{key}":', metadata)
            self.assertIn(f'@"{key}Status":', metadata)
        self.assertIn('@"createdAtSemanticsVerified": @NO', metadata)
        for leaked in ('correlationLocalID', 'listeningSince', 'payload', 'm_nsContent'):
            self.assertNotIn(leaked, metadata)
        self.assertIn('isfinite(value) && value > 0', CAPTURE)

    def test_unix_seconds_declaration_covers_only_the_two_local_times(self):
        # The host value keeps its own unverified unit: it must not be implied
        # to be Unix seconds, or any UI may silently convert it to a date.
        metadata = CAPTURE.split('static NSDictionary *SRSourceTimeMetadata(', 1)[1].split('\n}', 1)[0]
        self.assertIn('@"unit": @"unix_seconds"', metadata)
        self.assertIn('@"unitAppliesTo": @[@"receivedAt", @"previewFrozenAt"]', metadata)
        self.assertNotIn('@"unitAppliesTo": @[@"receivedAt", @"previewFrozenAt", @"createdAt"]', metadata)
        self.assertIn('@"createdAtUnit": @"unverified"', metadata)
        self.assertNotIn('@"createdAtUnit": @"unix_seconds"', metadata)
        # The unverified marker stays an explicit boolean literal, not @(expr).
        self.assertIn('@"createdAtSemanticsVerified": @NO', metadata)

    def test_diagnostics_report_shape_is_unchanged(self):
        body = method_body(CAPTURE, '- (NSDictionary *)diagnostics {')
        for key in ('state', 'generation', 'offered', 'rejected', 'lastReasonCode'):
            self.assertIn(f'@"{key}":', body)
        for added in ('receivedAt', 'previewFrozenAt', 'createdAt', 'sourceTime', 'account'):
            self.assertNotIn(f'@"{added}":', body)

    def test_no_schema_column_or_migration_is_added(self):
        store = (ROOT / 'Core/SRStore.m').read_text(encoding='utf-8')
        self.assertIn('PRAGMA user_version=14', store)
        for source in (CAPTURE, MESSAGE, store):
            self.assertNotIn('ALTER TABLE', source)
            self.assertNotIn('sourceTime', store)


class ProbeForwardingContracts(unittest.TestCase):
    def test_probe_forwards_allowlisted_evidence_without_sampling_side_effects(self):
        self.assertEqual(PROBE.count('self.legacyReceived('), 1)
        body = method_body(PROBE, '- (void)receiveMessage:(NSDictionary *)message evidence:(NSDictionary *)evidence {')
        # The single call site is the non-sampling branch: sampling only samples.
        self.assertIn('self.legacyReceived(message, [SRSourceMessage allowlistedTimeEvidence:evidence]);', body)
        self.assertIn('if (!self.listening) {', body)
        self.assertIn('self.lastProbeGeneration', body)
        for forbidden in ('SRSourceCapture', 'offerEnvelope:', 'createPlan'):
            self.assertNotIn(forbidden, PROBE)

    def test_panel_binds_receiver_round_after_a_successful_arm(self):
        begin = PANEL.split('- (void)beginCapture {', 1)[1].split('- (void)toggleSourceTimeProbe', 1)[0]
        self.assertIn('[self.capture bindReceiverGeneration:self.receiver.diagnostics[@"receiverGeneration"]];', begin)
        self.assertLess(begin.index('[self.receiver armForAccount:account configuration:snapshot error:&error]'),
                        begin.index('bindReceiverGeneration:'))
        self.assertIn('acceptCapturedMessage:message evidence:evidence', PANEL)


class PlanScreenRowContracts(unittest.TestCase):
    def test_time_rows_are_appended_after_the_content_entry(self):
        rows = method_body(SCREENS, '- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {')
        self.assertIn('section == 0 ? 8 :', rows)
        cell = method_body(SCREENS, '- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {')
        self.assertIn('@"消息内容（点开完整查看）",', cell)
        self.assertIn('@"插件首次观察时间"', cell)
        self.assertIn('@"抓取完成时间"', cell)
        self.assertIn('@"宿主来源时间原始值（未验证）"', cell)
        # Row 4 keeps the disclosure indicator that opens the text/image viewer.
        self.assertIn('else if (path.row == 4) {', cell)
        self.assertIn('else cell.detailTextLabel.text = SRSourceTimeText(source, path.row);', cell)
        select = method_body(SCREENS, '- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {')
        self.assertIn('if (path.row == 4) {', select)

    def test_host_created_at_is_never_rendered_as_a_date(self):
        # B-2 moved the formatting into Core/SRRunProjection so the operations
        # pages and the historical rows cannot drift apart. The semantics the
        # test guards are unchanged; the source that must satisfy them moved.
        local = SCREENS.split('static NSString *SRSourceTimeText(', 1)[1].split('static NSString *SRRunDescription(', 1)[0]
        host = PROJECTION.split('+ (NSString *)unverifiedHostTimeText:', 1)[1].split('\n}', 1)[0]
        # The two plugin-local observations are Unix seconds and may be dated.
        self.assertIn('"yyyy-MM-dd HH:mm:ss zzz"', PROJECTION)
        self.assertIn('NSTimeZone.localTimeZone', PROJECTION)
        # The host value is printed as a raw number, never converted.
        self.assertNotIn('dateWithTimeIntervalSince1970', host)
        self.assertNotIn('NSDate', host)
        self.assertIn('单位/语义未验证', host)
        self.assertIn('未记录 / 语义未验证', host)
        self.assertIn('if (row == 7) return [SRRunProjection hostTimeTextForEnvelope:envelope];', local)

    def test_missing_or_boolean_time_shows_an_explicit_unknown(self):
        helper = SCREENS.split('static NSString *SRSourceTimeText(', 1)[1].split('static NSString *SRRunDescription(', 1)[0]
        local = PROJECTION.split('static NSString *SRProjectionFormat', 1)[1].split('\n}', 1)[0]
        host = PROJECTION.split('+ (NSString *)unverifiedHostTimeText:', 1)[1].split('\n}', 1)[0]
        self.assertIn('CFBooleanGetTypeID', PROJECTION)
        self.assertIn('return missing;', local)
        self.assertIn('@"未记录"', PROJECTION)
        self.assertIn('@"未记录 / 语义未验证"', PROJECTION)
        # Nothing fabricates a time from the current clock.
        self.assertNotIn('NSDate.date', helper)
        self.assertNotIn('[NSDate date]', PROJECTION)
        self.assertNotIn('NSDate.date', local)
        self.assertNotIn('NSDate.date', host)
        # The minute-precision format is still the one historical rows use, now
        # declared once and reached through the projection.
        self.assertIn('@"yyyy-MM-dd HH:mm"', PROJECTION)
        self.assertIn('[SRRunProjection localDateTimeText:value]', SCREENS)


if __name__ == '__main__':
    unittest.main()
