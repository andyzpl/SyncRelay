"""Phase B UI wiring contracts; UIKit rendering still requires a device check."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PhaseBUIContracts(unittest.TestCase):
    def text(self, path):
        return (ROOT / path).read_text(encoding="utf-8")

    def test_operations_home_is_a_projection_only_entry(self):
        header = self.text("UI/SRPlanScreens.h")
        source = self.text("UI/SRPlanScreens.m")
        self.assertIn("SRCreateOperationsHome", header)
        self.assertIn('self.title = @"SyncRelay 运营"', source)
        self.assertIn('打开本页不会开始捕获、创建计划或发送', source)
        home = source.split("@interface SROperationsHomeScreen", 1)[1]
        self.assertNotIn("armForAccount:", home)
        self.assertNotIn("startRule:", home)
        self.assertNotIn("confirmForCurrentAccount:", home)

    def test_home_routes_to_existing_preview_and_plan_pages(self):
        source = self.text("UI/SRPlanScreens.m")
        home = source.split("@interface SROperationsHomeScreen", 1)[1]
        self.assertIn("SRCreateCapturePreview", home)
        self.assertIn("SRCreatePlanList", home)
        self.assertIn('section == 2 && path.row == 0', home)

    def test_capsule_has_open_and_menu_actions_without_owning_a_window(self):
        header = self.text("UI/SRFloatingProgress.h")
        source = self.text("UI/SRFloatingProgress.m")
        panel = self.text("UI/SRPanel.m")
        self.assertIn("openAction", header)
        self.assertIn("menuAction", header)
        self.assertIn("UITapGestureRecognizer", source)
        self.assertIn("menuButton", source)
        self.assertNotIn("UIWindow alloc", source)
        self.assertIn("openOperationsFromController", panel)
        self.assertIn("showOperationsMenu", panel)

    def test_cancel_menu_is_account_and_run_bound(self):
        session = self.text("Adapter/SRSmallGroupSession.h")
        panel = self.text("UI/SRPanel.m")
        self.assertIn("currentRunID", session)
        self.assertIn("NSString *run = self.smallGroupSession.currentRunID", panel)
        self.assertIn("cancelRun:run account:account", panel)
        self.assertIn("尚未尝试的目标将取消", panel)

    def test_capsule_keeps_three_phase_labels_and_unready_actions_closed(self):
        source = self.text("UI/SRFloatingProgress.m")
        panel = self.text("UI/SRPanel.m")
        for phase in ("running", "paused", "settling", "ready", "waiting"):
            self.assertIn(f'@"{phase}"', source + panel)
        self.assertIn('captureStatus[@"state"] isEqual:@"waiting"', panel)
        self.assertIn('self.capture.preview', panel)


if __name__ == "__main__":
    unittest.main()
