#!/usr/bin/env python3
"""Read-only Pulse diagnostics using existing Debug objects (run swift test first).

python3 scripts/bench-pulse.py [--mode sampler|model|all] [--balanced]
Creates only private compiler outputs/reports. Never connects to the helper or performs process actions.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import tempfile


def run(argv, timeout=60):
    return subprocess.run([str(x) for x in argv], capture_output=True, text=True,
                          timeout=timeout, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['sampler', 'model', 'all'], default='all')
    parser.add_argument('--balanced', action='store_true')
    args = parser.parse_args()
    if os.getuid() == 0:
        parser.error('Run as the ordinary user.')
    repo = Path(__file__).resolve().parents[1]
    products = repo / '.build/out/Products/Debug'
    required = ['CleanKit.o', 'AgentCore.o', 'ThermoL10n.o']
    if any(not (products / x).is_file() for x in required):
        parser.error('Missing Debug objects; run swift test first.')
    root = Path(tempfile.mkdtemp(prefix='thermo-pulse-bench-')).resolve()
    (root / '.thermo-pulse-bench-fixture').write_text('Owned read-only non-root diagnostics\n')
    print(str(root), file=sys.stderr, flush=True)
    report = {'root': str(root), 'source': run(['git', '-C', repo, 'rev-parse', 'HEAD']).stdout.strip(),
              'scope': 'Debug microbenchmarks; workload and OS caches are not controlled. '
                       'Sampler stage sweeps happen after full samples. Model benchmark omits window layout. '
                       'No helper, settings changes, or process actions.'}
    if args.mode in ['sampler', 'all']:
        source = repo / 'scripts/bench-pulse-sampler.swift'
        run(['xcrun', 'swiftc', source, '-I', products,
             *[products / x for x in required], '-framework', 'AppKit',
             '-framework', 'Security', '-lsqlite3', '-lz', '-o', root / 'sampler'])
        order = ['userInitiated', 'utility', 'utility', 'userInitiated',
                 'utility', 'userInitiated', 'userInitiated', 'utility'] if args.balanced else ['utility', 'userInitiated']
        rows = []
        for index, qos in enumerate(order):
            result = run([root / 'sampler', qos], timeout=50)
            (root / ('sampler-' + str(index) + '.stderr')).write_text(result.stderr)
            rows.append(json.loads(result.stdout))
            (root / 'sampler-runs.json').write_text(json.dumps(rows, indent=2) + '\n')
        report['samplerRuns'] = rows
        report['samplerSummary'] = {
            qos: {'firstMedian': statistics.median(r['samples'][0]['seconds'] for r in rows if r['qos'] == qos),
                  'firstMax': max(r['samples'][0]['seconds'] for r in rows if r['qos'] == qos),
                  'warmMedian': statistics.median(s['seconds'] for r in rows if r['qos'] == qos for s in r['samples'][1:])}
            for qos in ['utility', 'userInitiated']}
    if args.mode in ['model', 'all']:
        intermediate = repo / '.build/out/Intermediates.noindex/thermo.build/Debug'
        lists = list(intermediate.glob('ThermoApp-*-testable-*.build/Objects-normal/' + platform.machine() + '/*testable.LinkFileList'))
        if len(lists) != 1:
            parser.error('Expected one ThermoApp testable link list; run swift test first.')
        links = [x.strip().strip('"') for x in lists[0].read_text().splitlines()
                 if not x.endswith('main.o') and not x.endswith('main.o"')]
        framework = repo / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64'
        module_map = repo / '.build/out/Intermediates.noindex/GeneratedModuleMaps/CSMC.modulemap'
        objects = ['AgentCore', 'AgentDoctor', 'CleanKit', 'ThermoKit', 'ThermoL10n', 'CSMC',
                   'Markdown', 'CAtomic', 'cmark-gfm', 'cmark-gfm-extensions', 'CTokenData']
        run(['xcrun', 'swiftc', '-parse-as-library', repo / 'scripts/bench-pulse-model.swift',
             '-I', products, '-Xcc', '-fmodule-map-file=' + str(module_map), *links,
             *[products / (name + '.o') for name in objects], '-F', framework,
             '-Xlinker', '-rpath', '-Xlinker', framework, '-lz',
             *[item for name in ['Security', 'Sparkle', 'AppKit', 'SwiftUI', 'Charts', 'IOKit', 'CoreFoundation']
               for item in ['-framework', name]], '-o', root / 'model'])
        result = run([root / 'model'], timeout=25)
        (root / 'model.stderr').write_text(result.stderr)
        report['model'] = json.loads(result.stdout)
    report['fixtureSourcesSHA256'] = {name: hashlib.sha256((repo / 'scripts' / name).read_bytes()).hexdigest()
                                     for name in ['bench-pulse.py', 'bench-pulse-model.swift', 'bench-pulse-sampler.swift']}
    (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
