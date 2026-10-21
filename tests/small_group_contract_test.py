"""Bounded real-session source contracts, not phone forwarding verification."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SmallGroupContracts(unittest.TestCase):
    def text(self, path):
        return (ROOT / path).read_text(encoding='utf-8')

    def test_native_claim_precedes_host_allocation(self):
        text = self.text('Adapter/SRSmallGroupSession.m')
        action = text.split('- (void)submit:(NSDictionary *)delivery source:', 2)[2]
        self.assertLess(action.index('claimSmallGroupDelivery:'), action.index('self.hostFactory(source, allowed)'))
        self.assertLess(action.index('claimSmallGroupDelivery:'), action.index('submitRequest:request'))

    def test_no_synchronous_hop_to_main(self):
        text = self.text('Adapter/SRSmallGroupSession.m')
        self.assertIn('dispatch_async(dispatch_get_main_queue()', text)
        self.assertNotIn('dispatch_sync', text)
        ready = text.split('- (BOOL)cachedReady:', 2)[2].split('- (BOOL)environmentForAccount:', 1)[0]
        self.assertNotIn('currentAccount()', ready)
        self.assertNotIn('readyForAccount:', ready)

    def test_submission_requires_readback_not_merely_callback(self):
        text = self.text('Adapter/SRSmallGroupSession.m')
        predicate = text.split('static BOOL SRSmallSubmitted', 1)[1].split('@implementation SRSmallGroupSession', 1)[0]
        for marker in ('hostReturned', 'submissionAttempted', 'lookupAttempts', 'lookupMisses', 'identityConflicts',
                       'observationServiceCheckFailed', 'local_readback', 'materialValidated', 'imageSetterInvoked'):
            self.assertIn(marker, predicate)
        self.assertNotIn('completion(@"confirmed"', text)
        self.assertIn('generation == session.generation', text)

    def test_sql_scope_limits_and_restart_ledgers(self):
        text = self.text('Core/SRStore.m')
        self.assertIn('targets.count > 0 && targets.count <= 20', text)
        self.assertIn('CREATE TABLE IF NOT EXISTS small_group_runs', text)
        self.assertIn('CREATE TABLE IF NOT EXISTS native_attempt_claims', text)
        self.assertIn('delivery_id TEXT PRIMARY KEY REFERENCES deliveries(id)', text)
        self.assertNotIn('DELETE FROM native_attempt_claims', text)
        start = text.split('- (NSString *)startSmallGroupRule:', 1)[1].split('- (NSDictionary *)smallGroupRulePreview:', 1)[0]
        self.assertIn('replay:NO', start)

    def test_original_single_use_hosts_are_not_relaxed(self):
        for name in ('Text', 'Image'):
            text = self.text(f'Adapter/SRWeChat{name}SendHost.m')
            self.assertIn('if (self.consumed)', text)
            self.assertIn('one_attempt_per_launch', text)
            self.assertNotIn('self.consumed = NO', text)

    def test_native_settings_entry_receives_shared_lifecycle_owner(self):
        text = self.text('UI/SRPanel.m')
        self.assertIn('panel.smallGroupSession = self.smallGroupSession', text)
        self.assertIn('[self.smallGroupSession becameInactive]', text)
        self.assertIn('UIApplication.sharedApplication.idleTimerDisabled = self.smallGroupPreviousIdleTimer', text)
        self.assertIn('report[@"smallGroupExecution"]', text)
        self.assertIn('!entry.smallGroupSession.busy && !entry.smallGroupSession.usedNativeHost', text)

    def test_completion_pacing_handles_delayed_ui_calls(self):
        text = self.text('Core/SRRunner.m')
        result = text.split('- (void)recordDelivery:', 1)[1].split('- (BOOL)tick', 1)[0]
        self.assertIn('SRPacingSubmitted(&_pacing, _clock(), _random())', result)

    def test_test_actions_do_not_enable_large_rules_or_replay(self):
        text = self.text('UI/SRPlanScreens.m')
        self.assertIn('[rule[@"targetCount"] unsignedIntegerValue] <= 20', text)
        self.assertIn('startRule:rule[@"id"] account:self.account', text)
        self.assertIn('resumeRun:run[@"id"] account:self.account', text)
        self.assertNotIn('replay:YES', text)

    def test_foreground_progress_does_not_own_a_window_or_intercept_chat(self):
        text = self.text('UI/SRFloatingProgress.m')
        for forbidden in ('UIWindow alloc', 'makeKeyAndVisible', 'hitTest:', 'pointInside:', 'sendEvent:', 'swizzle'):
            self.assertNotIn(forbidden, text)
        self.assertIn('UIKeyboardWillChangeFrameNotification', text)
        self.assertIn('window.safeAreaInsets', text)
        self.assertIn('UIAccessibilityIsReduceMotionEnabled()', text)
        self.assertIn('UIPanGestureRecognizer', text)

    def test_progress_is_separate_from_optional_entry_and_account_gated(self):
        text = self.text('UI/SRPanel.m')
        progress = text.split('- (void)refreshFloatingProgress {', 1)[1].split('- (void)install {', 1)[0]
        self.assertIn('progressBelongsToCurrentAccount', progress)
        self.assertIn('UIApplicationStateActive', progress)
        self.assertNotIn('floatingEntryEnabled', progress)
        self.assertIn('togglePauseForCurrentAccount:', progress)


if __name__ == '__main__':
    unittest.main()
