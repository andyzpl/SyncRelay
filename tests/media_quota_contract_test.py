"""Static contract checks for the shared media budget.

These read the production sources; they do not compile, link or execute C or
Objective-C, and passing here is not evidence that a native build or a device run
succeeded. They guard the numbers and the ordering that the native tests assume.
"""
import re
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
QUOTA_H = (ROOT / 'Core/SRMediaQuota.h').read_text(encoding='utf-8')
QUOTA_C = (ROOT / 'Core/SRMediaQuota.c').read_text(encoding='utf-8')
ALERT_M = (ROOT / 'Core/SRMediaAlertState.m').read_text(encoding='utf-8')
ASSETS_M = (ROOT / 'Core/SRImageAssetStore.m').read_text(encoding='utf-8')
STORE_M = (ROOT / 'Core/SRStore.m').read_text(encoding='utf-8')
WORKFLOW = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')


def body_of(source, signature, name):
    start = source.find(signature)
    if start < 0:
        raise AssertionError(f'{name}: signature not found')
    end = source.find('\n}\n', start)
    if end < 0:
        raise AssertionError(f'{name}: body not terminated')
    return source[start:end]


class MediaBudgetContract(unittest.TestCase):
    def assertContains(self, needle, source, label):
        self.assertTrue(needle in source, f'{label} missing: {needle!r}')

    def test_one_shared_budget_across_types_and_accounts(self):
        self.assertContains('#define SR_MEDIA_LIMIT_BYTES 268435456ULL', QUOTA_H, 'Header')
        self.assertContains('#define SR_MEDIA_SINGLE_FILE_LIMIT_BYTES (20ULL * 1024 * 1024)', QUOTA_H, 'Header')
        self.assertContains('#define SR_MEDIA_TEMPORARY_GRACE_SECONDS 300.0', QUOTA_H, 'Header')
        # The number lives in exactly one place, so no per-kind or per-account copy
        # can drift away from the contract.
        self.assertEqual([], [line for line in QUOTA_C.splitlines() if '268435456' in line])
        self.assertEqual(1, QUOTA_C.count('limit_bytes = SR_MEDIA_LIMIT_BYTES'))

    def test_thresholds_are_integer_ratios_not_rounded_percentages(self):
        body = body_of(QUOTA_C, 'static SRMediaLevel SRMediaLevelFor', 'level helper')
        self.assertContains('used * policy.warn_numerator >= limit * policy.warn_denominator', body, 'level')
        self.assertIsNone(re.search(r'\b(double|float)\b', QUOTA_C), 'no floating point math')
        self.assertContains('policy.warn_numerator = 4;', QUOTA_C, 'Policy')
        self.assertContains('policy.warn_denominator = 5;', QUOTA_C, 'Policy')
        self.assertContains('policy.reset_numerator = 3;', QUOTA_C, 'Policy')
        self.assertContains('policy.reset_denominator = 4;', QUOTA_C, 'Policy')
        # An invalid band is rejected, so a caller cannot silently disable hysteresis.
        self.assertContains('reset_numerator * policy.warn_denominator >=', QUOTA_C, 'Policy')

    def test_reservation_check_and_add_share_one_lock(self):
        body = body_of(QUOTA_C, 'SRMediaStatus SRMediaLedgerReserve(', 'reserve')
        self.assertEqual(1, body.count('pthread_mutex_lock(&ledger->lock)'))
        self.assertEqual(1, body.count('pthread_mutex_unlock(&ledger->lock)'))
        lock = body.index('pthread_mutex_lock(&ledger->lock)')
        unlock = body.index('pthread_mutex_unlock(&ledger->lock)')
        check = body.index('bytes > remaining')
        add = body.index('ledger->reserved_bytes += bytes')
        self.assertTrue(lock < check < add < unlock, 'check and add must be inside one lock')

    def test_reuse_consumes_no_budget_and_failures_report_shortfall(self):
        body = body_of(QUOTA_C, 'SRMediaStatus SRMediaLedgerReserve(', 'reserve')
        self.assertContains('if (!reuse_only) {', body, 'reserve')
        self.assertContains('reuse_only ? 0 : bytes', body, 'reserve')
        self.assertContains('*shortfall = bytes - remaining;', body, 'reserve')

    def test_quota_core_never_deletes_anything(self):
        for forbidden in ('unlink', 'remove(', 'rmdir', 'truncate', 'NSFileManager'):
            self.assertEqual(-1, QUOTA_C.find(forbidden), f'quota core must not delete: {forbidden}')

    def test_scan_failure_is_not_recorded_as_zero(self):
        body = body_of(QUOTA_C, 'SRMediaStatus SRMediaLedgerRecordScanFailure(', 'scan failure')
        self.assertContains('scan_valid = false', body, 'scan failure')
        self.assertNotIn('committed_bytes = 0', body)
        reserve = body_of(QUOTA_C, 'SRMediaStatus SRMediaLedgerReserve(', 'reserve')
        self.assertContains('SRMediaStatusScanUnavailable', reserve, 'reserve')

    def test_store_refuses_bytes_when_usage_is_unavailable(self):
        body = body_of(ASSETS_M, '- (NSNumber *)reserveBytes:', 'reserveBytes')
        self.assertContains('if (!reuse && ![self refreshLedger:', body, 'reserveBytes')
        self.assertContains('SRMediaStatusScanUnavailable', body, 'reserveBytes')
        self.assertContains('SRImageAssetErrorUsageUnavailable', ASSETS_M, 'Assets')

    def test_error_codes_stay_distinct(self):
        header = (ROOT / 'Core/SRImageAssetStore.h').read_text(encoding='utf-8')
        for name in ('QuotaExceeded = 3', 'WriteFailed = 4', 'SingleFileExceeded = 20',
                     'DeviceFull = 21', 'UsageUnavailable = 22'):
            self.assertContains(name, header, 'Error enum')
        self.assertContains('errno == ENOSPC || errno == EDQUOT', ASSETS_M, 'Write path')

    def test_pruning_is_reference_and_reservation_guarded(self):
        body = body_of(ASSETS_M, '- (void)pruneUnreferenced:', 'prune')
        self.assertContains('![references containsObject:token]', body, 'prune')
        self.assertContains('![live containsObject:token]', body, 'prune')
        self.assertContains('SRImageSnapshotExtension', body, 'prune')
        self.assertNotIn('directoryEnumerator', body)
        temps = body_of(ASSETS_M, '- (NSUInteger)pruneTemporaryFilesOlderThan:', 'prune temps')
        self.assertContains('SRImageTemporaryExtension', temps, 'prune temps')
        self.assertContains('[_liveTemporaryNames containsObject:name]', temps, 'prune temps')
        self.assertNotIn('SRImageSnapshotExtension', temps)

    def test_writes_are_atomic_through_a_temporary_name(self):
        body = body_of(ASSETS_M, '- (NSInteger)writeData:(NSData *)data temporary:(NSString *)temporary final:(NSString *)final {', 'write')
        self.assertContains('O_CREAT | O_EXCL | O_NOFOLLOW', body, 'write')
        self.assertContains('renameat(', body, 'write')
        self.assertContains('unlinkat(', body, 'write')

    def test_startup_reclaims_temps_only_with_verified_references(self):
        self.assertContains('pruneTemporaryFilesOlderThan:SR_MEDIA_TEMPORARY_GRACE_SECONDS', STORE_M, 'Store')
        self.assertContains('if ([retained isKindOfClass:NSSet.class]) {', STORE_M, 'Store')
        self.assertContains('[self.imageAssets pruneUnreferenced:retained];', STORE_M, 'Store')

    def test_alert_state_is_persisted_and_account_scoped(self):
        self.assertContains('mediaAlertPath', STORE_M, 'Store')
        self.assertContains('SRMediaAlertStep(raised, snapshot, policy)', STORE_M, 'Store')
        self.assertContains('SRMediaAlertFileName', STORE_M, 'Store')
        self.assertContains('claimMediaWarningForAccount:(NSString *)account policy:', STORE_M, 'Store')
        # The sidecar is keyed by an account digest, written atomically, 0600.
        self.assertContains('[SRImageAssetStore sha256ForData:data]', ALERT_M, 'Alert state')
        self.assertContains('state[@"accounts"][key] = @{@"raised"', ALERT_M, 'Alert state')
        self.assertContains('NSDataWritingAtomic', ALERT_M, 'Alert state')
        self.assertContains('NSFilePosixPermissions: @0600', ALERT_M, 'Alert state')

    def test_schema_version_guard_is_single_and_bounded(self):
        self.assertContains('version >= 0 && version <= 14', STORE_M, 'Store')
        self.assertEqual(['PRAGMA user_version=14'],
                         [line.strip().split('"')[1] for line in STORE_M.splitlines()
                          if 'PRAGMA user_version=' in line])

    def test_new_targets_are_built_and_run(self):
        self.assertContains('tests/media_quota_test.c', WORKFLOW, 'Workflow')
        self.assertContains('tests/media_budget_test.m', WORKFLOW, 'Workflow')
        self.assertContains('"$RUNNER_TEMP/media-quota-test"', WORKFLOW, 'Workflow')
        self.assertContains('"$RUNNER_TEMP/media-budget-test"', WORKFLOW, 'Workflow')

    def test_limits_are_not_duplicated_as_magic_numbers(self):
        self.assertNotRegex(ASSETS_M, r'20 \* 1024 \* 1024')
        self.assertNotRegex(ASSETS_M, r'256 \* 1024 \* 1024')
        self.assertNotRegex(ASSETS_M, r'268435456')
        self.assertGreaterEqual(len(re.findall(r'SR_MEDIA_SINGLE_FILE_LIMIT_BYTES', ASSETS_M)), 1)


if __name__ == '__main__':
    unittest.main()
