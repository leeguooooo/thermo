"""Verify source-linked Skill loading using an owned log home; no Skill is executed."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

binary = Path(sys.argv[1]).resolve()
now = datetime.datetime.now(datetime.timezone.utc)
stamp = (now - datetime.timedelta(seconds=5)).isoformat().replace('+00:00', 'Z')
small = 'fixture-private-small-instruction'
large = 'fixture-private-large-instruction 中文'

def call(ident, name, skill=None):
    return {'type': 'assistant', 'timestamp': stamp, 'message': {'content': [
        {'type': 'tool_use', 'id': ident, 'name': name,
         'input': {'skill': skill, 'args': 'fixture-private-input'} if skill else {}}]}}

def result(ident):
    return {'type': 'user', 'timestamp': stamp, 'message': {'content': [
        {'type': 'tool_result', 'tool_use_id': ident, 'content': 'ack'}]}}

def load(ident, text, meta=True):
    return {'type': 'user', 'timestamp': stamp, 'isMeta': meta,
            'sourceToolUseID': ident, 'uuid': str(uuid.uuid4()),
            'message': {'content': [{'type': 'text', 'text': text}]}}

with tempfile.TemporaryDirectory(prefix='thermo-skill-loads-') as temporary:
    home = Path(temporary)
    file = home / '.claude/projects/owned/session.jsonl'
    file.parent.mkdir(parents=True)
    first = load('small', small)
    events = [first, first, call('small', 'Skill', 'fixture-small'), result('small'),
              call('large', 'Skill', 'fixture-large'), result('large'),
              load('large', large), load('large', large),
              call('unknown', 'Skill', 'fixture-unknown'), result('unknown'),
              load('large', 'fixture-private-user-text', meta=False),
              call('mcp', 'mcp__fixture__read'), result('mcp'), load('mcp', 'fixture-private-mcp-meta'),
              load('orphan', 'fixture-private-orphan')]
    file.write_text(''.join(json.dumps(e) + '\n' for e in events))
    env = dict(os.environ, CFFIXED_USER_HOME=str(home), THERMO_LANG='en')
    base = [str(binary), 'agents', 'usage', '--agent', 'claude', '--encoding', 'cl100k_base']
    raw = subprocess.check_output(base + ['--json'], env=env, text=True, timeout=30)
    report = json.loads(raw)
    rows = {row['name']: row for row in report['tools']}
    expected = {'fixture-small': (1, len(small.encode())), 'fixture-large': (2, 2 * len(large.encode())),
                'fixture-unknown': (0, 0)}
    for name, (count, size) in expected.items():
        row = rows[name]; measured = row['skillInstructions']
        assert measured['events'] == count and measured['textBytes'] == size, row
        assert row['returnedTextBytes'] == 3 and row['completed'] == 1, row
        assert row['unknownErrorStatus'] == 1, row
        assert measured['referenceTokens'] >= 0, measured
    assert rows['read'].get('skillInstructions') is None
    assert report['coverage']['unmatchedInstructionEvents'] == 1
    assert report['coverage']['duplicateRecords'] == 1
    assert not report['complete'] and not report['sessionTokens']
    text = subprocess.check_output(base, env=env, text=True, timeout=30)
    assert 'Linked instruction loads: 3' in text and 'total loading is unknown' in text
    assert 'fixture-private' not in raw + text
    ordered = json.loads(subprocess.check_output(base + ['--sort', 'instructions', '--json'], env=env, text=True, timeout=30))
    assert ordered['toolOrdering'] == 'instructions'
    assert {row['id']: row for row in ordered['tools']} == {row['id']: row for row in report['tools']}
    assert [row['name'] for row in ordered['tools'][:2]] == ['fixture-large', 'fixture-small']
    ordered_text = subprocess.check_output(base + ['--sort', 'instructions'], env=env, text=True, timeout=30)
    assert 'Tool ordering: instructions' in ordered_text and 'Observed instruction text tokens: unknown' in ordered_text
    assert 'Unknown or incomplete loading follows known counts' in ordered_text
    assert 'share of observed skill returned-text tokens' not in ordered_text
    assert 'fixture-private' not in ordered_text
    heuristic_text = subprocess.check_output(base[:-2] + ['--sort', 'instructions'], env=env, text=True, timeout=30)
    assert 'Observed instruction text tokens: ≈' in heuristic_text
    assert 'Observed instruction text tokens: unknown' in heuristic_text
    assert 'fixture-private' not in heuristic_text
    print(json.dumps({'passed': True, 'skillCalls': 3, 'linkedInstructionEvents': 3,
                      'linkedTextBytes': sum(size for _, size in expected.values()),
                      'acknowledgmentBytes': 9, 'duplicateLoadExcluded': True,
                      'unlinkedAndNonSkillMetadataExcluded': True, 'unknownLoadingNotZero': True,
                      'instructionTextNotExported': True, 'noSkillOrMCPExecution': True,
                      'instructionOrderingAndJSONVerified': True, 'allToolCountersUnchanged': True,
                      'heuristicCountsMarkedApproximate': True}))
