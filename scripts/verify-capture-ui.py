#!/usr/bin/env python3
"""Build an isolated app using production capture UI. Does not launch it or touch the installed Thermo."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path)
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
    binary = app / 'Contents/MacOS/ThermoCaptureQA'
    binary.parent.mkdir(parents=True)
    command = ['xcrun', 'swiftc', '-parse-as-library', str(root/'scripts/verify-capture-ui.swift'), '-o', str(binary),
               '-I', str(root/'Sources/CSQLite'), '-lsqlite3', '-lz']
    if (base/'ExecutableModules').is_dir():
        command += ['-I', str(base), '-F', str(base), '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', str(base)]
        intermediate = root/'.build/out/Intermediates.noindex/thermo.build/Debug'
        for name in ['CSMC', 'CTokenData']:
            for path in intermediate.glob(name+'-t.build/*.modulemap'):
                command += ['-Xcc', '-fmodule-map-file='+str(path)]
        modules = list((base/'ExecutableModules').glob('ThermoApp-*-testable.o'))
        if len(modules) != 1:
            raise RuntimeError('Expected one current ThermoApp testable object.')
        command += [str(path) for path in base.glob('*.o')] + [str(modules[0])]
    else:
        sparkle = root/'.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64'
        command += ['-I', str(base/'Modules'), '-I', str(base/'CSMC.build'),
                    '-F', str(sparkle), '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', str(sparkle)]
        command += (base/'ThermoApp.product/Objects.LinkFileList').read_text().splitlines()
    subprocess.run(command, check=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'dev.thermo.capture-qa', 'CFBundleExecutable': binary.name,
        'CFBundleName': 'Thermo Capture QA', 'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True,
    }))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    print(app)


if __name__ == '__main__':
    main()
