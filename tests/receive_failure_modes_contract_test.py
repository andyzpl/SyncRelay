"""Phase A failure-mode contracts for the receive path (P1/P2) and the source
capture round isolation (P3).

These are *source-contract* tests: they parse the Objective-C / C source as
text and assert the guard clauses that implement the required fail-closed and
round-isolation behavior. They do NOT execute the native code (no Apple
toolchain is available in this environment), so they verify that the intended
guards are present and ordered correctly in the source, not that the compiled
binary behaves. The complementary native ObjC tests live in tests/receive_test.m
and must be run under CI / on a macOS host.

Subject under test:
  Adapter/SRWeChatReceiver.m  (P1 senderIDs fail-closed, P2 probe timing)
  Core/SRSourceCapture.m      (P3 round/generation isolation)
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RECEIVER = (ROOT / "Adapter/SRWeChatReceiver.m").read_text(encoding="utf-8")
CAPTURE = (ROOT / "Core/SRSourceCapture.m").read_text(encoding="utf-8")


def method_body(source, signature):
    """Return the text of a method implementation starting at `signature`
    (the `{` version, unique to the @implementation), up to the next top-level
    `- (…)` or `+ (…)` method boundary."""
    idx = source.index(signature)
    rest = source[idx + len(signature):]
    match = re.search(r"\n[-+]\s*\(", rest)
    return rest[:match.start()] if match else rest


class P1SenderIDsFailClosedTests(unittest.TestCase):
    def test_allowsSender_denies_when_filter_empty(self):
        # Fail-closed: an unset or empty sender filter must deny, never allow an
        # arbitrary sender just because the filter was not yet configured.
        identity = method_body(RECEIVER, "- (BOOL)allowsSenderIdentity:(NSString *)sender {")
        self.assertIn('self.senderIDs.count == 0', identity)
        self.assertIn('[self note:@"receive_sender_filtered"]; return NO;', identity)
        # The combined gate must delegate to the fail-closed identity gate.
        combined = method_body(RECEIVER, "- (BOOL)allowsSender:(NSString *)sender type:(NSNumber *)type {")
        self.assertIn('if (![self allowsSenderIdentity:sender]) return NO;', combined)
        # The old allow-all-on-nil form must be gone.
        self.assertNotIn('if (self.senderIDs && ![self.senderIDs containsObject:sender])', RECEIVER)

    def test_legacy_sourceGroup_arm_leaves_senderIDs_nil(self):
        # The low-level arm sets senderIDs = nil, so under P1 it now fails closed.
        # Any delivery test that arms via sourceGroup: must convert to a
        # configuration-based arm to populate senderIDs.
        body = method_body(RECEIVER,
                           "- (BOOL)armForAccount:(NSString *)account sourceGroup:(NSString *)group error:(NSError **)error {")
        self.assertIn("self.senderIDs = nil;", body)

    def test_configured_arm_populates_senderIDs(self):
        body = method_body(RECEIVER,
                           "- (BOOL)armForAccount:(NSString *)account configuration:(NSDictionary *)configuration newMessagesOnly:(BOOL)newMessagesOnly error:(NSError **)error {")
        self.assertIn('self.senderIDs = [NSSet setWithArray:[configuration[@"senders"] valueForKey:@"id"]];', body)
        self.assertIn('[self armForAccount:account sourceGroup:configuration[@"sourceGroup"][@"id"] error:error]', body)


class P2ProbeTimingTests(unittest.TestCase):
    def test_observeMessageType_requires_live_generation(self):
        # Stale / late callbacks must never append to the current diagnostic.
        body = method_body(RECEIVER,
                           "- (void)observeMessageType:(NSNumber *)type generation:(NSUInteger)generation {")
        self.assertLess(body.index("if (!self.armed || self.generation != generation) return;"),
                        body.index("observedMessageTypes"))

    def test_observeSession_records_probe_only_after_delivery_gate(self):
        body = method_body(RECEIVER,
                           "- (void)observeSession:(id)session wrap:(id)wrap timeEvidence:(NSDictionary *)evidence {")
        # probeAllowed is gated on the live generation, a non-empty sender
        # filter, and the sender being in that filter.
        self.assertIn(
            "probeAllowed = self.armed && self.generation == generation && self.senderIDs.count > 0 && [self.senderIDs containsObject:sender];",
            body,
        )
        # Every identity gate comes before the relay type gate: a wrong sender,
        # a missing server ID, failed time evidence and a changed account must
        # all reject the callback before anything is observed.
        identity = body.index("[self allowsSenderIdentity:sender]")
        server = body.index('[self note:@"receive_no_server_id"]')
        time_evidence = body.index("[self acceptsTimeEvidence:evidence wrap:wrap generation:generation]")
        account = body.index("[self currentAccountMatches:account]")
        relay_type = body.index("[self allowsSender:sender type:type]")
        census = body.index("[self observeMessageType:type generation:generation];")
        self.assertLess(identity, server)
        self.assertLess(server, time_evidence)
        self.assertLess(time_evidence, account)
        self.assertLess(account, relay_type)
        # The type census only records allow-listed relay types.
        self.assertLess(relay_type, census)

    def test_observeOutgoingManager_records_probe_only_when_allowed(self):
        body = method_body(RECEIVER,
                           "- (void)observeOutgoingManager:(id)manager session:(id)session wrap:(id)wrap timeEvidence:(NSDictionary *)evidence {")
        self.assertIn(
            "probeAllowed = self.armed && self.generation == generation && self.senderIDs.count > 0 && [self.senderIDs containsObject:account];",
            body,
        )
        identity = body.index("[self allowsSenderIdentity:account]")
        time_evidence = body.index("[self acceptsTimeEvidence:evidence wrap:wrap generation:generation]")
        account = body.index("[self currentAccountMatches:account]")
        relay_type = body.index("[self allowsSender:account type:type]")
        census = body.index("[self observeMessageType:type generation:generation];")
        self.assertLess(identity, time_evidence)
        self.assertLess(time_evidence, account)
        self.assertLess(account, relay_type)
        self.assertLess(relay_type, census)

    def test_account_change_blocks_the_callback_before_the_type_filter(self):
        # An account change must stop the capture even when the message type is
        # not relayable. Otherwise a capture armed for the previous account
        # would stay armed and keep answering with a stale identity.
        body = method_body(RECEIVER,
                           "- (void)observeSession:(id)session wrap:(id)wrap timeEvidence:(NSDictionary *)evidence {")
        account = body.index('[self note:@"account_changed"]; [self stop]; return;')
        self.assertLess(account, body.index("[self allowsSender:sender type:type]"))

    def test_type_49_probe_is_not_blocked_by_the_relay_type_filter(self):
        # The read-only type-49 XML probe is a diagnostic capability that is
        # independent of the relay type gate: type 49 is never relayable, but
        # it must still be observable. The probe therefore has to be scheduled
        # before the relay type filter, and the type census after it.
        for signature, sender in (
            ("- (void)observeSession:(id)session wrap:(id)wrap timeEvidence:(NSDictionary *)evidence {", "sender"),
            ("- (void)observeOutgoingManager:(id)manager session:(id)session wrap:(id)wrap timeEvidence:(NSDictionary *)evidence {", "account"),
        ):
            body = method_body(RECEIVER, signature)
            probe = body.index("[self observeAppMessageWrap:")
            relay_type = body.index("[self allowsSender:%s type:type]" % sender)
            census = body.index("[self observeMessageType:type generation:generation];")
            self.assertLess(probe, relay_type)
            self.assertLess(relay_type, census)
            # The probe stays behind the identity gates and the live round.
            self.assertLess(body.index("[self allowsSenderIdentity:%s]" % sender), probe)
            self.assertLess(body.index("[self currentAccountMatches:account]"), probe)

    def test_relay_type_gate_still_rejects_non_relayable_types(self):
        # Type 49 must keep failing the relay type gate: it never becomes a
        # source message, a preview or a type-census entry.
        body = method_body(RECEIVER, "- (BOOL)allowsSender:(NSString *)sender type:(NSNumber *)type {")
        self.assertIn('@"unsupported"', body)
        self.assertIn('[self note:@"receive_type_filtered"]; return NO;', body)
        self.assertNotIn('@"link"', body)
        self.assertNotIn('@"file"', body)


class P3SourceCaptureRoundIsolationTests(unittest.TestCase):
    def test_arm_bumps_generation_and_resets_counters(self):
        body = method_body(CAPTURE,
                           "- (BOOL)armForAccount:(NSString *)account configuration:(NSDictionary *)configuration error:(NSError **)error {")
        self.assertIn("self.generation++;", body)
        self.assertIn("self.offered = 0; self.rejected = 0; self.lastReason = 0; self.generation++;", body)

    def test_offer_envelope_ignored_when_not_waiting(self):
        # A late callback after cancel / confirm-failure / stop must not mutate
        # the current round's counters or lastReason.
        body = method_body(CAPTURE, "- (BOOL)offerEnvelope:(NSDictionary *)envelope {")
        self.assertLess(body.index("if (!self.waiting) return NO;"), body.index("self.offered++"))

    def test_diagnostics_exposes_generation(self):
        body = method_body(CAPTURE, "- (NSDictionary *)diagnostics {")
        self.assertIn('@"generation": @(self.generation)', body)


if __name__ == "__main__":
    unittest.main()
