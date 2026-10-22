#!/usr/bin/env python3
"""Build an isolated macOS 27 public-API folding experiment and run core tests.

Building does not launch the app, fold icons, request permissions or install Thermo.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path, help='New directory for the isolated app and logs')
    parser.add_argument('--persistent-spacers', action='store_true', help='Keep inactive spacer items visible at one point for layout comparison')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    work = Path(tempfile.mkdtemp(prefix='thermo-fold-qa-'))
    manifest = {}

    def copy(source, destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        data = source.read_bytes()
        destination.write_bytes(data)
        manifest[str(source.relative_to(root))] = hashlib.sha256(data).hexdigest()

    try:
        for folder in ['Sources/MenuBarCore', 'Tests/MenuBarCoreTests']:
            for source in (root / folder).rglob('*'):
                if source.is_file():
                    copy(source, work / source.relative_to(root))
        copy(root / 'scripts/menu-bar-fold-check.swift', work / 'Sources/FoldCheck/main.swift')
        (work / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MenuBarFoldQA", platforms: [.macOS(.v13)], targets: [
 .target(name: "MenuBarCore"),
 .executableTarget(name: "FoldCheck", dependencies: ["MenuBarCore"], linkerSettings: [.linkedFramework("AppKit")]),
 .testTarget(name: "MenuBarCoreTests", dependencies: ["MenuBarCore"])
], swiftLanguageVersions: [.v5])
''')
        (output / 'input.json').write_text(json.dumps({'files': manifest, 'persistentSpacers': args.persistent_spacers}, indent=2))
        with (output / 'test.log').open('w') as log:
            result = subprocess.run(['swift', 'test', '--jobs', '2'], cwd=work, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f'Build/tests failed; see {output / "test.log"}')
        bindir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=work, text=True).strip())
        app = output / 'Thermo Menu Bar Fold Check.app'
        binary = app / 'Contents/MacOS/FoldCheck'
        binary.parent.mkdir(parents=True)
        shutil.copy2(bindir / 'FoldCheck', binary)
        identifier = 'dev.thermo.menubarqa.fold.' + uuid.uuid4().hex
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier, 'CFBundleExecutable': binary.name,
            'CFBundleName': 'Thermo Menu Bar Fold Check', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1', 'LSMinimumSystemVersion': '27.0', 'NSHighResolutionCapable': True,
            'ThermoMenuBarPersistentSpacers': args.persistent_spacers,
        }))
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        print(json.dumps({'app': str(app), 'bundle': identifier, 'tests': str(output / 'test.log'),
                          'inputs': str(output / 'input.json')}, indent=2))
    finally:
        shutil.rmtree(work)


if __name__ == '__main__':
    main()
