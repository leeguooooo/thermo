"""Compiled CLI cleanup diagnostics against an owned loopback fixture; no real configs."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parents[1]
source = (root / 'Tests/AgentDoctorTests/MCPHTTPTests.swift').read_text()
code = re.search(r'let code = #"""\n(.*?)\n"""#', source, re.S).group(1)
with tempfile.TemporaryDirectory(prefix='thermo-cleanup-cli-') as temporary:
    home = Path(temporary)
    script = home / 'server.py'
    script.write_text(code)
    server = subprocess.Popen([sys.executable, str(script), str(home)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 5
        while not (home / 'port').exists():
            if server.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('Owned fixture did not become ready')
            time.sleep(0.01)
        port = int((home / 'port').read_text())
        config = home / '.codex/config.toml'
        config.parent.mkdir()
        def run(path, as_json=True):
            config.write_text('[mcp_servers.fixture]\nurl = "http://127.0.0.1:' + str(port) + path + '"\n')
            args = [str(binary), 'agents', 'inspect', 'fixture', '--agent', 'codex', '--timeout', '5']
            if as_json:
                args.append('--json')
            result = subprocess.run(args, env=dict(os.environ, CFFIXED_USER_HOME=str(home), THERMO_LANG='en'),
                                    capture_output=True, text=True, check=True, timeout=10)
            assert 'fixture-private' not in result.stdout and 'fixture-session' not in result.stdout
            return json.loads(result.stdout) if as_json else result.stdout
        reports = []
        for path, reason, status in [('/cleanup-error', 'httpError', 503),
                                     ('/cleanup-slow', 'timedOut', None),
                                     ('/no-session', 'notNeeded', None)]:
            report = run(path)
            assert report['complete'] and report['state'] == 'ready'
            details = report['cleanupDetails']
            assert details['reason'] == reason and details.get('httpStatusCode') == status
            reports.append({'path': path, 'cleanupStatus': report['cleanupStatus'], 'details': details})
        text = run('/cleanup-error', False)
        assert 'HTTP session cleanup: unconfirmed' in text
        assert 'Session closure returned an HTTP error' in text and 'HTTP 503' in text
        assert 'budget 0.250 s' in text
        refused = run('/cleanup-refused')
        assert refused['complete'] and refused['cleanupDetails']['reason'] == 'transportError'
        assert 'httpStatusCode' not in refused['cleanupDetails']
        log = [json.loads(line) for line in (home / 'log').read_text().splitlines()]
        assert not any(row['method'] == 'tools/call' for row in log)
        print(json.dumps({'passed': True, 'reports': reports, 'transportFailureVerified': True,
                          'textOutputShowsReasonStatusAndBudget': True, 'privateDetailsExcluded': True,
                          'noBusinessCalls': True, 'fixtureOnly': True}))
    finally:
        if server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
