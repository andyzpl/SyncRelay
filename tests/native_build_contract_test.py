"""Validate native test source manifests locally; this does not link or run ObjC."""
from collections import Counter
from pathlib import Path
import re
import shlex
import unittest

ROOT = Path(__file__).resolve().parents[1]


def native_execution_counts(workflow):
    """Read the fixed CI test script, not arbitrary shell or actual execution evidence."""
    marker = '      - name: Test production core on macOS\n        run: |\n'
    if workflow.count(marker) != 1:
        raise ValueError('expected exactly one native test step')
    script = workflow.split(marker, 1)[1].split('\n      - ', 1)[0]
    lines = [line.strip() for line in script.splitlines()]
    if not lines or lines[0] != 'set -euo pipefail':
        raise ValueError('native test failures must stop the step')
    targets, executions = {}, Counter()
    in_loop = loop_seen = False
    for line in lines[1:]:
        if not line or line.startswith('#'):
            continue
        if line == "python3 -m unittest discover -s tests -p '*_test.py'":
            continue
        if line == 'for pass in 1 2 3; do':
            if in_loop or loop_seen:
                raise ValueError('expected one non-nested three-pass loop')
            in_loop = loop_seen = True
            continue
        if line == 'done':
            if not in_loop:
                raise ValueError('unmatched native loop end')
            in_loop = False
            continue
        if line.startswith('clang '):
            command = shlex.split(line)
            sources = [arg for arg in command if re.fullmatch(r'tests/\w+_test\.[mc]', arg)]
            output = re.fullmatch(r'\$RUNNER_TEMP/([\w-]+)', command[-1])
            if (in_loop or loop_seen or command.count('-o') != 1 or command[-2] != '-o'
                    or len(sources) != 1 or output is None
                    or any(not re.fullmatch(r'[-\w./=,+]+', arg) for arg in command[:-1])):
                raise ValueError('unsupported native compile command')
            target = output.group(1)
            if target in targets:
                raise ValueError('duplicate native compile target')
            targets[target] = sources[0]
            continue
        invocation = re.fullmatch(r'"\$RUNNER_TEMP/([\w-]+)"', line)
        if invocation and invocation.group(1) in targets:
            executions[invocation.group(1)] += 3 if in_loop else 1
            continue
        raise ValueError('unsupported native test script command')
    if in_loop or not loop_seen:
        raise ValueError('expected one complete native test loop')
    return targets, executions


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

    def test_store_requires_fresh_or_current_schema_and_reports_after_validation(self):
        store = (ROOT / 'Core/SRStore.m').read_text(encoding='utf-8')
        setup = store.split('__block NSInteger version = 0;', 1)[1].split('id setup =', 1)[1] \
            .split('if (!setup) return nil;', 1)[0]
        enforced = store.split('id enforced = [self perform:^id{', 1)[1] \
            .split('if (!initialized || !enforced) return nil;', 1)[0]
        self.assertIn('version == 0 || version == 14', setup)
        self.assertIn('Unsupported database schema; this build requires a new schema 14 database', setup)
        self.assertNotIn('version <', setup)
        self.assertLess(setup.index('version == 0 || version == 14'),
                         setup.index('PRAGMA foreign_keys=ON'))
        self.assertNotIn('migrateRuleIntervalConstraint', store)
        self.assertNotIn('migrationDiagnostics', store)
        self.assertIn('if (version == 0) [self query:@"PRAGMA user_version=14"', store)
        self.assertIn('PRAGMA user_version', enforced)
        self.assertIn('[row[@"user_version"] integerValue] == 14', enforced)
        self.assertLess(enforced.index('[row[@"user_version"] integerValue] == 14'),
                        enforced.index('self.schemaVersion ='))
        self.assertNotIn('PRAGMA user_version=', enforced)
        header = (ROOT / 'Core/SRStore.h').read_text(encoding='utf-8')
        self.assertIn('@property(nonatomic, readonly) NSInteger schemaVersion;', header)

    def test_store_schema_gate_fixture_does_not_imply_legacy_migration(self):
        test = (ROOT / 'tests/store_test.m').read_text(encoding='utf-8')
        self.assertIn('for (NSNumber *unsupportedNumber in @[@1, @13, @15])', test)
        self.assertIn('SELECT count(*) FROM sqlite_master WHERE type=\'table\'', test)
        self.assertIn('PRAGMA user_version', test)
        self.assertNotIn('SRStore *seed = [[SRStore alloc] initWithPath:unsupportedPath', test)

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

    def assert_native_execution_coverage(self, workflow):
        targets, executions = native_execution_counts(workflow)
        sources = [f'tests/{path.name}' for path in (ROOT / 'tests').glob('*_test.[mc]')]
        self.assertCountEqual(sources, targets.values(), 'every native test must compile once')
        single_pass = {'tests/pacing_test.c', 'tests/operations_state_test.c'}
        expected = {target: 1 if source in single_pass else 3
                    for target, source in targets.items()}
        self.assertEqual(expected, executions, 'every compiled target must execute its exact pass count')

    def test_every_native_target_compiles_and_has_exact_execution_count(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')
        self.assert_native_execution_coverage(workflow)

    def test_native_execution_contract_rejects_missing_or_miscounted_execution(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')
        store = '            "$RUNNER_TEMP/store-test"\n'
        probe = '            "$RUNNER_TEMP/source-time-probe-test"\n'
        loop = '          for pass in 1 2 3; do\n'
        compile_store = next(line + '\n' for line in workflow.splitlines()
                             if 'tests/store_test.m' in line)
        missing_store = workflow.replace(store, '', 1)
        mutations = {
            'compiled but never executed': missing_store,
            'commented invocation': workflow.replace(store, store.replace('"$', '# "$'), 1),
            'moved out of three-pass loop': workflow.replace(probe, '', 1).replace(
                loop, '          "$RUNNER_TEMP/source-time-probe-test"\n' + loop, 1),
            'duplicate invocation': workflow.replace(store, store * 2, 1),
            'shortened loop': workflow.replace('for pass in 1 2 3; do', 'for pass in 1 2; do', 1),
            'unclosed loop': workflow.replace('          done\n', '', 1),
            'masked failure': workflow.replace(store, store.rstrip() + ' || true\n', 1),
            'echo instead of execution': workflow.replace(store, store.replace('"$', 'echo "$'), 1),
            'early successful exit': workflow.replace(loop, '          exit 0\n' + loop, 1),
            'uncompiled invocation': workflow.replace(store, store.replace('store-test', 'missing-test'), 1),
            'missing compilation': workflow.replace(compile_store, '', 1),
            'duplicate compilation': workflow.replace(compile_store, compile_store * 2, 1),
            'invocation only in another step': missing_store.replace(
                '      - name: Install build tools',
                '      - name: Unrelated step\n        run: |\n' + store
                + '      - name: Install build tools', 1),
        }
        for name, mutated in mutations.items():
            with self.subTest(name=name):
                self.assertNotEqual(workflow, mutated)
                with self.assertRaises((AssertionError, ValueError)):
                    self.assert_native_execution_coverage(mutated)

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
