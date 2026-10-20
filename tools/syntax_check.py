"""Optional Windows check using an explicitly supplied SDK/libclang cache."""
import argparse
import json
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cache', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
cache = args.cache.resolve()
sys.path.insert(0, str(cache / 'python-tools'))
from clang import cindex

sdk = cache / 'syntax/iPhoneOS16.5.sdk'
resources = cache / 'python-tools/ziglang/lib/include'
index = cindex.Index.create()
results = []
for arch in ('arm64', 'arm64e'):
    flags = ['-target', f'{arch}-apple-ios15.0', '-isysroot', str(sdk),
             '-isystem', str(sdk / 'usr/include'), '-isystem', str(resources),
             '-isystem', str(sdk / 'usr/include/pthread'),
             '-F', str(sdk / 'System/Library/Frameworks'), '-I', str(root),
             '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror']
    for file in ('Core/SRStore.m', 'Core/SRConfiguration.m', 'Core/SRSelection.m', 'Core/SRGroupPlanner.m',
                 'Core/SRSourceMessage.m', 'Core/SRSourceCapture.m', 'Core/SRRunner.m',
                 'Adapter/SRRuntime.m', 'Adapter/SRWeChatReader.m', 'Adapter/SRWeChatReceiver.m', 'Adapter/SRWeChatSendProbe.m',
                 'Adapter/SRWeChatSettingsEntry.m', 'Core/SREntryPreferences.m',
                 'UI/SRPanel.m', 'UI/SRPlanScreens.m', 'UI/SRSettingsFallback.m',
                 'Tweak/SRBootstrap.m', 'tests/store_test.m', 'tests/adapter_test.m',
                 'tests/relay_pipeline_test.m', 'tests/group_planner_test.m',
                 'tests/receive_test.m', 'tests/plan_queries_test.m', 'tests/send_probe_test.m', 'tests/settings_entry_test.m'):
        unit = index.parse(str(root / file), args=flags)
        diagnostics = [str(d) for d in unit.diagnostics]
        passed = not any(d.severity >= cindex.Diagnostic.Warning for d in unit.diagnostics)
        results.append(dict(arch=arch, file=file, passed=passed, diagnostics=diagnostics))
        print(f'{"PASS" if passed else "FAIL"} {arch} {file}')
        for diagnostic in diagnostics:
            print(diagnostic)
output = root / '.build-cache'
output.mkdir(exist_ok=True)
(output / 'syntax-report.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
print('Syntax check only; no linking, package build or device behavior verified.')
sys.exit(0 if all(r['passed'] for r in results) else 1)
