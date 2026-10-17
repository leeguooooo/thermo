#!/usr/bin/env python3
"""Non-root dynamic XPC requirement check; requires existing swift test products.

Run: python3 scripts/verify-helper-peer-trust.py --sign-identity 'Developer ID Application: ...'
Only creates signed private fixtures; never connects to the installed helper.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import uuid


def run(argv, timeout=60):
    return subprocess.run([str(a) for a in argv], check=True, capture_output=True,
                          text=True, timeout=timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sign-identity', required=True)
    args = parser.parse_args()
    if os.getuid() == 0 or args.sign_identity == '-':
        parser.error('Run as the ordinary user and supply a Developer ID signing identity.')
    repo = Path(__file__).resolve().parents[1]
    products = repo / '.build/out/Products/Debug'
    module_map = repo / '.build/out/Intermediates.noindex/GeneratedModuleMaps/CSMC.modulemap'
    source = repo / 'scripts/verify-helper-peer-trust.swift'
    for path in [products / 'ThermoKit.o', products / 'CSMC.o', module_map]:
        if not path.is_file():
            parser.error('Missing Debug build products; run swift test first: ' + str(path))
    root = Path(tempfile.mkdtemp(prefix='thermo-helper-peer-')).resolve()
    (root / '.thermo-helper-peer-fixture').write_text('Owned non-root XPC peer fixture\n')
    sdk = run(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).stdout.strip()
    common = ['xcrun', 'swiftc', '-swift-version', '5', '-target',
              platform.machine() + '-apple-macosx13.0', '-sdk', sdk, source]
    run(common + ['-o', root / 'PeerClient'])
    run(common + ['-D', 'SERVER', '-I', products, '-Xcc',
                  '-fmodule-map-file=' + str(module_map), products / 'ThermoKit.o',
                  products / 'CSMC.o', '-framework', 'IOKit', '-framework', 'Security',
                  '-o', root / 'PeerService'])
    unique = uuid.uuid4().hex
    results = {}
    variants = [('cli', args.sign_identity, 'dev.thermo.cli'),
                ('app', args.sign_identity, 'dev.thermo.app'),
                ('wrongID', args.sign_identity, 'dev.thermo.qa.wrong-client'),
                ('adHoc', '-', 'dev.thermo.cli')]
    for variant, identity, host_id in variants:
        app = root / (variant + '.app')
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        shutil.copyfile(root / 'PeerClient', contents / 'MacOS/PeerClient')
        (contents / 'MacOS/PeerClient').chmod(0o700)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': host_id, 'CFBundleExecutable': 'PeerClient',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSBackgroundOnly': True}))
        names = {}
        for role in ['open', 'gated']:
            name = 'dev.thermo.qa.peer.' + unique + '.' + variant + '.' + role
            names[role] = name
            service = contents / 'XPCServices' / (name + '.xpc')
            sc = service / 'Contents'
            (sc / 'MacOS').mkdir(parents=True)
            shutil.copyfile(root / 'PeerService', sc / 'MacOS/PeerService')
            (sc / 'MacOS/PeerService').chmod(0o700)
            (sc / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': name, 'CFBundleExecutable': 'PeerService',
                'CFBundlePackageType': 'XPC!', 'CFBundleVersion': '1',
                'XPCService': {'ServiceType': 'Application'},
                'ThermoEnforceClientRequirement': role == 'gated'}))
            run(['codesign', '--force', '--options', 'runtime', '--timestamp=none',
                 '--sign', args.sign_identity, service])
        run(['codesign', '--force', '--options', 'runtime', '--timestamp=none',
             '--sign', identity, app])
        run(['codesign', '--verify', '--deep', '--strict', app])
        checks = {}
        for role in ['open', 'gated']:
            process = subprocess.run([str(contents / 'MacOS/PeerClient'), names[role]],
                                     capture_output=True, text=True, timeout=12)
            value = json.loads(process.stdout)
            expected_reply = role == 'open' or variant in ['cli', 'app']
            if expected_reply:
                assert process.returncode == 0 and value.get('service') == names[role]
            else:
                assert process.returncode == 3 and value['status'] in ['error', 'invalidated']
            checks[role] = {'exitCode': process.returncode, 'result': value,
                            'stderr': process.stderr.strip()}
        results[variant] = checks
        (root / 'partial-results.json').write_text(json.dumps(results, indent=2) + '\n')
    # NSXPC service connections exit their private service when invalidated.
    processes = run(['ps', '-axo', 'pid=,uid=,command=']).stdout
    owned = [row for row in processes.splitlines() if str(root) + '/' in row]
    report = {
        'root': str(root), 'uid': os.getuid(), 'results': results,
        'sourceSnapshot': run(['git', '-C', repo, 'rev-parse', 'HEAD']).stdout.strip(),
        'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'helperSourceSHA256': hashlib.sha256((repo / 'Sources/ThermoKit/Helper.swift').read_bytes()).hexdigest(),
        'fixtureProcessesStillObserved': owned,
        'scope': 'Real per-app non-root XPC using the production HelperConstants.clientRequirement. '
                 'Only ping is exported. Does not exercise the production helper Service, '
                 'system-domain launchd registration, installed helper, hardware, or root privileges.'}
    (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
