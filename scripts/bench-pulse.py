#!/usr/bin/env python3
"""Read-only Pulse diagnostics compiled as actual temporary SwiftPM targets.

python3 scripts/bench-pulse.py [--mode sampler|model|all] [--balanced]
Creates only private compiler outputs/reports. Never connects to the helper or performs process actions.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import uuid
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
    parser.add_argument('--jobs',type=int,default=1)
    parser.add_argument('--build-only',action='store_true',help='Compile fixtures without running measurements')
    args = parser.parse_args()
    if os.getuid() == 0:
        parser.error('Run as the ordinary user.')
    repo = Path(__file__).resolve().parents[1]
    if args.jobs<1:parser.error('jobs must be positive')
    root = Path(tempfile.mkdtemp(prefix='thermo-pulse-bench-')).resolve()
    (root / '.thermo-pulse-bench-fixture').write_text('Owned read-only non-root diagnostics\n')
    print(str(root), file=sys.stderr, flush=True)
    report = {'root': str(root), 'source': run(['git', '-C', repo, 'rev-parse', 'HEAD']).stdout.strip(),
              'scope': 'Debug microbenchmarks; workload and OS caches are not controlled. '
                       'Sampler stage sweeps happen after full samples. Model benchmark omits window layout. '
                       'No helper, settings changes, or process actions.'}
    modes=['sampler','model'] if args.mode=='all' else [args.mode]
    package=repo/'Package.swift';original=package.read_bytes();needle=b'    targets: ['
    if original.count(needle)!=1:raise RuntimeError('Expected one package target list')
    declarations=[];directories=[];targets={}
    try:
        for mode in modes:
            target='PulseBenchmark'+uuid.uuid4().hex[:10];targets[mode]=target
            directory=repo/'Sources'/target;directory.mkdir();directories.append(directory)
            name='main.swift' if mode=='sampler' else 'Benchmark.swift'
            (directory/name).write_bytes((repo/'scripts'/('bench-pulse-'+mode+'.swift')).read_bytes())
            deps=['CleanKit','AgentCore','ThermoL10n'] if mode=='sampler' else ['PerformanceFeature','CleanKit','AgentCore','ThermoUI']
            declarations.append('\n        .executableTarget(name:'+json.dumps(target)+',dependencies:'+json.dumps(deps)+'),')
        modified=original.replace(needle,needle+''.join(declarations).encode());package.write_bytes(modified)
        for mode,target in targets.items():
            run(['swift','build','--jobs',str(args.jobs),'--product',target],timeout=600)
            base=Path(run(['swift','build','--show-bin-path']).stdout.strip())
            shutil.copy2(base/target,root/mode)
    finally:
        if 'modified' not in locals() or package.read_bytes() in [original,modified]:
            package.write_bytes(original)
            for directory in directories:
                for source in directory.iterdir():source.unlink()
                directory.rmdir()
        else:
            (root/'Package.before-benchmark.swift').write_bytes(original)
            raise RuntimeError('Concurrent Package.swift change preserved; original backup and fixture sources retained')
    report['executed']=not args.build_only
    report['configuration']='debug SwiftPM; private production model'
    if args.mode in ['sampler','all'] and not args.build_only:
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
    if args.mode in ['model','all'] and not args.build_only:
        result = run([root / 'model'], timeout=25)
        (root / 'model.stderr').write_text(result.stderr)
        report['model'] = json.loads(result.stdout)
    report['fixtureSourcesSHA256'] = {name: hashlib.sha256((repo / 'scripts' / name).read_bytes()).hexdigest()
                                     for name in ['bench-pulse.py', 'bench-pulse-model.swift', 'bench-pulse-sampler.swift']}
    (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
