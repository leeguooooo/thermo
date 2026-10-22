#!/usr/bin/env python3
"""Build an isolated menu-bar preview and run policy/lifecycle tests.

No Thermo installation, production preferences or helper is changed. This only
builds; run the resulting app normally for UI review. Its explicit --self-test
briefly hides a separate disposable fixture using the private interface. It can
affect system extras, so it is never run automatically by this builder.
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
    parser.add_argument('--output', type=Path, required=True, help='New directory for app, logs and manifest')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    work = Path(tempfile.mkdtemp(prefix='thermo-menubar-qa-'))
    manifest = {}

    def copy(source, destination, transform=None):
        data = source.read_bytes()
        if transform:
            data = transform(data)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        manifest[str(source.relative_to(root))] = hashlib.sha256(data).hexdigest()

    try:
        for folder in ['Sources/MenuBarCore', 'Sources/CMenuBar', 'Sources/ThermoL10n', 'Tests/MenuBarCoreTests']:
            for source in (root / folder).rglob('*'):
                if source.is_file():
                    copy(source, work / source.relative_to(root))
        preview = work / 'Sources/MenuBarPreview'
        for name in ['MenuBarManager.swift', 'MenuBarManagerPanel.swift']:
            copy(root / 'Sources/ThermoApp' / name, preview / name)
        # The preview uses actual Theme tokens; unrelated shared view components
        # depend on the rest of Thermo, and are outside this isolated build.
        copy(root / 'Sources/ThermoApp/Theme.swift', preview / 'Theme.swift',
             lambda data: data.split(b'\nextension Animation {')[0])
        copy(root / 'scripts/menu-bar-preview.swift', preview / 'main.swift')
        copy(root / 'scripts/menu-bar-visual-check.swift', preview / 'MenuBarVisualCheck.swift')
        (work / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ThermoMenuBarQA", platforms: [.macOS(.v13)], targets: [
 .target(name: "MenuBarCore"), .target(name: "ThermoL10n"),
 .target(name: "CMenuBar", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("Foundation")]),
 .executableTarget(name: "MenuBarPreview", dependencies: ["MenuBarCore", "ThermoL10n", "CMenuBar"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("ApplicationServices")]),
 .testTarget(name: "MenuBarCoreTests", dependencies: ["MenuBarCore"])
], swiftLanguageVersions: [.v5])
''')
        (output / 'input.json').write_text(json.dumps({'files': manifest, 'themeScope': 'tokens before extension Animation'}, indent=2))
        with (output / 'test.log').open('w') as log:
            result = subprocess.run(['swift', 'test', '--jobs', '2'], cwd=work, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f'Build/tests failed; see {output / "test.log"}')
        bindir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=work, text=True).strip())
        app = output / 'Thermo Menu Bar Preview.app'
        binary = app / 'Contents/MacOS/MenuBarPreview'
        binary.parent.mkdir(parents=True)
        shutil.copy2(bindir / 'MenuBarPreview', binary)
        identifier = 'dev.thermo.menubarqa.' + uuid.uuid4().hex
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier, 'CFBundleExecutable': binary.name,
            'CFBundleName': 'Thermo Menu Bar Preview', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1', 'LSMinimumSystemVersion': '13.0', 'NSHighResolutionCapable': True,
            'UTExportedTypeDeclarations': [{'UTTypeIdentifier': 'dev.thermo.menubar-app', 'UTTypeDescription': 'Thermo menu bar app', 'UTTypeConformsTo': ['public.data']}],
        }))
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        fixtures = []
        for name, label in [('Thermo Menu Bar Fixture', 'MBH'), ('Thermo Menu Bar Visible Fixture', 'MBV'), ('Thermo Menu Bar Always Fixture', 'MBA')]:
            fixture = output / (name + '.app')
            shutil.copytree(app, fixture)
            fixture_info = fixture / 'Contents/Info.plist'
            info = plistlib.loads(fixture_info.read_bytes())
            info['CFBundleIdentifier'] = 'org.example.mbfx.' + uuid.uuid4().hex
            info['CFBundleName'] = name
            info['ThermoMenuBarFixtureLabel'] = label
            fixture_info.write_bytes(plistlib.dumps(info))
            subprocess.run(['codesign', '--force', '--sign', '-', str(fixture)], check=True, capture_output=True)
            fixtures.append({'app': str(fixture), 'bundle': info['CFBundleIdentifier'], 'label': label})
        visual = output / 'Thermo Menu Bar Visual Check.app'
        shutil.copytree(app, visual)
        visual_info = visual / 'Contents/Info.plist'
        info = plistlib.loads(visual_info.read_bytes())
        info['CFBundleIdentifier'] = 'dev.thermo.menubarqa.visual.' + uuid.uuid4().hex
        info['CFBundleName'] = 'Thermo Menu Bar Visual Check'
        info['ThermoMenuBarQARole'] = 'visual-check'
        visual_info.write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--sign', '-', str(visual)], check=True, capture_output=True)
        drag = output / 'Thermo Menu Bar Drag Check.app'
        shutil.copytree(app, drag)
        drag_info = drag / 'Contents/Info.plist'
        info = plistlib.loads(drag_info.read_bytes())
        info['CFBundleIdentifier'] = 'dev.thermo.menubarqa.drag.' + uuid.uuid4().hex
        info['CFBundleName'] = 'Thermo Menu Bar Drag Check'
        info['ThermoMenuBarQARole'] = 'drag-check'
        drag_info.write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--sign', '-', str(drag)], check=True, capture_output=True)
        probe = subprocess.check_output([str(binary), '--probe'], text=True)
        (output / 'capabilities.json').write_text(probe)
        print(json.dumps({'app': str(app), 'fixtures': fixtures, 'visualCheck': str(visual), 'dragCheck': str(drag), 'input': str(output / 'input.json'),
                          'tests': str(output / 'test.log'), 'capabilities': json.loads(probe)}, indent=2))
    finally:
        shutil.rmtree(work)


if __name__ == '__main__':
    main()
