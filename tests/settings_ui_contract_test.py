"""Source-level UI contracts only; these do not validate UIKit rendering."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SettingsUIContractTests(unittest.TestCase):
    def test_save_uses_settings_language_without_renaming_internal_events(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        self.assertIn('initWithTitle:@"\u4fdd\u5b58" style:UIBarButtonItemStyleDone', panel)
        self.assertIn('record:@"draft_saved"', panel)
        self.assertIn('record:@"draft_save_failed"', panel)
        sources = [*sorted((ROOT / 'UI').glob('*.m')), ROOT / 'Core/SRSourceCapture.m']
        for path in sources:
            literals = re.findall(r'@"(?:[^"\\]|\\.)*"', path.read_text(encoding='utf-8'))
            with self.subTest(source=path.name):
                self.assertFalse(any('\u8349\u7a3f' in literal for literal in literals))

    def test_all_plugin_navigation_modes_explicitly_use_opaque_background(self):
        style = (ROOT / 'UI/SRNativeStyle.h').read_text(encoding='utf-8')
        navigation = style.split('static inline void SRStyleSettingsNavigation(', 1)[1]
        # Enforce the override after either the copied-host or fallback appearance path.
        self.assertRegex(navigation, r'if \(!appearance\) \{[\s\S]*?\n    \}\n(?:    //[^\n]*\n)*    \[appearance configureWithOpaqueBackground\];')
        self.assertIn('[appearance configureWithOpaqueBackground];', navigation)
        self.assertIn('appearance.backgroundEffect = nil;', navigation)
        self.assertIn('appearance.backgroundImage = nil;', navigation)
        self.assertIn('appearance.backgroundColor = SRSettingsBackground();', navigation)
        self.assertIn('navigation.navigationBar.translucent = NO;', navigation)
        for mode in ('standardAppearance', 'scrollEdgeAppearance', 'compactAppearance', 'compactScrollEdgeAppearance'):
            self.assertRegex(navigation, rf'navigation\.navigationBar\.{mode} = (?:\[appearance copy\]|appearance);')
        self.assertNotIn('host.navigationBar.standardAppearance =', navigation)
        self.assertNotIn('[UINavigationBar appearance]', navigation)

    def test_single_text_idle_claim_survives_countdown_until_host_completion(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        experiment = panel.split('- (void)beginSingleTextSend {', 1)[1].split('- (UIAlertController *)textTestResult:', 1)[0]
        self.assertIn('UIApplication.sharedApplication.idleTimerDisabled = YES;', experiment)
        countdown = experiment.split('panel.textCountdown = NO;', 1)[1].split('[panel.textSendAdapter submitDelivery:', 1)[0]
        self.assertNotIn('[panel restoreTextIdleTimer]', countdown)
        self.assertIn('[panel restoreTextIdleTimer]; panel.singleTextSendEnabled = NO;', experiment)
        cancel = panel.split('- (void)cancelTextExperiment {', 1)[1].split('\n}', 1)[0]
        self.assertLess(cancel.index('self.textGeneration++'), cancel.index('[self.textSendHost stopObservation]'))
        self.assertIn('[self restoreTextIdleTimer]', cancel)
        self.assertIn('![panel.draft isEqual:configuration]', experiment)

    def test_service_preflight_precedes_countdown_and_persistent_claim(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        experiment = panel.split('- (void)beginSingleTextSend {', 1)[1].split('- (UIAlertController *)textTestResult:', 1)[0]
        self.assertLess(experiment.index('readyForAccount:account'), experiment.index('panel.textCountdown = YES'))
        countdown = experiment.split('panel.textCountdown = NO;', 1)[1]
        self.assertLess(countdown.index('readyForAccount:account'), countdown.index('claimTextExperiment:'))
        host = (ROOT / 'Adapter/SRWeChatTextSendHost.m').read_text(encoding='utf-8')
        preflight = host.split('- (BOOL)readyForAccount:', 1)[1].split('- (BOOL)matches:', 1)[0]
        self.assertIn('resolveManagerForPhase:@"preflight"', preflight)
        self.assertNotIn('SRHostCreateTextWrap(', preflight)
        self.assertNotIn('claimTextExperiment:', preflight)

    def test_grouping_defaults_to_100_and_keeps_200_advanced(self):
        panel = (ROOT / 'UI/SRPanel.m').read_text(encoding='utf-8')
        self.assertIn('NSUInteger size = 100;', panel)
        self.assertNotIn('chosen.count <= 100 ? 100 : 200', panel)
        self.assertIn('field.text = size.unsignedIntegerValue == 100 ? @"10" : @"0";', panel)
        self.assertIn('默认 100 群/条', panel)


if __name__ == '__main__':
    unittest.main()
