"""Validate native test source manifests locally; this does not link or run ObjC."""
from pathlib import Path
import re
import shlex
import unittest

ROOT = Path(__file__).resolve().parents[1]


def perform_blocks(text):
    """Yield the body of every `perform:^id{ ... }` block in one source file."""
    for match in re.finditer(r'perform:\^id\{', text):
        depth, index = 1, match.end()
        while index < len(text) and depth:
            if text[index] == '{':
                depth += 1
            elif text[index] == '}':
                depth -= 1
            index += 1
        yield text[match.end():index]


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

    def test_no_perform_block_captures_the_caller_error_out_parameter(self):
        # A captured NSError ** is autoreleasing storage, so clang rejects it under
        # -Werror,-Wblock-capture-autoreleasing. The build fails on macOS only, so
        # this guard is what keeps the pattern from coming back unnoticed.
        pattern = re.compile(r'error:\s*&\s*error\b|error:\s*error\b|if\s*\(\s*error\s*\)|\*\s*error\s*=')
        for folder in ('Core', 'Adapter', 'UI'):
            for path in sorted((ROOT / folder).glob('*.m')):
                text = path.read_text(encoding='utf-8')
                for body in perform_blocks(text):
                    self.assertIsNone(pattern.search(body),
                                      f'{path.relative_to(ROOT)} captures the caller error in a perform block')

    def test_library_image_save_reports_material_error_after_the_transaction(self):
        text = (ROOT / 'Core/SRStore.m').read_text(encoding='utf-8')
        start = text.index('- (NSDictionary *)saveLibraryImageData:')
        end = text.index('\n- (NSString *)createLibraryItemForAccount:', start)
        method = text[start:end]
        # The material step reports into a block-local; the value travels to a
        # __block strong local, and the caller's pointer is written once, after
        # perform: returned, and only when no payload was produced.
        self.assertIn('__block NSError *assetError = nil;', method)
        self.assertIn('error:&materialError', method)
        self.assertIn('assetError = materialError;', method)
        # The database error is a local too, so precedence is decided after the
        # call instead of the asset error overwriting a failed COMMIT.
        self.assertIn('NSError *storeError = nil;', method)
        self.assertIn('transaction:YES error:&storeError]', method)
        self.assertLess(method.index('if (storeError && error) *error = storeError;'),
                        method.index('else if (assetError && error) *error = assetError;'))
        # Only bytes written by this call are tracked, set after the material step
        # and never on the reuse path, so a reused token is never deleted.
        self.assertIn('__block NSDictionary *created = nil;', method)
        self.assertLess(method.index('return reused;'), method.index('created = fresh;'))
        self.assertLess(method.index('error:&materialError'), method.index('created = fresh;'))
        self.assertEqual(1, method.count('discardPayload:'), 'cleanup must happen in exactly one place')
        self.assertLess(method.index('created = fresh;'), method.index('discardPayload:created'))
        # A stale row is only removed once its replacement bytes have landed, so a
        # refused write commits nothing even though perform: still says COMMIT.
        self.assertLess(method.index('error:&materialError'),
                        method.index('DELETE FROM media_assets'))
        self.assertIn("'message_library'", method)

    def test_commit_failure_injection_stays_in_the_native_test(self):
        # The deferred-foreign-key probe exists only in tests/library_test.m; no
        # production source may grow a switch that can fail COMMIT on demand.
        for path in sorted((ROOT / 'Core').glob('*.m')) + sorted((ROOT / 'Adapter').glob('*.m')) \
                + sorted((ROOT / 'UI').glob('*.m')):
            text = path.read_text(encoding='utf-8')
            self.assertNotIn('commit_probe', text, f'{path.relative_to(ROOT)} carries a fault injection hook')
            self.assertNotIn('fail_commit', text, f'{path.relative_to(ROOT)} carries a fault injection hook')
        test = (ROOT / 'tests/library_test.m').read_text(encoding='utf-8')
        self.assertIn('DEFERRABLE INITIALLY DEFERRED', test)
        self.assertIn('installCommitFault(path)', test)
        self.assertIn('removeCommitFault(path)', test)


if __name__ == '__main__':
    unittest.main()
