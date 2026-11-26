#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Python supplies finite deadlines, exit-status checks and durable per-command logs.
exec python3 - "$@" <<'PY'
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import traceback

root = Path.cwd()
evidence = Path(os.environ.get('SR_UI_EVIDENCE_DIR', root / '.build-cache/ios-ui-evidence')).resolve()
evidence.mkdir(parents=True, exist_ok=True)
(evidence / 'README.txt').write_text(
    'After-only: no reliable Before capture exists. Synthetic fixtures; no host/phone evidence.\n'
    'Both captures: portrait 390x844 points/pixels, light theme, scale 1; same app/window.\n'
    'Screenshots are supplementary; both entrypoint markers and clean runner exit are required.\n')
sequence = 0

def run(args, timeout=120):
    global sequence
    sequence += 1
    stem = evidence / f'{sequence:02d}-{Path(str(args[0])).name}'
    (stem.with_suffix('.command.txt')).write_text(' '.join(map(str, args)) + '\n')
    try:
        result = subprocess.run(list(map(str, args)), cwd=root, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        stem.with_suffix('.stdout.log').write_bytes(error.stdout or b'')
        stem.with_suffix('.stderr.log').write_bytes(error.stderr or b'')
        raise RuntimeError(f'command timed out after {timeout}s: {args[0]}') from error
    stem.with_suffix('.stdout.log').write_bytes(result.stdout)
    stem.with_suffix('.stderr.log').write_bytes(result.stderr)
    if result.returncode:
        raise RuntimeError(f'command exited {result.returncode}: {args[0]} (see {stem.name} logs)')
    return result.stdout.decode('utf-8', errors='replace')

udid = None
status = 1
try:
    sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).strip()
    runtime_info = json.loads(run(['xcrun', 'simctl', 'list', 'runtimes', '--json']))
    runtimes = [r for r in runtime_info['runtimes'] if r.get('isAvailable') and '.iOS-' in r['identifier']]
    runtime = max(runtimes, key=lambda r: tuple(map(int, r['version'].split('.'))))
    device_types = json.loads(run(['xcrun', 'simctl', 'list', 'devicetypes', '--json']))['devicetypes']
    # iPhone 14 fixes the UIKit viewport at 390x844 points; use an installed iOS runtime.
    device_type = next(t['identifier'] for t in device_types if t['name'] == 'iPhone 14')
    udid = None
    app = evidence / 'SRTestApp.app'
    app.mkdir(exist_ok=True)
    with (app / 'Info.plist').open('wb') as handle:
        plistlib.dump(dict(CFBundleIdentifier='local.syncrelay.uitests', CFBundleExecutable='SRTestApp',
            CFBundleName='SRTestApp', CFBundlePackageType='APPL', CFBundleVersion='1',
            CFBundleShortVersionString='1.0', MinimumOSVersion='15.0', LSRequiresIPhoneOS=True,
            UIDeviceFamily=[1], UILaunchScreen={}, UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait']), handle)
    sources = []
    for line in (root / 'Makefile').read_text().splitlines():
        match = re.match(r'^SyncRelay_FILES\s*\+?=\s*(.*)$', line)
        if match:
            sources.extend(p for p in match[1].split() if not p.startswith('Tweak/'))
    assert sources and not any(p.startswith('Tweak/') for p in sources)
    run(['xcrun', '--sdk', 'iphonesimulator', 'clang', '-target', 'x86_64-apple-ios15.0-simulator',
         '-isysroot', sdk, '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror', '-UNDEBUG', '-I.',
         *sources, 'tests/ios/SRTestApp.m', '-framework', 'Foundation', '-framework', 'UIKit',
         '-framework', 'ImageIO', '-framework', 'CoreGraphics', '-lsqlite3', '-o', app / 'SRTestApp'], timeout=300)
    run(['codesign', '--force', '--sign', '-', app])
    last_error = None
    for attempt in range(1, 4):
        udid = run(['xcrun', 'simctl', 'create', f'SyncRelay-UI-tests-{attempt}', device_type, runtime['identifier']]).strip()
        try:
            run(['xcrun', 'simctl', 'boot', udid], timeout=30)
            run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout=120)
            break
        except Exception as error:
            last_error = error
            print(f'simulator boot attempt {attempt} failed: {error}', file=sys.stderr)
            for command in [['xcrun', 'simctl', 'shutdown', udid], ['xcrun', 'simctl', 'delete', udid]]:
                try:
                    run(command, timeout=30)
                except Exception as cleanup_error:
                    print(f'boot recovery cleanup: {cleanup_error}', file=sys.stderr)
            udid = None
    else:
        raise RuntimeError('all simulator boot attempts failed') from last_error
    run(['xcrun', 'simctl', 'ui', udid, 'appearance', 'light'])
    run(['xcrun', 'simctl', 'status_bar', udid, 'override', '--time', '9:41', '--batteryState', 'charged', '--batteryLevel', '100'])
    run(['xcrun', 'simctl', 'install', udid, app])
    output = run(['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process', udid, 'local.syncrelay.uitests'], timeout=180)
    required = ['SR_TEST_ENTRYPOINT_PASS: SRFloatingProgressTests',
                'SR_TEST_ENTRYPOINT_PASS: SRNavigationTests', 'SR_UI_TESTS_PASS']
    assert all(marker in output.splitlines() for marker in required), 'missing test completion marker (assertion/crash is a failure)'
    container = Path(run(['xcrun', 'simctl', 'get_app_container', udid, 'local.syncrelay.uitests', 'data']).strip())
    for name in ['after-home-five-entrances.png', 'after-local-image-preview.png']:
        data = (container / 'Documents' / name).read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack('>II', data[16:24]) == (390, 844)
        (evidence / name).write_bytes(data)
    (evidence / 'result.txt').write_text('PASS: both UIKit entrypoints, explicit completion, two After captures\n')
    status = 0
except Exception:
    (evidence / 'result.txt').write_text('FAIL\n' + traceback.format_exc())
    traceback.print_exc()
finally:
    if udid:
        for command in [['xcrun', 'simctl', 'shutdown', udid], ['xcrun', 'simctl', 'delete', udid]]:
            try:
                run(command, timeout=30)
            except Exception as error:
                print(f'cleanup: {error}', file=sys.stderr)
    # Retain logs/screenshots, not the disposable executable bundle.
    if (evidence / 'SRTestApp.app').exists():
        shutil.rmtree(evidence / 'SRTestApp.app')
sys.exit(status)
PY
