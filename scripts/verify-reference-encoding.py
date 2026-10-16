"""Compare the compiled, standalone CLI with fixed official tiktoken reference counts.
No Python tokenizer package or vocabulary files are used by the production binary.
"""
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
case = json.loads((root / 'Tests/AgentDoctorTests/Fixtures/tokenizer-cli-reference.json').read_text())
with tempfile.TemporaryDirectory(prefix='thermo-reference-encoding-') as temporary:
    home = Path(temporary)
    binary = home / 'thermo'
    shutil.copy2(Path(sys.argv[1]).resolve(), binary)
    skill = home / '.agents/skills/fixture/SKILL.md'
    skill.parent.mkdir(parents=True)
    skill.write_text(case['text'])
    server = home / 'fixture.py'
    server.write_text('import json,sys\nfor line in sys.stdin:\n r=json.loads(line)\n if "id" not in r: continue\n result={"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}} if r["method"]=="initialize" else {"tools":[' + repr(case['tool']) + ']}\n print(json.dumps({"jsonrpc":"2.0","id":r["id"],"result":result}),flush=True)\n')
    config = home / '.codex/config.toml'
    config.parent.mkdir(exist_ok=True)
    config.write_text('[mcp_servers.fixture]\ncommand = "/usr/bin/python3"\nargs = [' + json.dumps(str(server)) + ']\n')
    now = datetime.datetime.now(datetime.timezone.utc)
    def stamp(seconds):
        return (now + datetime.timedelta(seconds=seconds)).isoformat().replace('+00:00', 'Z')
    rows = []
    for ident in ['a', 'b']:
        rows += [{'timestamp': stamp(-10), 'type': 'response_item', 'payload': {'type': 'function_call', 'call_id': ident, 'name': 'mcp__fixture__read'}},
                 {'timestamp': stamp(-5), 'type': 'response_item', 'payload': {'type': 'function_call_output', 'call_id': ident, 'output': case['body']}}]
    log = home / '.codex/sessions/fixture.jsonl'
    log.parent.mkdir(parents=True)
    log.write_text(''.join(json.dumps(row) + '\n' for row in rows))
    environment = dict(os.environ, CFFIXED_USER_HOME=str(home), THERMO_LANG='en')
    def run(command, encoding):
        result = subprocess.run([str(binary), 'agents', *command, '--encoding', encoding, '--json'],
                                env=environment, cwd=home, capture_output=True, text=True, check=True, timeout=30)
        return json.loads(result.stdout)
    for encoding, expected in case['encodings'].items():
        report = run(['context', '--agent', 'codex'], encoding)
        footprint = report['skills'][0]['skillFootprint']
        assert footprint['document']['referenceTokens'] == expected['document']
        assert footprint['body']['referenceTokens'] == expected['body']
        assert footprint['catalog']['referenceTokens'] == expected['catalog']
        assert report['summaries'][0]['referenceDocumentTokens'] == expected['document']
        assert report['referenceEncoding'] == encoding and report['referenceEngine']
        inspected = run(['inspect', 'fixture', '--agent', 'codex'], encoding)
        assert inspected['complete'] and inspected['tools'][0]['definition']['referenceTokens'] == expected['definition']
        assert inspected['analysisSeconds'] >= 0 and inspected['listingSeconds'] >= 0
        usage = run(['usage', '--agent', 'codex'], encoding)
        assert usage['tools'][0]['referenceReturnedTextTokens'] == 2 * expected['body']
        assert not usage['sessionTokens'], 'no request tokens may be fabricated from returned text'
    invalid = subprocess.run([str(binary), 'agents', 'context', '--encoding', 'some-model-name'], env=environment, capture_output=True, text=True)
    assert invalid.returncode != 0
    print(json.dumps({'passed': True, 'encodings': list(case['encodings']), 'standaloneBinary': True,
                      'skillMCPAndUsageCountsMatchReference': True, 'modelNamesNotInferred': True}))
