"""Source-order safety guards only; these do not execute Objective-C ports."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CoordinatorSafetyContracts(unittest.TestCase):
    def test_fault_revokes_manual_lease_before_port_callbacks(self):
        source = (ROOT / 'Core/SRRelayCoordinator.m').read_text(encoding='utf-8')
        failure = source.split('- (BOOL)fail:', 1)[1].split('- (BOOL)performCommand:', 1)[0]
        revoke = 'self.manualRun = nil;'
        self.assertIn(revoke, failure)
        for callback in ('[self stopCapture]', '[self.execution pauseForAccount:'):
            self.assertLess(failure.index(revoke), failure.index(callback))


if __name__ == '__main__':
    unittest.main()
