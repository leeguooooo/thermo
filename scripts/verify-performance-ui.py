#!/usr/bin/env python3
"""Build a separate performance UI review app; never launches or replaces installed Thermo."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--jobs', type=int, default=1)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('jobs must be positive')
    root = Path(__file__).resolve().parent.parent
    output = args.output_dir.expanduser().resolve() if args.output_dir else Path(tempfile.mkdtemp(prefix='thermo-performance-review-'))
    app = output / 'ThermoPerformanceQA.app'
    if app.exists():
        parser.error('Output app already exists; choose a fresh output directory.')
    if not output.name.startswith('thermo-performance-review-'):
        parser.error('Output directory must start with thermo-performance-review-.')
    output.mkdir(parents=True, exist_ok=True)
    (output / '.thermo-performance-fixture').touch()
    # A real package target gets the actual package identity and linker inputs.
    # No guessed package-name or scan of unrelated Release object files.
    target = 'PerformanceReviewFixture' + uuid.uuid4().hex[:10]
    source_dir = root / 'Sources' / target
    package_file = root / 'Package.swift'
    original = package_file.read_bytes()
    needle = b'    targets: ['
    if original.count(needle) != 1:
        raise RuntimeError('Expected one package target list')
    declaration = ('\n        .executableTarget(name:"' + target + '",dependencies:["ThermoApp","SystemServicesAPI","AgentCore","ModuleKit","ThermoKit"]),').encode()
    product = b'        .executable(name: "ThermoApp", targets: ["ThermoApp"]),\n'
    executable = b'.executableTarget(\n            name: "ThermoApp",'
    if original.count(product) != 1 or original.count(executable) != 1:
        raise RuntimeError('Expected the current ThermoApp executable declaration')
    # SwiftPM does not link executable dependencies into another executable.
    # For this staged Root harness only, compile unchanged app declarations as a library,
    # omitting launch statements. The production manifest and entry point are preserved.
    import re
    modified = original.replace(needle, needle + declaration).replace(product, b'').replace(executable, b'.target(\n            name: "ThermoApp",')
    modified, count = re.subn(rb'(name: "ThermoApp",\n            dependencies: \[[^\n]+\],\n)', rb'\1            exclude: ["main.swift"],\n', modified)
    if count != 1:
        raise RuntimeError('Expected one ThermoApp dependency declaration')
    entry = (root / 'Sources/ThermoApp/main.swift').read_text()
    marker = '// Capture upgrade evidence before SingleInstance creates Application Support/Thermo/app.lock.'
    if entry.count(marker) != 1:
        raise RuntimeError('Expected the app launch boundary')
    declarations = entry.split(marker)[0] + '\nlet featureLaunchState: FeatureLaunchPolicy.State? = nil\n'
    app_declarations = root / 'Sources/ThermoApp' / (target + 'Declarations.swift')
    source_dir.mkdir()
    source = source_dir / 'Review.swift'
    source.write_bytes((root / 'scripts/verify-performance-ui.swift').read_bytes())
    binary = app / 'Contents/MacOS/ThermoPerformanceQA'
    binary.parent.mkdir(parents=True)
    try:
        app_declarations.write_text(declarations)
        package_file.write_bytes(modified)
        subprocess.run(['swift', 'build', '--jobs', str(args.jobs), '--product', target], cwd=root, check=True)
        base = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip()).resolve()
        subprocess.run(['ditto', str(base / target), str(binary)], check=True)
        subprocess.run(['ditto', str(base / 'Sparkle.framework'), str(app / 'Contents/Frameworks/Sparkle.framework')], check=True)
    finally:
        current = package_file.read_bytes()
        if (current == modified or current == original) and app_declarations.read_text() == declarations:
            package_file.write_bytes(original)
            app_declarations.unlink()
            source.unlink()
            source_dir.rmdir()
        else:
            backup = output / 'Package.before-fixture.swift'
            backup.write_bytes(original)
            raise RuntimeError('Package.swift changed during review build; preserved current source and saved original to ' + str(backup))
    info = {'CFBundleIdentifier': 'dev.thermo.performance-review.' + hashlib.sha256(str(output).encode()).hexdigest()[:12],
            'CFBundleName': 'ThermoPerformanceQA', 'CFBundleExecutable': binary.name,
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSMinimumSystemVersion': '13.0',
            'ThermoPerformanceFixture': str(output)}
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
    (output / 'source.json').write_text(json.dumps({
        'gitHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
        'executableSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'packageSHA256': hashlib.sha256(original).hexdigest(), 'configuration': 'debug SwiftPM',
        'helperInteraction': False, 'launched': False}, indent=2) + '\n')
    print(app)


if __name__ == '__main__':
    main()
