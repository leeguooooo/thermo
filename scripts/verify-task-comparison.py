"""Exercise the compiled CLI with synthetic records; never invokes models or tools.
Usage: python3 scripts/verify-task-comparison.py .build/debug/thermo
"""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parents[1]
fixture = json.loads((root / 'docs/examples/task-comparison.json').read_text())
checks = []

with tempfile.TemporaryDirectory(prefix='thermo-task-comparison-') as directory:
    home = Path(directory)
    source = home / 'records.json'
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))

    def run(payload, *arguments, success=True):
        source.write_text(json.dumps(payload))
        result = subprocess.run([str(binary), 'agents', 'compare', str(source), *arguments],
                                env=env, text=True, capture_output=True, timeout=10)
        assert (result.returncode == 0) == success, result.stderr
        return result

    report = json.loads(run(fixture, '--json').stdout)
    assert report['evidenceKind'] == 'synthetic'
    assert (report['matchedPairs'], report['verifiedOutcomePairs']) == (3, 3)
    assert report['candidate']['timeout'] == report['baseline']['failed'] == 1
    assert report['passRateDifferencePercentagePoints'] == 0
    assert report['seconds']['medianCandidateMinusBaseline'] == 2
    assert report['inputTokens']['samples'] == 2
    checks.append('compiled JSON output retains outcomes and paired metric sample sizes')

    plain = run(fixture, '--no-color').stdout
    assert 'Evidence: synthetic' in plain and '+2.000' in plain and '+35.000' in plain
    checks.append('text output labels synthetic evidence and delta direction')

    altered = copy.deepcopy(fixture)
    for row in altered['runs']:
        row['seconds'] = row['inputTokens'] = row['outputTokens'] = None
        row['outcome'] = 'unverified'
    unknown = json.loads(run(altered, '--json').stdout)
    assert unknown['verifiedOutcomePairs'] == 0
    assert unknown['seconds']['samples'] == 0
    assert 'passRateDifferencePercentagePoints' not in unknown
    assert 'unknown (0 paired samples)' in run(altered).stdout
    checks.append('missing metrics and unverified outcomes remain unknown in JSON and text')

    altered = copy.deepcopy(fixture)
    altered['runs'][1]['conditions']['task'] = 'f' * 64
    altered['runs'].pop()
    excluded = json.loads(run(altered, '--json').stdout)
    assert excluded['matchedPairs'] == 1 and len(excluded['excluded']) == 2
    checks.append('missing and changed-task pairs are excluded rather than compared')

    altered = copy.deepcopy(fixture)
    for row in altered['runs']:
        row['comparisonCheck'] = 'failed'
    rejected = json.loads(run(altered, '--json').stdout)
    assert rejected['matchedPairs'] == rejected['inputTokens']['samples'] == rejected['seconds']['samples'] == 0
    assert rejected['reportedBaseline']['passed'] == 2 and rejected['reportedCandidate']['timeout'] == 1
    assert rejected['comparisonCheckFailedRuns'] == 6
    assert {x['reason'] for x in rejected['excluded']} == {'comparison_check_failed'}
    assert 'Pass-rate difference: unknown' in run(altered).stdout
    checks.append('failed comparison checks retain task outcomes but cannot produce rate or metric deltas')

    altered['schemaVersion'] = 1
    for row in altered['runs']:
        row.pop('comparisonCheck')
    unchecked = json.loads(run(altered, '--json').stdout)
    assert unchecked['matchedPairs'] == 0 and unchecked['comparisonCheckUnverifiedRuns'] == 6
    assert unchecked['reportedCandidate']['timeout'] == 1
    altered['schemaVersion'] = 2
    run(altered, '--json', success=False)
    checks.append('legacy missing checks remain unverified; version two requires an explicit check')

    altered = copy.deepcopy(fixture)
    altered['runs'][1]['conditions']['model'] = 'different-model'
    run(altered, '--json', success=False)
    altered = copy.deepcopy(fixture)
    altered['runs'].append(altered['runs'][0])
    run(altered, '--json', success=False)
    checks.append('mixed cohorts and duplicate results fail closed')

    altered = copy.deepcopy(fixture)
    altered['prompt'] = 'SYNTHETIC_PRIVATE_PROMPT'
    altered['verifierCommand'] = 'touch ' + str(home / 'must-not-exist')
    safe = run(altered, '--json').stdout
    assert 'SYNTHETIC_PRIVATE_PROMPT' not in safe and not (home / 'must-not-exist').exists()
    run(fixture, '--encoding', 'o200k_base', success=False)
    run(fixture, '--csv', success=False)
    checks.append('extra content is not exported or executed; unsupported options rejected')

    pipe = home / 'pipe'
    os.mkfifo(pipe)
    for path in [pipe, home]:
        result = subprocess.run([str(binary), 'agents', 'compare', str(path)], env=env,
                                text=True, capture_output=True, timeout=3)
        assert result.returncode != 0 and 'regular file' in result.stderr
    checks.append('FIFO and directory inputs are rejected without waiting for data')

print(json.dumps({'evidenceKind': 'synthetic', 'checksPassed': len(checks), 'checks': checks,
                  'notVerified': ['real model task effect', 'independent outcome authenticity', 'App integration', 'release installation']}, indent=2))
