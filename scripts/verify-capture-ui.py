#!/usr/bin/env python3
"""Build an isolated app using production capture UI. Does not launch it or touch the installed Thermo."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--recording-review', action='store_true')
    parser.add_argument('--ordinary-review', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    output = args.output_dir.resolve() if args.output_dir else Path(tempfile.mkdtemp(prefix='thermo-capture-qa-'))
    app = output / 'ThermoCaptureQA.app'
    if app.exists():
        parser.error('Output app already exists; choose a fresh output directory.')
    output.mkdir(parents=True, exist_ok=True)
    # Test builds emit the renamed ThermoApp_main entry point for @testable import.
    subprocess.run(['swift', 'test', '-j', '4', '--filter', 'CaptureCoreTests'], check=True)
    base = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], text=True).strip()).resolve()
    package = json.loads(subprocess.check_output(['swift', 'package', 'describe', '--type', 'json'], text=True))
    clang_targets = {target['name'] for target in package['targets'] if target.get('module_type') == 'ClangTarget'} | {'libwebp'}
    binary = app / 'Contents/MacOS/ThermoCaptureQA'
    binary.parent.mkdir(parents=True)
    command = ['xcrun', 'swiftc', '-parse-as-library', str(root/'scripts/verify-capture-ui.swift'), '-o', str(binary),
               '-I', str(root/'Sources/CSQLite'), '-lsqlite3', '-lz', '-framework', 'AVKit']
    if (base/'ExecutableModules').is_dir():
        command += ['-I', str(base), '-F', str(base), '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', str(base)]
        for name in sorted(clang_targets):
            for path in (root/'.build/out/Intermediates.noindex/GeneratedModuleMaps').glob(name+'.modulemap'):
                command += ['-Xcc', '-fmodule-map-file='+str(path)]
        modules = list((base/'ExecutableModules').glob('ThermoApp-*-testable.o'))
        if len(modules) != 1:
            raise RuntimeError('Expected one current ThermoApp testable object.')
        command += [str(path) for path in base.glob('*.o')] + [str(modules[0])]
    else:
        sparkle = root/'.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64'
        command += ['-I', str(base/'Modules'), '-I', str(base/'CSMC.build'),
                    '-I', str(base/'CWebPEncoder.build'), '-I', str(base/'libwebp.build'),
                    '-F', str(sparkle), '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', str(sparkle)]
        for name in sorted(clang_targets):
            command += ['-I', str(base/(name+'.build'))]
        command += (base/'ThermoApp.product/Objects.LinkFileList').read_text().splitlines()
    subprocess.run(command, check=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'dev.thermo.capture-qa.'+hashlib.sha256(str(output).encode()).hexdigest()[:12], 'CFBundleExecutable': binary.name,
        'CFBundleName': binary.name, 'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True,
        'ThermoRecordingReview': args.recording_review or args.ordinary_review, 'ThermoOrdinaryReview': args.ordinary_review, 'ThermoCaptureFixtureRoot': str(output),
    }))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    print(app)


if __name__ == '__main__':
    main()
