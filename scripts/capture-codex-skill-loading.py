"""Probe owned Skill discovery and explicit loading through a loopback fake model.
Usage: python3 scripts/capture-codex-skill-loading.py NEW_OUTPUT_DIRECTORY CODEX_BINARY
Raw requests stay private. No real model, credentials or user Skill is used.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

arguments = argparse.ArgumentParser(description=__doc__)
arguments.add_argument('output_directory', type=Path)
arguments.add_argument('codex_binary', type=Path)
options = arguments.parse_args()
root = options.output_directory.resolve()
root.mkdir(mode=0o700)
binary = options.codex_binary.resolve()
runs = []
for case in ['catalog', 'explicit-user', 'duplicate-catalog', 'duplicate-explicit', 'alias-catalog', 'alias-explicit', 'copy-catalog', 'copy-explicit']:
    directory = root/case
    directory.mkdir(mode=0o700)
    home = directory/'home'
    codex_home = home/'.codex'
    codex_home.mkdir(parents=True, mode=0o700)
    project = directory/'project'
    project.mkdir()
    subprocess.run(['git', 'init', '--quiet', str(project)], check=True)
    scopes = {'legacy': codex_home/'skills', 'user': home/'.agents/skills', 'repo': project/'.agents/skills'}
    skills = []
    # Create the canonical user file before linking aliases in other scopes.
    for scope in (['user', 'legacy', 'repo'] if case.startswith(('alias', 'copy')) else scopes):
        parent = scopes[scope]
        name = 'owned-shared' if case.startswith(('duplicate', 'alias', 'copy')) else 'owned-'+scope
        folder = parent/name
        if case.startswith('alias') and scope != 'user':
            parent.mkdir(parents=True, exist_ok=True)
            folder.symlink_to(scopes['user']/name, target_is_directory=True)
            skills.append({'scope': scope, 'name': name, 'aliasOfUser': True,
                           'documentSHA256': hashlib.sha256((folder/'SKILL.md').read_bytes()).hexdigest()})
            continue
        if case.startswith('copy') and scope != 'user':
            (folder/'references').mkdir(parents=True)
            document = (scopes['user']/name/'SKILL.md').read_text()
            (folder/'SKILL.md').write_text(document)
            (folder/'references/details.md').write_text('OWNED_REFERENCE_USER\n')
            skills.append({'scope': scope, 'name': name, 'identicalCopyOfUser': True,
                           'documentSHA256': hashlib.sha256(document.encode()).hexdigest()})
            continue
        (folder/'references').mkdir(parents=True)
        marker = scope.upper()
        document = ('---\nname: '+name+'\ndescription: "OWNED_CATALOG_'+marker+' - Only an owned client-loading fixture."\n---\n\n'
                    'OWNED_BODY_'+marker+'\nReturn owned-client-fixture without running tools.\n'+
                    'Fixture body payload. '*128+'\nFor optional details, see [reference](references/details.md).\n')
        (folder/'SKILL.md').write_text(document)
        (folder/'references/details.md').write_text('OWNED_REFERENCE_'+marker+'\n')
        skills.append({'scope': scope, 'name': name, 'documentSHA256': hashlib.sha256(document.encode()).hexdigest()})
    observations = []
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *args):
            pass
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            coding = self.headers.get('Content-Encoding', '')
            if coding == 'gzip': body = gzip.decompress(body)
            elif coding == 'zstd':
                from compression import zstd
                body = zstd.decompress(body)
            request = json.loads(body)
            (directory/('request-private-'+str(len(observations))+'.json')).write_bytes(body)
            # Inspect the model input, not request options or a provider's fake usage.
            model_input = json.dumps(request.get('input'), ensure_ascii=False)
            observations.append({'onlyFakeCredential': self.headers.get('Authorization') == 'Bearer owned-loopback-key',
                                 'skills': [{'scope': scope,
                                             'catalogMarkerPresent': 'OWNED_CATALOG_'+scope.upper() in model_input,
                                             'catalogMarkerOccurrences': model_input.count('OWNED_CATALOG_'+scope.upper()),
                                             'bodyMarkerPresent': 'OWNED_BODY_'+scope.upper() in model_input,
                                             'referenceMarkerPresent': 'OWNED_REFERENCE_'+scope.upper() in model_input} for scope in scopes]})
            item = {'id': 'msg_owned', 'type': 'message', 'role': 'assistant', 'status': 'completed',
                    'content': [{'type': 'output_text', 'text': 'owned-client-fixture', 'annotations': []}]}
            response = {'id': 'resp_owned', 'object': 'response', 'created_at': 1, 'status': 'completed',
                        'model': request.get('model'), 'output': [item], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}
            events = [{'type': 'response.created', 'response': dict(response, status='in_progress', output=[])},
                      {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                      {'type': 'response.completed', 'response': response}]
            payload = ''.join('event: '+e['type']+'\ndata: '+json.dumps(e)+'\n\n' for e in events).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers(); self.wfile.write(payload); self.wfile.flush()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    instructions = directory/'owned-instructions.txt'
    instructions.write_text('Owned Skill loading fixture. Return the user-requested literal. No real model is connected.\n')
    config = '\n'.join(['model = "gpt-6.1-sol"', 'model_provider = "ownedloop"', 'web_search = "disabled"',
                        'model_instructions_file = '+json.dumps(str(instructions)), 'cli_auth_credentials_store = "file"',
                        'approval_policy = "never"', 'sandbox_mode = "read-only"', '[model_providers.ownedloop]',
                        'name = "Owned Loopback Fixture"', 'base_url = "http://127.0.0.1:'+str(server.server_port)+'/v1"',
                        'wire_api = "responses"', 'env_key = "THERMO_FAKE_PROVIDER_KEY"', 'requires_openai_auth = false',
                        'supports_websockets = false', 'request_max_retries = 0', 'stream_max_retries = 0',
                        '[projects.'+json.dumps(str(project))+']', 'trust_level = "trusted"', ''])
    (codex_home/'config.toml').write_text(config)
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(home), 'CODEX_HOME': str(codex_home),
           'XDG_CONFIG_HOME': str(home/'.config'), 'LANG': 'en_US.UTF-8', 'TERM': 'dumb',
           'THERMO_FAKE_PROVIDER_KEY': 'owned-loopback-key', 'NO_PROXY': '127.0.0.1,localhost', 'no_proxy': '127.0.0.1,localhost'}
    prompt = 'Return the literal owned-client-fixture without tools.'
    if case == 'explicit-user': prompt = 'Use $owned-user. '+prompt
    elif case in ['duplicate-explicit', 'alias-explicit', 'copy-explicit']: prompt = 'Use $owned-shared. '+prompt
    proc = None
    try:
        proc = subprocess.Popen([str(binary), 'exec', '--json', '--ephemeral', '--ignore-rules', '--sandbox', 'read-only',
                                 '--strict-config', '--color', 'never', '--cd', str(project), prompt], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try: stdout, stderr = proc.communicate(timeout=35)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM); stdout, stderr = proc.communicate(timeout=5)
        (directory/'events-private.jsonl').write_bytes(stdout)
        (directory/'stderr-private.txt').write_bytes(stderr)
        result = {'case': case, 'exitCode': proc.returncode, 'ownedSkills': skills, 'requests': observations}
        runs.append(result)
        print(json.dumps(result), flush=True)
    finally:
        if proc is not None and proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL); proc.wait(timeout=5)
        server.shutdown(); server.server_close(); thread.join(timeout=2)
    assert proc.returncode == 0 and len(observations) == 1
    assert observations[0]['onlyFakeCredential']
    assert any(skill['catalogMarkerPresent'] for skill in observations[0]['skills'])
collection = {'clientVersion': subprocess.check_output([str(binary), '--version'], text=True).strip(),
              'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'fixtureSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'realModelCalled': False, 'credentialsCopied': False, 'userSkillsModified': False,
              'syntheticUsageIsNotBilling': True, 'rawRequestsPublished': False, 'runs': runs}
(root/'collection.json').write_text(json.dumps(collection, indent=2)+'\n')
