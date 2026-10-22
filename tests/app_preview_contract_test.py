"""Preview-only source contracts. UIKit/device behavior still needs real testing."""
from pathlib import Path
import unittest
from tools.diagnose_report import analyze

ROOT = Path(__file__).resolve().parents[1]


class AppPreviewContractTests(unittest.TestCase):
    def text(self, name):
        return (ROOT / name).read_text(encoding='utf-8')

    def test_preview_has_a_separate_explicit_arm(self):
        header = self.text('Adapter/SRWeChatReceiver.h')
        self.assertIn('armAppMessagePreviewForAccount:', header)
        source = self.text('Adapter/SRWeChatReceiver.m')
        self.assertIn('if (self.appPreviewKind) return;', source)
        self.assertIn('captureFields:previewKind != nil', source)
        self.assertIn('[sample removeObjectForKey:@"privateFields"]', source)
        self.assertIn('self.appPreviewKind = nil; self.appMessagePreview = nil;', source)

    def test_preview_does_not_enable_relay_types(self):
        config = self.text('Core/SRConfiguration.m')
        self.assertNotIn('@"link"', config)
        self.assertNotIn('@"file"', config)
        source = self.text('Adapter/SRWeChatReceiver.m')
        preview = source.split('if (!previewKind ||', 1)[1].split('- (void)observeOutgoingManager:', 1)[0]
        for forbidden in ('deliverMessage:', 'self.received(', 'createPlanFrom', 'GetMsg:', 'AddAppMsg:'):
            self.assertNotIn(forbidden, preview)

    def test_file_reads_only_a_declared_native_path_with_bounds(self):
        source = self.text('Adapter/SRWeChatFileSource.m')
        self.assertIn('SRReadDeclaredString(wrap, @"GetAppAttachmentPath"', source)
        self.assertIn('8ULL * 1024 * 1024', source)
        for marker in ('openat(', 'O_NOFOLLOW', 'O_NONBLOCK', 'S_ISREG(', 'before.st_nlink != after.st_nlink',
                       'st_mtimespec', 'st_ctimespec', 'CC_SHA256(', 'close(file)'):
            self.assertIn(marker, source)
        for forbidden in ('NSLog(', 'valueForKey:', 'NSFileHandle', 'dataWithContentsOfFile', 'NSURLSession',
                          'StartDownload', 'O_CREAT', 'unlink(', 'write(', 'AddAppMsg:'):
            self.assertNotIn(forbidden, source)
        self.assertLess(source.index('size > 8ULL'), source.index('GetAppAttachmentPath'))

    def test_native_getter_rechecks_context_before_file_io(self):
        source = self.text('Adapter/SRWeChatFileSource.m')
        getter = source.index('SRReadDeclaredString(')
        read = source.index('int directory = open(')
        self.assertIn('if (!allowed()) return nil', source[getter:read])
        receiver = self.text('Adapter/SRWeChatReceiver.m')
        self.assertIn('snapshotForWrap:wrap expectedSize:size home:NSHomeDirectory() allowed:', receiver)
        self.assertIn('m_nsContent", NULL) isEqual:content', receiver)

    def test_hard_links_keep_length_identity_and_unlink_guards(self):
        source = self.text('Adapter/SRWeChatFileSource.m')
        self.assertIn('before.st_nlink == 0', source)
        self.assertIn('before.st_nlink != after.st_nlink', source)
        self.assertIn('(unsigned long long)before.st_size != size', source)
        self.assertNotIn('before.st_nlink != 1', source)
        self.assertLess(source.index('before.st_nlink == 0'), source.index('NSMutableData *data'))

    def test_ui_does_not_open_urls_or_render_execute_files(self):
        source = self.text('UI/SRAppMessagePreviewScreen.m')
        self.assertIn('UIDataDetectorTypeNone', source)
        self.assertIn('UIApplicationWillResignActiveNotification', source)
        for forbidden in ('WKWebView', 'QLPreview', 'openURL:', 'URLSession', 'UIActivityViewController'):
            self.assertNotIn(forbidden, source)
        self.assertIn('[self.receiver stop]', source)

    def test_build_and_native_receive_test_include_new_sources(self):
        make = self.text('Makefile')
        workflow = self.text('.github/workflows/build.yml')
        for source in ('Adapter/SRWeChatFileSource.m', 'UI/SRAppMessagePreviewScreen.m'):
            self.assertIn(source, make)
        receive = next(line for line in workflow.splitlines() if 'clang ' in line and 'tests/receive_test.m' in line)
        self.assertIn('Adapter/SRWeChatFileSource.m', receive)
        self.assertIn('checkAppMessagePreview();', self.text('tests/receive_test.m'))

    def test_all_production_send_environments_exclude_preview_experiment(self):
        panel = self.text('UI/SRPanel.m')
        self.assertGreaterEqual(panel.count('!entry.receiver.appMessagePreviewActive'), 4)
        self.assertIn('if (self.receiver.appMessagePreviewActive)', panel.split('- (void)beginCapture {', 1)[1])

    def test_preview_survives_panel_close_but_clears_on_background(self):
        panel = self.text('UI/SRPanel.m')
        resigning = panel.split('- (void)resigningActive:', 1)[1].split('- (void)didEnterBackground:', 1)[0]
        background = panel.split('- (void)didEnterBackground:', 1)[1].split('@end', 1)[0]
        self.assertIn('if (!self.receiver.appMessagePreviewActive) [self.receiver stop];', resigning)
        self.assertIn('[self.receiver stop];', background)
        self.assertIn('UIApplicationDidEnterBackgroundNotification', panel)

    def test_redacted_triage_does_not_claim_relay_or_echo_private_fields(self):
        for kind, code in (('link', 'app_link_preview_ready'), ('file', 'app_file_snapshot_ready')):
            preview = {'schema': 1, 'state': 'ready', 'kind': kind, 'relayable': False,
                       'memoryOnly': True, 'planCreationEnabled': False, 'sendingEnabled': False,
                       'title': 'private title', 'path': '/private/secret'}
            result = analyze({'reportSchema': 1, 'receiveCandidate': {'appMessagePreview': preview}})
            self.assertIn(code, {row['code'] for row in result})
            self.assertNotIn('private title', str(result))
            self.assertNotIn('/private/secret', str(result))
            preview['sendingEnabled'] = True
            self.assertIn('app_preview_invalid', {row['code'] for row in analyze(
                {'reportSchema': 1, 'receiveCandidate': {'appMessagePreview': preview}})})
            for key in ('state', 'kind'):
                malformed = {**preview, key: {'untrusted': 'value'}}
                self.assertIn('app_preview_invalid', {row['code'] for row in analyze(
                    {'reportSchema': 1, 'receiveCandidate': {'appMessagePreview': malformed}})})

    def test_file_rejections_are_distinguished_without_exposing_sizes_or_paths(self):
        cases = {
            'file_length_mismatch': ('app_file_length_mismatch', 'sensitive length'),
            'file_unlinked': ('app_file_unlinked', 'private path'),
            'file_link_count_rejected': ('app_file_link_count_rejected', 'private path'),
            'file_non_regular': ('app_file_non_regular', 'private path'),
            'file_stat_unavailable': ('app_file_stat_unavailable', 'private path'),
            'file_size_unavailable': ('app_file_size_unavailable', 'private path'),
        }
        for state, (code, secret) in cases.items():
            preview = {'schema': 1, 'state': state, 'kind': 'file', 'relayable': False,
                       'memoryOnly': True, 'planCreationEnabled': False, 'sendingEnabled': False}
            result = analyze({'reportSchema': 1, 'receiveCandidate': {'appMessagePreview': preview}})
            self.assertIn(code, {row['code'] for row in result})
            self.assertNotIn(secret, str(result))


if __name__ == '__main__':
    unittest.main()
