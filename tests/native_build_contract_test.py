"""Validate native test source manifests locally; this does not link or run ObjC."""
from pathlib import Path
import shlex
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeBuildContracts(unittest.TestCase):
    def test_coordinator_native_target_links_state_and_diagnostics(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')
        commands = [shlex.split(line.strip()) for line in workflow.splitlines()
                    if line.strip().startswith('clang ')]
        commands = [command for command in commands if 'tests/relay_coordinator_test.m' in command]
        self.assertEqual(1, len(commands))
        self.assertTrue({'Core/SRRelayCoordinator.m', 'Core/SRRuntimeLog.m',
                         'Core/SROperationsState.c', 'Core/SRStore.m',
                         'Core/SRConfiguration.m', 'Core/SRSourceMessage.m',
                         'Core/SRImageAssetStore.m', 'Core/SRPacing.c'} <= set(commands[0]))
        self.assertIn('-lsqlite3', commands[0])
        self.assertTrue(any(line.strip() == '"$RUNNER_TEMP/relay-coordinator-test"'
                            for line in workflow.splitlines()))


if __name__ == '__main__':
    unittest.main()
