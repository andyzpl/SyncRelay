"""Offline UI contracts for run history and target-level projections."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HistoryUIContracts(unittest.TestCase):
    def test_history_opens_target_detail_not_exception_only(self):
        screen = (ROOT / "UI/SRPlanScreens.m").read_text(encoding="utf-8")
        self.assertIn("SRRecordRunTargets", screen)
        self.assertIn("targetDetailsForRun:self.identifier", screen)
        self.assertIn('title:@"转发详情 · 目标群"', screen)

    def test_image_history_uses_verified_snapshot_only(self):
        screen = (ROOT / "UI/SRPlanScreens.m").read_text(encoding="utf-8")
        self.assertIn("dataForPayload:source[@\"payload\"] source:source", screen)
        self.assertIn("图片消息", screen)
        self.assertIn("缩略图仅来自已保存并校验的本地快照", screen)
        self.assertNotIn("主动图片", screen)

    def test_status_copy_keeps_submitted_separate_from_delivery(self):
        screen = (ROOT / "UI/SRPlanScreens.m").read_text(encoding="utf-8")
        self.assertIn("已提交 · 未确认送达", screen)
        self.assertIn("已提交不等于已确认送达", screen)
        self.assertNotIn('submitted": @"已送达"', screen)

    def test_core_detail_queries_are_account_bound(self):
        store = (ROOT / "Core/SRStore.m").read_text(encoding="utf-8")
        self.assertIn("runDetailsForRun:(NSString *)run account:(NSString *)account", store)
        self.assertIn("targetDetailsForRun:(NSString *)run account:(NSString *)account", store)
        self.assertIn("x.id=? AND x.account=? AND p.account=?", store)
        self.assertIn("Run is unavailable for this account", store)


if __name__ == "__main__":
    unittest.main()
