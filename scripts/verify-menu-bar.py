#!/usr/bin/env python3
"""Build isolated apps from the actual private MenuBarFeature; does not launch them.

Run policy/lifecycle tests separately. Explicit self-test/live modes can hide
icons through the private interface and are never run by this builder.
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
    parser.add_argument('--jobs',type=int,default=1)
    parser.add_argument('--output', type=Path, required=True, help='New directory for app, logs and manifest')
    parser.add_argument('--fixture-delay', type=float, default=0, help='Delay MBH creation 0 to 5 seconds for startup identity comparison; other fixtures stay immediate')
    parser.add_argument('--real-hidden-bundle', default='com.depthpicture.PixPin', help='Running app with an identifiable status icon to place in Hidden for manual visual review')
    parser.add_argument('--real-always-bundle', default='com.bitwarden.desktop', help='Running app with an identifiable status icon to place in Always Hidden for manual visual review')
    args = parser.parse_args()
    if args.jobs<1:parser.error('--jobs must be positive')
    if not 0 <= args.fixture_delay <= 5:
        parser.error('--fixture-delay must be between 0 and 5 seconds')
    if args.real_hidden_bundle == args.real_always_bundle:
        parser.error('Real-app comparison requires two different bundle identifiers')
    for bundle in [args.real_hidden_bundle, args.real_always_bundle]:
        if not bundle or len(bundle.encode('utf-8')) > 255 or bundle.startswith(('com.apple.', 'dev.thermo.')):
            parser.error('Real-app comparison requires non-protected bundle identifiers of at most 255 bytes')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    target='MenuBarPreview'+uuid.uuid4().hex[:10]
    source_dir=root/'Sources'/target
    source_dir.mkdir()
    package_file=root/'Package.swift'
    original=package_file.read_bytes()
    needle=b'    targets: ['
    if original.count(needle)!=1:
        source_dir.rmdir();raise RuntimeError('Expected one package target list')
    declaration=('\n        .executableTarget(name:"'+target+'",dependencies:["MenuBarFeature","MenuBarCore","CMenuBar","NativeFeatureAPI","HotkeyCore","ThermoUI","ThermoL10n"]),').encode()
    modified=original.replace(needle,needle+declaration)
    copied=[];written=False
    try:
        files={}
        for source_name,destination_name in [('menu-bar-preview.swift','main.swift'),('menu-bar-visual-check.swift','MenuBarVisualCheck.swift'),('menu-bar-live-manager-check.swift','MenuBarLiveManagerCheck.swift')]:
            source=root/'scripts'/source_name
            destination=source_dir/destination_name
            destination.write_bytes(source.read_bytes());copied.append(destination)
            files[str(source.relative_to(root))]=hashlib.sha256(source.read_bytes()).hexdigest()
        for source in (root/'Sources/MenuBarFeature').glob('*.swift'):
            files[str(source.relative_to(root))]=hashlib.sha256(source.read_bytes()).hexdigest()
        (output/'input.json').write_text(json.dumps({'files':files,'source':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'fixtureDelaySeconds':args.fixture_delay,'realHiddenBundle':args.real_hidden_bundle,'realAlwaysHiddenBundle':args.real_always_bundle,'buildOnly':True},indent=2))
        package_file.write_bytes(modified);written=True
        with (output/'build.log').open('w') as log:
            subprocess.run(['swift','build','--jobs',str(args.jobs),'--product',target],cwd=root,stdout=log,stderr=subprocess.STDOUT,check=True)
        bindir=Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=root,text=True).strip())
        app=output/'Thermo Menu Bar Preview.app'
        binary=app/'Contents/MacOS/MenuBarPreview'
        binary.parent.mkdir(parents=True)
        shutil.copy2(bindir/target,binary)
    finally:
        current=package_file.read_bytes()
        if current==modified or (not written and current==original):
            package_file.write_bytes(original)
            for source in copied:source.unlink()
            source_dir.rmdir()
        else:
            (output/'Package.before-fixture.swift').write_bytes(original)
            raise RuntimeError('Concurrent Package.swift change preserved; fixture sources and original backup retained')
    identifier='dev.thermo.menubarqa.'+uuid.uuid4().hex
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier':identifier,'CFBundleExecutable':binary.name,'CFBundleName':'Thermo Menu Bar Preview','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,
        'UTExportedTypeDeclarations':[{'UTTypeIdentifier':'dev.thermo.menubar-app','UTTypeDescription':'Thermo menu bar app','UTTypeConformsTo':['public.data']}],
    }))
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
    fixtures = []
    for name, label in [('Thermo Menu Bar Fixture', 'MBH'), ('Thermo Menu Bar Visible Fixture', 'MBV'), ('Thermo Menu Bar Always Fixture', 'MBA')]:
        fixture = output / (name + '.app')
        shutil.copytree(app, fixture)
        fixture_info = fixture / 'Contents/Info.plist'
        info = plistlib.loads(fixture_info.read_bytes())
        info['CFBundleIdentifier'] = 'org.example.mbfx.' + uuid.uuid4().hex
        info['CFBundleName'] = name
        info['ThermoMenuBarFixtureLabel'] = label
        if label == 'MBH': info['ThermoMenuBarFixtureDelaySeconds'] = args.fixture_delay
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
    real = output / 'Thermo Menu Bar Real Check.app'
    shutil.copytree(visual, real)
    real_info = real / 'Contents/Info.plist'
    info['CFBundleIdentifier'] = 'dev.thermo.menubarqa.real.' + uuid.uuid4().hex
    info['CFBundleName'] = 'Thermo Menu Bar Real Check'
    info['ThermoMenuBarQARole'] = 'real-check'
    info['ThermoMenuBarRealHiddenBundle'] = args.real_hidden_bundle
    info['ThermoMenuBarRealAlwaysBundle'] = args.real_always_bundle
    real_info.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(real)], check=True, capture_output=True)
    swap = output / 'Thermo Menu Bar Swapped Check.app'
    shutil.copytree(real, swap)
    info['CFBundleIdentifier'] = 'dev.thermo.menubarqa.real.' + uuid.uuid4().hex
    info['CFBundleName'] = 'Thermo Menu Bar Swapped Check'
    info['ThermoMenuBarRealHiddenBundle'] = args.real_always_bundle
    info['ThermoMenuBarRealAlwaysBundle'] = args.real_hidden_bundle
    (swap / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(swap)], check=True, capture_output=True)
    drag = output / 'Thermo Menu Bar Drag Check.app'
    shutil.copytree(app, drag)
    drag_info = drag / 'Contents/Info.plist'
    info = plistlib.loads(drag_info.read_bytes())
    info['CFBundleIdentifier'] = 'dev.thermo.menubarqa.drag.' + uuid.uuid4().hex
    info['CFBundleName'] = 'Thermo Menu Bar Drag Check'
    info['ThermoMenuBarQARole'] = 'drag-check'
    info.pop('ThermoMenuBarRealHiddenBundle', None)
    info.pop('ThermoMenuBarRealAlwaysBundle', None)
    drag_info.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(drag)], check=True, capture_output=True)
    print(json.dumps({'app':str(app),'fixtures':fixtures,'visualCheck':str(visual),'realCheck':str(real),'swappedCheck':str(swap),'dragCheck':str(drag),'input':str(output/'input.json'),'build':str(output/'build.log'),'launched':False},indent=2))


if __name__ == '__main__':
    main()
