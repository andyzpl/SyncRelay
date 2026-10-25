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

    def test_library_occupancy_is_not_projected_as_legacy_content(self):
        source = (ROOT / 'Core/SRRelayCoordinator.m').read_text(encoding='utf-8')
        store = (ROOT / 'Core/SRStore.m').read_text(encoding='utf-8')
        # Projected separately, and occupancy includes it.
        self.assertIn('self.libraryOccupancy = ', source)
        self.assertIn('_state.occupied = self.content != nil || self.libraryOccupancy != nil', source)
        self.assertNotIn('self.legacyRun = self.libraryOccupancy', source)
        self.assertNotIn('libraryOccupancy = self.legacyRun', source)
        # Capture refuses before the state gate, so it can never arm and fail later.
        update = source.split('- (BOOL)updateCapture:', 1)[1].split('- (BOOL)refreshForeground:', 1)[0]
        self.assertLess(update.index('if (self.libraryOccupancy)'), update.index('SROpsCaptureAllowed(_state)'))
        # The store keeps library runs out of the legacy projection and exposes
        # them only through their own account-scoped query.
        self.assertIn('NOT EXISTS(SELECT 1 FROM library_tasks t WHERE t.run_id=x.id)', store)
        self.assertIn('WHERE t.account=? AND x.state IN', store)


if __name__ == '__main__':
    unittest.main()
