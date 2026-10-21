"""Automatic rule progress contracts; not device delivery or UIKit verification."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AutomaticProgressContractTests(unittest.TestCase):
    def test_no_user_review_workflow(self):
        for name in ('Core/SRStore.h', 'Core/SRStore.m', 'UI/SRPlanScreens.m'):
            text = (ROOT / name).read_text(encoding='utf-8')
            self.assertNotIn('reviewDelivery:', text)
            self.assertNotIn('delivery_reviews', text)
            self.assertNotIn('confirmReview:', text)

    def test_dispatch_evidence_does_not_rewrite_delivery_as_success(self):
        store = (ROOT / 'Core/SRStore.m').read_text(encoding='utf-8')
        self.assertIn('NSString *storedState = submitted ? @"uncertain" : state;', store)
        self.assertIn('INSERT INTO submission_receipts', store)
        self.assertIn('submitted_at REAL NOT NULL', store)
        self.assertNotIn('DELETE FROM submission_receipts', store)
        self.assertNotIn('ALTER TABLE', store)

    def test_claims_only_unattempted_targets(self):
        store = (ROOT / 'Core/SRStore.m').read_text(encoding='utf-8')
        claim = store.split('- (NSDictionary *)claimNextForRun:', 1)[1].split('- (BOOL)recordResultForDelivery:', 1)[0]
        self.assertIn("state='pending' ORDER BY position", claim)
        self.assertNotIn("'submitting','uncertain'", claim)
        recovery = store.split('- (BOOL)recoverInterruptedRuns:', 1)[1].split('- (NSDictionary *)claimNextForRun:', 1)[0]
        self.assertIn("state='uncertain'", recovery)
        self.assertNotIn("state='pending'", recovery)

    def test_exception_page_is_not_a_submission_log(self):
        store = (ROOT / 'Core/SRStore.m').read_text(encoding='utf-8')
        exceptions = store.split('- (NSArray *)exceptionsForRun:', 1)[1].split('- (BOOL)claimTextExperiment:', 1)[0]
        self.assertIn('v.attempt_id IS NULL', exceptions)
        self.assertIn("d.state IN ('failed','cancelled')", exceptions)

    def test_runner_accepts_submitted_without_confirming_it(self):
        runner = (ROOT / 'Core/SRRunner.m').read_text(encoding='utf-8')
        self.assertIn('@[@"submitted", @"confirmed", @"failed", @"uncertain"]', runner)
        self.assertNotIn('state = @"confirmed"', runner)
        self.assertNotIn('reviewDelivery:', runner)


if __name__ == '__main__':
    unittest.main()
