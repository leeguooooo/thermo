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
    parser.add_argument('--av-layer-review', action='store_true')
    parser.add_argument('--keyboard-review', action='store_true')
    parser.add_argument('--annotation-review', action='store_true')
    parser.add_argument('--pin-groups-review', action='store_true')
    parser.add_argument('--typed-pins-review', action='store_true')
    parser.add_argument('--latex-review', action='store_true')
    parser.add_argument('--word-math-review', action='store_true')
    parser.add_argument('--shortcuts-review', action='store_true')
    parser.add_argument('--script-review', action='store_true')
    parser.add_argument('--capture-cli-review', action='store_true')
    parser.add_argument('--saving-review', action='store_true')
    parser.add_argument('--screenshot-review', action='store_true')
    parser.add_argument('--ocr-review', action='store_true')
    parser.add_argument('--pin-lock-review', action='store_true')
    parser.add_argument('--html-probe-url', default='http://127.0.0.1:49379/probe')
    args = parser.parse_args()
    if args.pin_lock_review:
        args.annotation_review = True
        args.ocr_review = True
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
               '-I', str(root/'Sources/CSQLite'), '-lsqlite3', '-lz', '-framework', 'AVKit', '-framework', 'WebKit', '-framework', 'Quartz', '-framework', 'JavaScriptCore']
    if (base/'ExecutableModules').is_dir():
        framework = base/'Sparkle.framework'
        command += ['-I', str(base), '-F', str(base), '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks']
        for name in sorted(clang_targets):
            for path in (root/'.build/out/Intermediates.noindex/GeneratedModuleMaps').glob(name+'.modulemap'):
                command += ['-Xcc', '-fmodule-map-file='+str(path)]
        modules = list((base/'ExecutableModules').glob('ThermoApp-*-testable.o'))
        if len(modules) != 1:
            raise RuntimeError('Expected one current ThermoApp testable object.')
        command += [str(path) for path in base.glob('*.o')] + [str(modules[0])]
    else:
        sparkle = root/'.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64'
        framework = sparkle/'Sparkle.framework'
        command += ['-I', str(base/'Modules'), '-I', str(base/'CSMC.build'),
                    '-I', str(base/'CWebPEncoder.build'), '-I', str(base/'libwebp.build'),
                    '-F', str(sparkle), '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks']
        for name in sorted(clang_targets):
            command += ['-I', str(base/(name+'.build'))]
        command += (base/'ThermoApp.product/Objects.LinkFileList').read_text().splitlines()
    subprocess.run(command, check=True)
    helpers=app/'Contents/Helpers'
    helpers.mkdir(parents=True)
    subprocess.run(['ditto',str(base/'thermo-capture-script'),str(helpers/'thermo-capture-script')],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(helpers/'thermo-capture-script')],check=True)
    if args.capture_cli_review:
        subprocess.run(['ditto',str(base/'thermo'),str(helpers/'thermo')],check=True)
        subprocess.run(['codesign','--force','--sign','-','--identifier','dev.thermo.cli',str(helpers/'thermo')],check=True)
    frameworks = app/'Contents/Frameworks'
    frameworks.mkdir(parents=True)
    subprocess.run(['ditto', str(framework), str(frameworks/'Sparkle.framework')], check=True)
    subprocess.run(['python3', str(root/'scripts/math-renderer/verify.py')], check=True)
    subprocess.run(['python3', str(root/'scripts/word-template/verify.py')], check=True)
    subprocess.run(['ditto', str(root/'Resources/CaptureWord'), str(app/'Contents/Resources/CaptureWord')], check=True)
    subprocess.run(['ditto', str(root/'Resources/CaptureMath'), str(app/'Contents/Resources/CaptureMath')], check=True)
    subprocess.run(['ditto', str(root/'Resources/ThirdPartyNotices'), str(app/'Contents/Resources/ThirdPartyNotices')], check=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'dev.thermo.capture-qa.'+hashlib.sha256(str(output).encode()).hexdigest()[:12], 'CFBundleExecutable': binary.name,
        'CFBundleName': binary.name, 'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True,
        'ThermoOCRReview': args.ocr_review, 'ThermoScreenshotReview': args.screenshot_review, 'ThermoSavingReview': args.saving_review, 'ThermoCaptureCLIReview': args.capture_cli_review, 'ThermoScriptReview': args.script_review or args.capture_cli_review, 'ThermoShortcutsReview': args.shortcuts_review or args.script_review or args.capture_cli_review, 'ThermoWordMathReview': args.word_math_review, 'ThermoLaTeXReview': args.latex_review or args.word_math_review, 'ThermoTypedPinsReview': args.typed_pins_review, 'ThermoHTMLProbeURL': args.html_probe_url, 'ThermoPinGroupsReview': args.pin_groups_review, 'ThermoAnnotationReview': args.annotation_review, 'ThermoRecordingReview': args.recording_review or args.ordinary_review or args.av_layer_review or args.keyboard_review, 'ThermoOrdinaryReview': args.ordinary_review or args.av_layer_review or args.keyboard_review, 'ThermoKeyboardReview': args.keyboard_review, 'ThermoAVLayerReview': args.av_layer_review, 'ThermoCaptureFixtureRoot': str(output),
    }))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    print(app)


if __name__ == '__main__':
    main()
