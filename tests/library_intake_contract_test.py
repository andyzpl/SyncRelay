"""Contracts for the text-only message-library intake.

The behaviour (complete body, one entry per operation, identical text kept
apart, every other type refused, no task/run created) is executed by
tests/library_intake_test.m on macOS CI. This file only pins the invariants
that must hold in the source and the registration the build relies on.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class IntakeContracts(unittest.TestCase):
    def test_intake_is_text_only_and_never_degrades(self):
        source = read("Core/SRLibraryIntake.m")
        self.assertIn('[type isEqual:@"text"]', source)
        self.assertIn("SRLibraryIntakeUnsupportedType", source)
        self.assertEqual(source.count('kind:@"text"'), 1)
        self.assertNotIn('kind:@"image"', source)

    def test_payload_carries_the_body_only(self):
        source = read("Core/SRLibraryIntake.m")
        self.assertIn('NSDictionary *stored = @{@"text": text};', source)
        for forbidden in ('@"group"', '"sender"', '"messageID"', '"account"', "mediaReference"):
            self.assertNotIn(forbidden, source, forbidden)

    def test_one_operation_saves_once_and_binds_the_request(self):
        source = read("Core/SRLibraryIntake.m")
        self.assertIn("SRLibraryIntakeDuplicate", source)
        # A reused key with another account, type or body is refused.
        self.assertIn("SRLibraryIntakeConflictingRequest", source)
        self.assertIn("[record.account isEqual:account]", source)
        self.assertIn("[record.body isEqual:text]", source)
        # The key, not the body, is the identity.
        self.assertNotIn("objectForKey:body", source)
        # The query is account-bound too.
        self.assertIn("record != nil && [record.account isEqual:account]", source)

    def test_check_write_and_publish_share_one_critical_section(self):
        source = read("Core/SRLibraryIntake.m")
        body = source.split("- (NSString *)saveMessageOfType:", 1)[1]
        lock = body.index("@synchronized(self.lock) {")
        self.assertLess(lock, body.index("SRLibraryIntakeRecord *record = self.ledger[operationKey];"))
        self.assertLess(lock, body.index("createLibraryItemForAccount"))
        self.assertLess(lock, body.index("self.ledger[operationKey] = created;"))
        # Nothing is deleted afterwards to hide a losing write.
        self.assertNotIn("removeObjectForKey", source)

    def test_a_failed_write_publishes_nothing(self):
        source = read("Core/SRLibraryIntake.m")
        write = source.split("NSString *item = [store createLibraryItemForAccount", 1)[1]
        failure = write.split("self.ledger[operationKey] = created;", 1)[0]
        self.assertIn("SRLibraryIntakeWriteFailed", failure)
        self.assertNotIn("self.ledger[operationKey] = created;", failure)
        # Publishing happens only after the entry exists.
        self.assertLess(source.index("if (!item.length) {"), source.index("self.ledger[operationKey] = created;"))

    def test_intake_has_a_process_owner(self):
        header = read("Core/SRLibraryIntake.h")
        self.assertIn("+ (instancetype)intakeForStore:", header)
        source = read("Core/SRLibraryIntake.m")
        self.assertIn("intakeForStore:(SRStore *)store", source)
        self.assertIn("self.ledger", source)
        # One owner per store, not a fresh ledger per tap.
        self.assertIn("[SRLibraryIntakes() setObject:created forKey:key];", source)

    def test_intake_never_creates_tasks_or_sends(self):
        source = read("Core/SRLibraryIntake.m")
        for forbidden in ("library_tasks", "createLibraryTask", "startLibraryTask", "sqlite3",
                          "submitDelivery", "startRule", "saveLibraryImageData",
                          "claimNext", "deleteLibraryEntry"):
            self.assertNotIn(forbidden, source, forbidden)
        self.assertIn("createLibraryItemForAccount", source)

    def test_intake_time_is_the_process_intake_time(self):
        source = read("Core/SRLibraryIntake.m")
        self.assertIn("capturedAt = NSDate.date.timeIntervalSince1970;", source)
        header = read("Core/SRLibraryIntake.h")
        self.assertIn("never treated as a verified time", header)
        self.assertNotIn("m_uiCreateTime", source)

    def test_registration(self):
        makefile = read("Makefile")
        self.assertIn("Core/SRLibraryIntake.m", makefile)
        workflow = read(".github/workflows/build.yml")
        self.assertIn("tests/library_intake_test.m", workflow)
        self.assertIn('"$RUNNER_TEMP/library-intake-test"', workflow)
        syntax = read("tools/syntax_check.py")
        for unit in ("Core/SRLibraryIntake.m", "tests/library_intake_test.m"):
            self.assertIn(unit, syntax, unit)

    def test_library_page_is_still_read_only_in_this_build(self):
        """Forwarding is not wired yet, so the pages must not pretend it is."""
        screens = read("UI/SRLibraryScreens.m")
        self.assertIn("本页只读", screens)
        for forbidden in ("转发", "createLibraryTaskForAccount", "startLibraryTask",
                          "SRLibraryIntake"):
            self.assertNotIn(forbidden, screens, forbidden)

    def test_the_menu_adapter_is_installed_only_through_the_gated_build_hook(self):
        """The adapter is gated; the entry installs the build interposer only
        after resolving the four host classes, and no raw hooking API is used."""
        adapter = read("Adapter/SRMessageMenuHook.m")
        self.assertIn("SRMenuGateEncodingMismatch", adapter)
        self.assertIn("method_copyArgumentType", adapter)
        self.assertIn("method_copyReturnType", adapter)
        self.assertNotIn("method_getTypeEncoding", adapter)
        self.assertIn("SRMenuGateMethodMissing", adapter)
        # The adapter never writes to the library and never sends.
        for forbidden in ("sqlite3", "createLibraryItem", "submitDelivery", "startRule"):
            self.assertNotIn(forbidden, adapter, forbidden)
        for path in ("Adapter/SRWeChatReceiver.m", "Tweak/SRBootstrap.m", "UI/SRPanel.m",
                     "Adapter/SRMessageMenuHook.m"):
            self.assertNotIn("MSHookMessageEx", read(path), path)
        # The bootstrap never constructs the intake hook; only the settings entry
        # assembles it, together with the gated build interposer.
        bootstrap = read("Tweak/SRBootstrap.m")
        self.assertNotIn("initWithIntake:", bootstrap)
        self.assertNotIn("SRMessageMenuHook alloc", bootstrap)
        workflow = read(".github/workflows/build.yml")
        menu_target = [line for line in workflow.splitlines() if "message-menu-hook-test" in line and "clang" in line]
        self.assertTrue(menu_target, "menu hook test target missing")
        self.assertIn("Adapter/SRRuntime.m", menu_target[0])
        panel = read("UI/SRPanel.m")
        self.assertIn("SRMenuBuildHook alloc", panel)
        self.assertIn("[entry.libraryMenuBuildHook install:NULL]", panel)
        self.assertIn("NSClassFromString(@\"MMMenuController\")", panel)

    def test_menu_click_rechecks_an_independent_identity(self):
        header = read("Adapter/SRMessageMenuHook.h")
        source = read("Adapter/SRMessageMenuHook.m")
        self.assertIn("ownerToken", header)
        self.assertIn("@interface SRMenuCurrentIdentity", header)
        self.assertIn("handleSelection:(nullable id)item", header)
        self.assertIn("current:(nullable SRMenuCurrentIdentity *)current", header)
        self.assertIn("initWithAccount:source.account", source)
        self.assertIn("ownerToken:source.ownerToken", source)
        self.assertIn("current.ownerToken.length", source)
        self.assertIn("context.ownerToken isEqual:current.ownerToken", source)
        self.assertIn("context.messageIdentity isEqual:current.messageIdentity", source)
        self.assertIn("self.currentAccount", source)
        self.assertIn("self.accountActive", source)
        # The old two-argument identity check must not remain as a bypass.
        self.assertNotIn("expectedGeneration:", header + source)
        self.assertNotIn("currentAccountValue:", header + source)

    def test_menu_ownership_survives_generation_but_old_items_are_stale(self):
        source = read("Adapter/SRMessageMenuHook.m")
        self.assertIn("NSPointerFunctionsOpaquePersonality", source)
        self.assertIn("activeGeneration", source)
        self.assertIn("activeItem", source)
        self.assertIn("context.generation isEqual:self.activeGeneration", source)
        self.assertIn("if (![self.contexts objectForKey:item])", source)
        self.assertIn("hasOtherOwn", source)
        self.assertIn("if (!self.enabled || !self.enabled()) return original;", source)
        # Intake is the only operation ledger; the adapter cannot hide a
        # failed write behind a second delivered set.
        self.assertNotIn("delivered", source)
        self.assertNotIn("appendedGeneration", source)

    def test_display_switch_is_independent_and_defaults_off(self):
        preferences = read("Core/SREntryPreferences.m")
        header = read("Core/SREntryPreferences.h")
        self.assertIn("libraryMenuEntryEnabled", header)
        self.assertIn("SRLibraryMenuEntryKey", preferences)
        self.assertIn('return [value isKindOfClass:NSNumber.class] && [value boolValue];', preferences)
        # The preference is deliberately backend-only until a verified host
        # menu hook is installed; no visible switch may pretend the entry works.
        self.assertNotIn("libraryMenuEntryChanged:", read("UI/SRPanel.m"))


if __name__ == "__main__":
    unittest.main()
