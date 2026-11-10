"""UI source contracts, not UIKit/device interaction evidence.

The selected-row readback is executed by run_projection_test.m on macOS.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCREENS = (ROOT / "UI/SRPlanScreens.m").read_text(encoding="utf-8")
FLOW = SCREENS.split("@implementation SRCapturedForwardingScreen", 1)[1].split("@end", 1)[0]


class CapturedForwardingUIContracts(unittest.TestCase):
    def test_main_route_no_longer_reuses_technical_record_screen(self):
        route = SCREENS.split("UIViewController *SRCreateCapturedForwarding(", 1)[1].split("\n}", 1)[0]
        self.assertIn("SRCapturedForwardingScreen", route)
        self.assertIn("screen.generation = generation", route)
        self.assertIn("screen.selectedIndex = NSNotFound", route)
        self.assertNotIn("SRRecordScreen", route)
        for phrase in ("建立计划", "规则", "wxid", "宿主来源时间"):
            self.assertNotIn(phrase, FLOW)

    def test_select_and_inspect_never_confirm_or_send(self):
        tap = FLOW.split("didSelectRowAtIndexPath:", 1)[1].split("- (void)continuePressed", 1)[0]
        self.assertIn("self.selectedIndex = (NSUInteger)path.row", tap)
        self.assertIn("[self continuePressed]", tap)
        viewer = FLOW.split("accessoryButtonTappedForRowWithIndexPath:", 1)[1].split("didSelectRowAtIndexPath:", 1)[0]
        self.assertIn('row[@"targets"]', viewer)
        self.assertIn("[weakSelf contentIsCurrent]", viewer)
        for body in (tap, viewer):
            for forbidden in ("confirmForCurrentAccount:", "startRule:", "configurationForAccount:"):
                self.assertNotIn(forbidden, body)

    def test_only_explicit_continue_confirms_and_preserves_plan_on_retry(self):
        before, action = FLOW.split("- (void)continuePressed", 1)
        self.assertNotIn("confirmForCurrentAccount:", before)
        self.assertIn("self.navigationController.topViewController != self", action)
        self.assertIn("if (!self.confirmedPlan.length)", action)
        self.assertIn("self.confirmedPlan = [self.capture confirmForCurrentAccount:self.account generation:self.generation", action)
        self.assertLess(action.index("self.confirmedPlan ="), action.index("ruleCardsForPlan:self.confirmedPlan"))
        self.assertIn("confirmedCardForRow:selected atIndex:self.selectedIndex cards:cards", action)
        self.assertLess(action.index("if (!card)"), action.index("SRCreateRunDetail"))
        mismatch = action.split("if (!card)", 1)[1].split("\n    }", 1)[0]
        self.assertIn("self.selectedIndex = NSNotFound", mismatch)
        self.assertIn('card[@"id"], run[@"id"]', action)
        self.assertIn("[stack addObject:groups]; [stack addObject:detail]", action)
        self.assertNotIn("startRule:", FLOW)

    def test_generation_and_foreground_checked_for_every_intent(self):
        gate = FLOW.split("- (BOOL)contentIsCurrent", 1)[1].split("\n}", 1)[0]
        self.assertIn("applicationState == UIApplicationStateActive", gate)
        self.assertIn("[self verified]", gate)
        self.assertIn("previewSnapshotForAccount:self.account generation:self.generation", gate)
        self.assertIn("discardPreviewForAccount:self.account generation:self.generation", FLOW)
        self.assertIn("!self.confirmedPlan.length", FLOW)

    def test_content_hidden_on_inactive_and_unknown_type_rejected(self):
        self.assertIn("UIApplicationWillResignActiveNotification", FLOW)
        hidden = FLOW.split("- (void)hideContent", 1)[1].split("\n}", 1)[0]
        self.assertIn("self.source = nil; self.groups = @[]", hidden)
        self.assertIn('![self.source[@"type"] isEqual:@"text"] && ![self.source[@"type"] isEqual:@"image"]', FLOW)
        self.assertIn("if (self.problem) { self.source = nil; self.groups = @[]; }", FLOW)

    def test_existing_run_detail_owns_final_send_confirmation(self):
        detail = SCREENS.split("@implementation SRRunDetailScreen", 1)[1].split("@end", 1)[0]
        self.assertIn("[self.execution startRule:rule account:account error:&error]", detail)
        self.assertIn("pageIsStaleForBoundRun:self.runID currentRunID:currentRunID", detail)
        self.assertIn("if (self.replaced)", detail)
        self.assertIn("count > limit", detail)
        self.assertIn('card[@"initialUnlocked"]', detail)
        self.assertIn('card[@"accountOccupied"]', detail)

    def test_wechat_entry_opens_home_and_preserves_recovery_settings(self):
        panel = (ROOT / "UI/SRPanel.m").read_text(encoding="utf-8")
        entry = panel.split("entry.settingsEntry =", 1)[1]
        self.assertIn("[weakEntry openHomeFromController:controller]", entry)
        self.assertIn("[weakEntry openHomeFromController:host]", entry)
        route = panel.split("- (void)openHomeFromController:", 1)[1].split("\n}", 1)[0]
        self.assertIn("self.store && [self.identityReader connect:NULL]", route)
        self.assertIn("else [self openFromController:controller]", route)

    def test_docked_waiting_has_one_label_and_resets_surface_for_preview(self):
        capsule = (ROOT / "UI/SRFloatingProgress.m").read_text(encoding="utf-8")
        layout = capsule.split("- (void)layoutSubviews", 1)[1].split("- (void)showModel:", 1)[0]
        dock = layout.split("if (self.docked)", 1)[1].split("\n    }", 1)[0]
        self.assertIn("self.countLabel.hidden = YES", dock)
        self.assertIn('self.dockLabel.text =', dock)
        self.assertIn('self.actionButton.hidden = YES', dock)
        self.assertLess(layout.index("self.actionButton.backgroundColor = SRSettingsBackground()"),
                        layout.index('if ([self.model[@"phase"] isEqual:@"preview"])'))
        self.assertIn("[self updatePreviewControls]", layout)


if __name__ == "__main__":
    unittest.main()
