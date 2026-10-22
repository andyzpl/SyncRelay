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

    def test_library_native_target_links_store_assets_and_runs(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')
        commands = [shlex.split(line.strip()) for line in workflow.splitlines()
                    if line.strip().startswith('clang ')]
        commands = [command for command in commands if 'tests/library_test.m' in command]
        self.assertEqual(1, len(commands))
        self.assertTrue({'Core/SRStore.m', 'Core/SRConfiguration.m', 'Core/SRSourceMessage.m',
                         'Core/SRImageAssetStore.m', 'Core/SRPacing.c'} <= set(commands[0]))
        self.assertIn('-lsqlite3', commands[0])
        self.assertTrue(any(line.strip() == '"$RUNNER_TEMP/library-test"'
                            for line in workflow.splitlines()))

    def test_library_task_target_links_store_assets_and_runs(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')
        commands = [shlex.split(line.strip()) for line in workflow.splitlines()
                    if line.strip().startswith('clang ')]
        commands = [command for command in commands if 'tests/library_task_test.m' in command]
        self.assertEqual(1, len(commands))
        self.assertTrue({'Core/SRStore.m', 'Core/SRMediaAlertState.m', 'Core/SRConfiguration.m',
                         'Core/SRSourceMessage.m', 'Core/SRImageAssetStore.m',
                         'Core/SRMediaQuota.c', 'Core/SRPacing.c'} <= set(commands[0]))
        self.assertIn('-lsqlite3', commands[0])
        self.assertTrue(any(line.strip() == '"$RUNNER_TEMP/library-task-test"'
                            for line in workflow.splitlines()))

    def test_media_quota_targets_link_their_dependencies(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')
        commands = [shlex.split(line.strip()) for line in workflow.splitlines()
                    if line.strip().startswith('clang ')]
        quota = [command for command in commands if 'tests/media_quota_test.c' in command]
        self.assertEqual(1, len(quota))
        self.assertIn('Core/SRMediaQuota.c', quota[0])
        self.assertIn('-std=c11', quota[0])
        budget = [command for command in commands if 'tests/media_budget_test.m' in command]
        self.assertEqual(1, len(budget))
        self.assertTrue({'Core/SRMediaQuota.c', 'Core/SRMediaAlertState.m',
                         'Core/SRImageAssetStore.m', 'Core/SRStore.m'} <= set(budget[0]))
        self.assertIn('-lsqlite3', budget[0])
        for name in ('media-quota-test', 'media-budget-test'):
            self.assertTrue(any(line.strip() == f'"$RUNNER_TEMP/{name}"'
                                for line in workflow.splitlines()))
        # An asset-store target that forgets the budget core would fail to link,
        # and a store target that forgets the alert state would lose persistence.
        for command in commands:
            if 'Core/SRImageAssetStore.m' in command:
                self.assertIn('Core/SRMediaQuota.c', command)
            if 'Core/SRStore.m' in command:
                self.assertIn('Core/SRMediaAlertState.m', command)

    def test_all_native_targets_run_three_passes(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')
        self.assertIn('for pass in 1 2 3; do', workflow)
        loop = workflow.split('for pass in 1 2 3; do', 1)[1].split('done', 1)[0]
        binaries = [line.strip().strip('"').replace('$RUNNER_TEMP/', '')
                    for line in loop.splitlines() if line.strip()]
        self.assertTrue({'media-quota-test', 'media-budget-test', 'image-asset-test'} <= set(binaries))


if __name__ == '__main__':
    unittest.main()
