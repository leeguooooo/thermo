#!/usr/bin/env python3
"""Build an isolated app using production capture UI. Does not launch it or touch the installed Thermo."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--app-path', type=Path, help='Optional persistent QA app location, for example ~/Applications/ThermoCaptureQA.app')
    parser.add_argument('--jobs',type=int,default=1,help='Bounded Swift build jobs')
    parser.add_argument('--bundle-id', help='Stable identity for an explicitly authorized live-capture QA profile')
    parser.add_argument('--sign-id', default='-', help='Signing identity; ad-hoc by default, Developer ID recommended for live permission tests')
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
    parser.add_argument('--live-capture-review', action='store_true')
    parser.add_argument('--ocr-review', action='store_true')
    parser.add_argument('--pin-lock-review', action='store_true')
    parser.add_argument('--passthrough-review', action='store_true')
    parser.add_argument('--batch-export-review', action='store_true')
    parser.add_argument('--batch-export-stress-review', action='store_true')
    parser.add_argument('--crop-review', action='store_true')
    parser.add_argument('--annotation-styles-review', action='store_true')
    parser.add_argument('--html-probe-url', default='http://127.0.0.1:49379/probe')
    args = parser.parse_args()
    if args.batch_export_stress_review:
        args.batch_export_review = True
    if args.batch_export_review:
        args.passthrough_review = True
    if args.annotation_styles_review:
        args.annotation_review = True
        args.ocr_review = True
    if args.crop_review:
        args.annotation_review = True
        args.ocr_review = True
    if args.pin_lock_review:
        args.annotation_review = True
        args.ocr_review = True
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    output = args.output_dir.resolve() if args.output_dir else Path(tempfile.mkdtemp(prefix='thermo-capture-qa-'))
    app = args.app_path.expanduser().resolve() if args.app_path else output / 'ThermoCaptureQA.app'
    if args.bundle_id and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]+', args.bundle_id):
        parser.error('Invalid QA bundle identifier.')
    if app.exists():
        parser.error('Output app already exists; choose a fresh output directory.')
    output.mkdir(parents=True, exist_ok=True)
    if args.jobs < 1:
        parser.error('jobs must be positive')
    # A real temporary SPM target gets package visibility and exact transitive linking.
    # Never link ThermoApp or expose its former private capture models for this harness.
    import uuid
    target = 'CaptureReviewFixture' + uuid.uuid4().hex[:10]
    source_dir = root / 'Sources' / target
    source_dir.mkdir()
    package_file = root / 'Package.swift'
    original_package = package_file.read_bytes()
    needle = b'    targets: ['
    if original_package.count(needle) != 1:
        source_dir.rmdir()
        raise RuntimeError('Expected one package target list')
    declaration = ('\n        .executableTarget(name:"' + target + '",dependencies:["CaptureFeature","CaptureControlAdapter","CaptureCore","CaptureScriptCore","AgentCore","ThermoKit","ThermoL10n"]),').encode()
    modified_package = original_package.replace(needle, needle + declaration)
    binary = app / 'Contents/MacOS/ThermoCaptureQA'
    binary.parent.mkdir(parents=True)
    copied_sources = []
    try:
        for name in ('verify-capture-ui.swift','verify-capture-live.swift'):
            destination = source_dir / name
            destination.write_bytes((root/'scripts'/name).read_bytes())
            copied_sources.append(destination)
        package_file.write_bytes(modified_package)
        subprocess.run(['swift','build','--jobs',str(args.jobs),'--product',target],check=True)
        subprocess.run(['swift','build','--jobs',str(args.jobs),'--product','thermo-capture-script'],check=True)
        if args.capture_cli_review:
            subprocess.run(['swift','build','--jobs',str(args.jobs),'--product','thermo'],check=True)
        base = Path(subprocess.check_output(['swift','build','--show-bin-path'],text=True).strip()).resolve()
        subprocess.run(['ditto',str(base/target),str(binary)],check=True)
    finally:
        if package_file.read_bytes() == modified_package:
            package_file.write_bytes(original_package)
            for source in copied_sources:
                source.unlink()
            source_dir.rmdir()
        else:
            backup = output/'Package.before-fixture.swift'
            backup.write_bytes(original_package)
            raise RuntimeError('Package.swift changed during the fixture build; preserved it and fixture sources. Original saved to '+str(backup))
    helpers=app/'Contents/Helpers'
    helpers.mkdir(parents=True)
    subprocess.run(['ditto',str(base/'thermo-capture-script'),str(helpers/'thermo-capture-script')],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(helpers/'thermo-capture-script')],check=True)
    if args.capture_cli_review:
        subprocess.run(['ditto',str(base/'thermo'),str(helpers/'thermo')],check=True)
        subprocess.run(['codesign','--force','--sign','-','--identifier','dev.thermo.cli',str(helpers/'thermo')],check=True)
    subprocess.run(['python3', str(root/'scripts/math-renderer/verify.py')], check=True)
    subprocess.run(['python3', str(root/'scripts/word-template/verify.py')], check=True)
    subprocess.run(['ditto', str(root/'Resources/CaptureWord'), str(app/'Contents/Resources/CaptureWord')], check=True)
    subprocess.run(['ditto', str(root/'Resources/CaptureMath'), str(app/'Contents/Resources/CaptureMath')], check=True)
    subprocess.run(['ditto', str(root/'Resources/ThirdPartyNotices'), str(app/'Contents/Resources/ThirdPartyNotices')], check=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': args.bundle_id or 'dev.thermo.capture-qa.'+hashlib.sha256(str(output).encode()).hexdigest()[:12], 'CFBundleExecutable': binary.name,
        'CFBundleName': app.stem, 'CFBundleShortVersionString':'0.0.1', 'CFBundleVersion':'1',
        'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True, 'ThermoLiveCaptureReview':args.live_capture_review,
        'ThermoPassthroughReview': args.passthrough_review, 'ThermoBatchExportReview': args.batch_export_review, 'ThermoBatchExportStressReview': args.batch_export_stress_review, 'ThermoCropReview': args.crop_review, 'ThermoAnnotationStylesReview': args.annotation_styles_review, 'ThermoOCRReview': args.ocr_review, 'ThermoScreenshotReview': args.screenshot_review, 'ThermoSavingReview': args.saving_review, 'ThermoCaptureCLIReview': args.capture_cli_review, 'ThermoScriptReview': args.script_review or args.capture_cli_review, 'ThermoShortcutsReview': args.shortcuts_review or args.script_review or args.capture_cli_review, 'ThermoWordMathReview': args.word_math_review, 'ThermoLaTeXReview': args.latex_review or args.word_math_review, 'ThermoTypedPinsReview': args.typed_pins_review, 'ThermoHTMLProbeURL': args.html_probe_url, 'ThermoPinGroupsReview': args.pin_groups_review, 'ThermoAnnotationReview': args.annotation_review, 'ThermoRecordingReview': args.recording_review or args.ordinary_review or args.av_layer_review or args.keyboard_review, 'ThermoOrdinaryReview': args.ordinary_review or args.av_layer_review or args.keyboard_review, 'ThermoKeyboardReview': args.keyboard_review, 'ThermoAVLayerReview': args.av_layer_review, 'ThermoCaptureFixtureRoot': str(output),
    }))
    subprocess.run(['codesign', '--force', '--sign', args.sign_id]+(['--timestamp'] if args.sign_id != '-' else [])+[str(app)], check=True)
    if args.live_capture_review:
        import math, struct, wave
        pattern = output/'ThermoCapturePattern.app'
        executable = pattern/'Contents/MacOS/ThermoCapturePattern'
        executable.parent.mkdir(parents=True)
        resources = pattern/'Contents/Resources'
        resources.mkdir()
        with wave.open(str(resources/'test-tone.wav'), 'wb') as tone:
            tone.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
            tone.writeframes(b''.join(struct.pack('<h', int(12000*math.sin(2*math.pi*440*i/48000))) for i in range(48000)))
        (pattern/'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier':'dev.thermo.capture-pattern.'+hashlib.sha256(str(output).encode()).hexdigest()[:12],
            'CFBundleExecutable':executable.name, 'CFBundleName':executable.name, 'CFBundlePackageType':'APPL', 'NSHighResolutionCapable':True,
        }))
        subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'scripts/verify-capture-pattern.swift'),'-o',str(executable)],check=True)
        subprocess.run(['codesign','--force','--sign','-',str(pattern)],check=True)
        print(pattern)
    print(app)


if __name__ == '__main__':
    main()
