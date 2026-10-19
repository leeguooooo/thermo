"""Refresh only a stopped, owned Thermo AI QA copy with newly built executables.
Does not install, launch an app, control UI or change production configuration.
Usage: python3 scripts/refresh-ai-ui-qa.py FIXTURE_ROOT BUILD_PRODUCTS [--json]
"""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys

BASE_ID = 'dev.thermo.aiqa'
NAMES = ['ThermoApp', 'thermo', 'thermo-helper']


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def inside(path, root):
    return path.resolve().is_relative_to(root)


def refresh(root, products):
    root = root.resolve(strict=True); products = products.resolve(strict=True)
    marker = root / '.thermo-ai-ui-fixture'
    if not root.name.startswith('thermo-ai-ui-') or not marker.is_file() or marker.is_symlink():
        raise ValueError('Expected a marked, owned thermo-ai-ui-* fixture root')
    app = root / 'Thermo AI QA.app'
    info_path = app / 'Contents/Info.plist'; runtime = app / 'Contents/MacOS/ThermoRuntime'
    destinations = [info_path, runtime, app / 'Contents/Helpers/thermo', app / 'Contents/Helpers/thermo-helper']
    if not app.is_dir() or not inside(app, root) or not all(inside(p, root) for p in destinations):
        raise ValueError('QA app and refresh targets must stay inside the marked fixture root')
    info = plistlib.loads(info_path.read_bytes())
    identifier = BASE_ID + '.' + hashlib.sha256(str(root).encode()).hexdigest()[:12]
    if info.get('CFBundleIdentifier') not in [BASE_ID, identifier] or info.get('CFBundleExecutable') != 'ThermoRuntime':
        raise ValueError('Unexpected QA application identity or executable')
    processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
    if any(Path(line.strip()).resolve() == runtime.resolve() for line in processes if line.strip()):
        raise ValueError('Close the owned QA app before refreshing')
    framework = app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle'
    if not framework.is_file() or not inside(framework, root):
        raise ValueError('Prepare the pinned Sparkle framework inside the owned QA app before refreshing')
    sources = {name: products / name for name in NAMES}
    if not all(path.is_file() for path in sources.values()):
        raise ValueError('Build products must contain ThermoApp, thermo and thermo-helper')
    source_hashes = {name: digest(path) for name, path in sources.items()}
    old_id = info['CFBundleIdentifier']
    shutil.copy2(sources['ThermoApp'], runtime)
    loads = subprocess.check_output(['otool', '-l', str(runtime)], text=True)
    if '@executable_path/../Frameworks' not in loads:
        subprocess.run(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(runtime)], check=True)
    for name in ['thermo', 'thermo-helper']:
        shutil.copy2(sources[name], app / 'Contents/Helpers' / name)
    info['CFBundleIdentifier'] = identifier
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    return {'schemaVersion': 1, 'complete': True, 'appPath': str(app), 'runtimePath': str(runtime),
            'bundleIdentifier': identifier, 'legacyIdentifierMigrated': old_id == BASE_ID,
            'sourceFilesSHA256': source_hashes, 'runtimeSHA256': digest(runtime),
            'launchesOrInstalls': False,
            'computerUseHint': 'Select this copy by appPath; do not select an older QA binding or observe it after exit.'}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture_root', type=Path); parser.add_argument('build_products', type=Path)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    try:
        result = refresh(args.fixture_root, args.build_products)
    except (ValueError, OSError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        print('QA refresh failed: ' + str(error), file=sys.stderr); return 1
    print(json.dumps(result, indent=2) if args.json else result['appPath'])
    return 0


if __name__ == '__main__':
    sys.exit(main())
