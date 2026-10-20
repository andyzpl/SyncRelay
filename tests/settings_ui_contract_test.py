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


if __name__ == '__main__':
    unittest.main()
