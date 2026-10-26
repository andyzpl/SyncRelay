"""Source contracts for the receive_test type-selection fixture.

These are *source-contract* tests: they read tests/receive_test.m as text and
assert the intent of the shared drafts and of the image-capability negative
case. They do NOT execute the Objective-C code -- no Apple toolchain is
available in this environment -- so they cannot show that the native
assertions hold at runtime. The native target is executed by CI / on macOS.

Why the fixture is pinned here: the production SRConfiguration.emptyDraft()
selects both text and image, and -armForAccount:configuration:error: treats a
selected image type as a capability opt-in that requires prepareImage /
discardImage. A text-focused fixture that inherited the empty draft would be
rejected by that image gate instead of exercising the behaviour it names, which
is exactly what CI run 40277683819 reported first at receive_test.m:704.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEST_SOURCE = (ROOT / "tests/receive_test.m").read_text(encoding="utf-8")
PROBE_CASES = (ROOT / "tests/app_message_probe_cases.h").read_text(encoding="utf-8")


def c_function(source, signature):
    """Return the text of a C function/block starting at `signature`, up to the
    first closing brace that sits alone in the first column."""
    index = source.index(signature)
    rest = source[index:]
    end = rest.index("\n}\n")
    return rest[:end]


class TextDraftContractTests(unittest.TestCase):
    def test_shared_draft_selects_text_only(self):
        body = c_function(TEST_SOURCE, "static NSMutableDictionary *draft(void) {")
        self.assertIn('value[@"types"] = @[@"text"];', body)
        # The helper must not opt into the image capability on its own.
        self.assertNotIn('"image"', body)

    def test_sender_draft_inherits_the_text_selection(self):
        body = c_function(TEST_SOURCE, "static NSMutableDictionary *draftForSender(NSString *sender) {")
        self.assertIn("NSMutableDictionary *value = draft();", body)
        # A sender variant changes the sender filter only.
        self.assertNotIn("types", body)

    def test_probe_cases_keep_their_explicit_text_selection(self):
        # The type-49 probe cases build their own configuration; they narrowed
        # the types themselves, so the shared draft change must not be needed
        # there and must not have been "fixed" by widening them.
        self.assertIn('configuration[@"types"] = @[@"text"];', PROBE_CASES)


class ImageOptInContractTests(unittest.TestCase):
    def test_image_scenarios_select_image_explicitly(self):
        for signature in (
            "static void checkImageCapture(void) {",
            "static void checkSourceTimeEvidence(void) {",
        ):
            body = c_function(TEST_SOURCE, signature)
            self.assertIn('@[@"image"]', body, "%s must select image explicitly" % signature)

    def test_image_scenarios_keep_their_capability_blocks(self):
        for signature in (
            "static void checkImageCapture(void) {",
            "static void checkSourceTimeEvidence(void) {",
        ):
            body = c_function(TEST_SOURCE, signature)
            self.assertIn("prepareImage =", body)
            self.assertIn("discardImage =", body)

    def test_no_arm_relies_on_an_unstated_image_selection(self):
        # Every `configuration:` arm either uses a draft helper (text-only) or a
        # configuration this file narrowed explicitly; nothing arms straight
        # from the production empty draft.
        self.assertNotIn("emptyDraft] armForAccount", TEST_SOURCE)


class ImageCapabilityNegativeCaseTests(unittest.TestCase):
    def test_case_is_defined_and_called_from_main(self):
        self.assertIn("static void checkImageCapabilityGate(void) {", TEST_SOURCE)
        main = c_function(TEST_SOURCE, "int main(void) {")
        # Guard against silently shortening the native path.
        for call in (
            "checkDirectionEvidence();",
            "checkReflectedMessage();",
            "checkImageCapture();",
            "checkSourceTimeEvidence();",
            "checkAppMessageProbe();",
            "checkOutgoingTypeCensus();",
            "checkImageCapabilityGate();",
        ):
            self.assertIn(call, main)

    def test_case_asserts_the_specific_gate_and_the_disarmed_state(self):
        body = c_function(TEST_SOURCE, "static void checkImageCapabilityGate(void) {")
        # The rejection has to name the missing capability, so a version, ABI or
        # tap-ownership failure cannot satisfy the assertion by accident.
        self.assertIn('containsString:@"Image snapshot preparation is unavailable"', body)
        self.assertIn('error.domain isEqual:@"SyncRelay.Receiver"', body)
        self.assertIn('![receiver.diagnostics[@"armed"] boolValue]', body)
        # The rejected round must install no capture entry ...
        self.assertIn('[manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:wrap()]; pump();', body)
        # ... and the same receiver still arms, delivers and releases for a
        # text-only round.
        self.assertIn("armForAccount:account configuration:textOnly", body)
        self.assertIn("[receiver stop];", body)
        self.assertIn("SRWeChatReceiver *next = makeReceiver();", body)

    def test_case_uses_its_own_manager_class(self):
        # A dedicated manager class keeps the case independent of the receive
        # tap the main() fixtures already own.
        body = c_function(TEST_SOURCE, "static void checkImageCapabilityGate(void) {")
        self.assertIn("InheritedReceiveManager *manager", body)
        self.assertIn("InheritedReceiveManager.class", body)
        # The plain receive class must not be used here: it would collide with
        # the tap owner created earlier in main().
        self.assertIsNone(re.search(r"(?<!Inherited)ReceiveManager\.class", body))


if __name__ == "__main__":
    unittest.main()
