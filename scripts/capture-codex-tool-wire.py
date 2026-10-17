"""Capture Codex tool serialization with a loopback-only fake Responses endpoint.
No real model, authentication copy, or business MCP tool is used.
Usage: python3 scripts/capture-codex-tool-wire.py OUTPUT_DIRECTORY CODEX_BINARY [--exercise-tools] [--persist-session] [--mcp-media image]
Code-mode features are explicit; discovery placement is observed, not assumed.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

arguments = argparse.ArgumentParser(description=__doc__)
arguments.add_argument('output_directory', type=Path)
arguments.add_argument('codex_binary', type=Path)
arguments.add_argument('--exercise-tools', action='store_true')
arguments.add_argument('--persist-session', action='store_true')
arguments.add_argument('--mcp-outcome', choices=['success', 'application-error', 'protocol-error'], default='success')
arguments.add_argument('--mcp-media', choices=['text', 'image'], default='text')
options = arguments.parse_args()
if options.mcp_media == 'image' and options.mcp_outcome != 'success':
    arguments.error('--mcp-media image requires --mcp-outcome success')
exercise = options.exercise_tools
persist_session = options.persist_session
root = options.output_directory.resolve()
root.mkdir(mode=0o700)
binary = options.codex_binary.resolve()
MCP = r'''
import json,sys
mode=sys.argv[1]
outcome=sys.argv[3]
media=sys.argv[4]
for line in sys.stdin:
 request=json.loads(line)
 with open(sys.argv[2],'a') as log:log.write(json.dumps({'method':request.get('method')})+'\n')
 method=request.get('method')
 if 'id' not in request:continue
 if method=='initialize':result={'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'owned-wire-fixture','version':'1'}}
 elif method=='tools/list':
  tool={'name':'echo','description':'Owned read-only echo fixture.','inputSchema':{'type':'object','properties':{'value':{'type':'string','description':'OWNED_INPUT_SCHEMA_MARKER'}},'required':['value'],'additionalProperties':False},'annotations':{'readOnlyHint':True,'destructiveHint':False}}
  if mode=='full':tool['outputSchema']={'type':'object','properties':{'value':{'type':'string','description':'OWNED_OUTPUT_ONLY_MARKER '*1024}},'required':['value'],'additionalProperties':False}
  result={'tools':[tool]}
 elif method=='tools/call':
  assert request['params']['name']=='echo'
  if outcome=='protocol-error':
   print(json.dumps({'jsonrpc':'2.0','id':request['id'],'error':{'code':-32000,'message':'OWNED_PROTOCOL_ERROR'}}),flush=True);continue
  value='OWNED_APPLICATION_ERROR' if outcome=='application-error' else 'OWNED_SERVER_ECHO_ACK:'+request['params']['arguments']['value']
  result={'content':[{'type':'text','text':value}],'structuredContent':{'value':value},'isError':outcome=='application-error'}
  if media=='image':
   result.pop('structuredContent')
   result['content'].append({'type':'image','data':'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGNQSFhAEmIY1TCqYfhqAACc2CAQXseIAgAAAABJRU5ErkJggg==','mimeType':'image/png'})
 elif method=='ping':result={}
 else:
  print(json.dumps({'jsonrpc':'2.0','id':request['id'],'error':{'code':-32601,'message':'Only metadata is supported'}}),flush=True);continue
 print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
'''
script = root / 'mcp-fixture.py'
script.write_text(MCP)
results = []
for mode in ['full', 'off']:
    directory = root / mode
    directory.mkdir(mode=0o700)
    home = directory / 'home'
    codex_home = home / '.codex'
    codex_home.mkdir(parents=True, mode=0o700)
    project = directory / 'project'
    project.mkdir()
    subprocess.run(['git','init','--quiet',str(project)],check=True)
    requests = []
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self,*args):
            pass
        def do_GET(self):
            requests.append({'method':'GET','path':self.path})
            body = json.dumps({'models':[],'object':'list','data':[]}).encode()
            self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('Content-Length','0')))
            coding = self.headers.get('Content-Encoding','')
            if coding == 'gzip':body = gzip.decompress(body)
            elif coding == 'zstd':
                from compression import zstd
                body = zstd.decompress(body)
            request = json.loads(body)
            number = len([r for r in requests if r['method']=='POST'])
            (directory / ('request-private-'+str(number)+'.json')).write_bytes(body)
            requests.append({'method':'POST','path':self.path,'requestBytes':len(body),
                             'onlyFakeCredential':self.headers.get('Authorization')=='Bearer owned-loopback-key'})
            message = {'id':'msg_owned_fixture','type':'message','role':'assistant','status':'completed',
                       'content':[{'type':'output_text','text':'owned-client-fixture','annotations':[]}]}
            if exercise and number < 2:
                program = 'text(ALL_TOOLS.filter(t => t.name.includes("wirefixture")).map(t => ({name:t.name,description:t.description})));' if number == 0 else 'const r = await tools.mcp__wirefixture__echo({value:"OWNED_ECHO_REQUEST"}); for (const c of r.content ?? []) { if (c.type === "text") text(c.text); else if (c.type === "image") image(c); }'
                message = {'id':'ctc_owned_'+str(number),'type':'custom_tool_call','status':'completed','call_id':'owned_call_'+str(number),'name':'exec','input':program}
                # CLI builds may advertise exec at the root or in a namespace.
                root_exec = any(t.get('name') == 'exec' and t.get('type') == 'custom' for t in request.get('tools', []))
                if not root_exec:
                    namespaces = [t['name'] for t in request.get('tools', []) if t.get('type') == 'namespace' and any(c.get('name') == 'exec' for c in t.get('tools', []))]
                    assert len(namespaces) == 1, 'No unambiguous advertised exec entry point'
                    message['namespace'] = namespaces[0]
            response = {'id':'resp_owned_fixture' ,'object':'response','created_at':1,'status':'completed',
                        'model':request.get('model','fixture'),'output':[message],
                        'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}
            events = [{'type':'response.created','response':dict(response,status='in_progress',output=[])},
                      {'type':'response.output_item.done','output_index':0,'item':message},
                      {'type':'response.completed','response':response}]
            payload = ''.join('event: '+e['type']+'\ndata: '+json.dumps(e)+'\n\n' for e in events).encode()
            self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(payload)));self.end_headers();self.wfile.write(payload);self.wfile.flush()
    server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever,daemon=True)
    thread.start()
    instructions = directory / 'owned-instructions.txt'
    instructions.write_text('This is an owned client serialization fixture. Follow the user prompt. No real model is connected.\n')
    config = '\n'.join([
        'model = "gpt-6.1-sol"','model_provider = "ownedloop"','web_search = "disabled"',
        'model_instructions_file = '+json.dumps(str(instructions)),
        'cli_auth_credentials_store = "file"','approval_policy = "never"','sandbox_mode = "read-only"',
        '[model_providers.ownedloop]','name = "Owned Loopback Fixture"',
        'base_url = "http://127.0.0.1:'+str(server.server_port)+'/v1"','wire_api = "responses"',
        'env_key = "THERMO_FAKE_PROVIDER_KEY"','requires_openai_auth = false','supports_websockets = false',
        'request_max_retries = 0','stream_max_retries = 0',
        '[mcp_servers.wirefixture]','command = "/usr/bin/python3"',
        'args = '+json.dumps([str(script),mode,str(directory/'mcp-methods.jsonl'),options.mcp_outcome,options.mcp_media]),'startup_timeout_sec = 10',
        '[features]','code_mode = true','code_mode_only = true',
        '[projects.'+json.dumps(str(project))+']','trust_level = "trusted"',''])
    (codex_home/'config.toml').write_text(config)
    env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(home),'CODEX_HOME':str(codex_home),
           'XDG_CONFIG_HOME':str(home/'.config'),'LANG':'en_US.UTF-8','TERM':'dumb',
           'THERMO_FAKE_PROVIDER_KEY':'owned-loopback-key','NO_PROXY':'127.0.0.1,localhost','no_proxy':'127.0.0.1,localhost'}
    proc = None
    try:
        proc = subprocess.Popen([str(binary),'exec','--json',*([] if persist_session else ['--ephemeral']),'--ignore-rules','--sandbox','read-only',
                                 '--strict-config','--color','never','--cd',str(project),
                                 'Exercise the owned fixture discovery and echo tools, then return owned-client-fixture.' if exercise else 'Return the literal owned-client-fixture. Do not call tools.'],
                                env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        try:stdout,stderr = proc.communicate(timeout=35)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid,signal.SIGTERM);stdout,stderr = proc.communicate(timeout=5)
        (directory/'events-private.jsonl').write_bytes(stdout)
        (directory/'stderr-private.txt').write_bytes(stderr)
        summary = {'mode':mode,'exitCode':proc.returncode,'requests':requests,'authCopyCreated':False,
                   'realProviderCalled':False,'fakeUsageIsNotBilling':True}
        results.append(summary)
        print(json.dumps(summary),flush=True)
    finally:
        if proc is not None and proc.poll() is None:
            os.killpg(proc.pid,signal.SIGKILL);proc.wait(timeout=5)
        server.shutdown();server.server_close();thread.join(timeout=2)
# Publish only owned markers and protocol metadata, never captured instructions.
for result in results:
    directory = root / result['mode']
    methods = [json.loads(line)['method'] for line in (directory/'mcp-methods.jsonl').read_text().splitlines()]
    result['mcpMethods'] = methods
    if persist_session:
        logs = list((directory/'home/.codex/sessions').rglob('*.jsonl'))
        native_calls = []
        wrapper_calls = 0
        for log in logs:
            for line in log.open():
                event = json.loads(line)
                payload = event.get('payload', {})
                item = payload.get('item', {})
                if event.get('type') == 'response_item' and payload.get('type') == 'custom_tool_call':
                    wrapper_calls += 1
                if event.get('type') == 'event_msg' and payload.get('type') == 'item_completed' and item.get('type') == 'McpToolCall':
                    native_result = item.get('result') or {}
                    native_calls.append({'ownedEcho': item.get('server') == 'wirefixture' and item.get('tool') == 'echo',
                                         'status': item.get('status'), 'hasResult': item.get('result') is not None,
                                         'explicitErrorFlag': native_result.get('isError'),
                                         'errorFieldPresent': item.get('error') is not None,
                                         'hasStartAndEndMilliseconds': isinstance(payload.get('started_at_ms'), int) and isinstance(payload.get('completed_at_ms'), int)})
                elif event.get('type') == 'event_msg' and payload.get('type') == 'mcp_tool_call_end':
                    invocation = payload.get('invocation', {})
                    outcome = payload.get('result', {})
                    native_result = outcome.get('Ok') or {}
                    native_calls.append({'ownedEcho': invocation.get('server') == 'wirefixture' and invocation.get('tool') == 'echo',
                                         'eventFormat': 'mcp_tool_call_end', 'hasResult': 'Ok' in outcome,
                                         'explicitErrorFlag': native_result.get('isError'), 'errorFieldPresent': 'Err' in outcome,
                                         'hasDuration': isinstance(payload.get('duration'), dict),
                                         'imageBlocks': sum(c.get('type') == 'image' for c in native_result.get('content', []))})
        result['persistedLogObservations'] = {'files': len(logs), 'customToolCalls': wrapper_calls, 'nativeMCPCalls': native_calls}
        if exercise:
            assert len(logs) == 1 and wrapper_calls == 2 and len(native_calls) == 1
            assert native_calls[0]['ownedEcho'] and (native_calls[0].get('hasStartAndEndMilliseconds') or native_calls[0].get('hasDuration'))
    result['wireObservations'] = []
    for request_path in sorted(directory.glob('request-private-*.json')):
        raw = request_path.read_text()
        request = json.loads(raw)
        outputs = [item for item in request.get('input',[]) if item.get('type') == 'custom_tool_call_output']
        blocks = [block for item in outputs if isinstance(item.get('output'), list) for block in item['output']]
        result['wireObservations'].append({
            'requestIndex': int(request_path.stem.rsplit('-',1)[1]),
            'inputDeclarationMarkerPresent': 'OWNED_INPUT_SCHEMA_MARKER' in raw,
            'outputDeclarationMarkerPresent': 'OWNED_OUTPUT_ONLY_MARKER' in raw,
            'serverAckInToolOutput': any('OWNED_SERVER_ECHO_ACK:OWNED_ECHO_REQUEST' in json.dumps(item.get('output')) for item in outputs),
            'applicationErrorInToolOutput': any('OWNED_APPLICATION_ERROR' in json.dumps(item.get('output')) for item in outputs),
            'protocolErrorInToolOutput': any('OWNED_PROTOCOL_ERROR' in json.dumps(item.get('output')) for item in outputs),
            'inputImageBlocks': sum(block.get('type') == 'input_image' for block in blocks),
            'rootToolsPresent': 'tools' in request,
            'additionalToolsInputPresent': any(item.get('type') == 'additional_tools' for item in request.get('input',[]))})
    if exercise:
        assert result['exitCode'] == 0 and methods.count('tools/call') == 1, result
        assert len(result['wireObservations']) == 3, result
        first, discovered, invoked = result['wireObservations']
        assert discovered['inputDeclarationMarkerPresent']
        marker = {'success':'serverAckInToolOutput','application-error':'applicationErrorInToolOutput','protocol-error':'protocolErrorInToolOutput'}[options.mcp_outcome]
        assert invoked[marker]
        if options.mcp_media == 'image':
            assert invoked['inputImageBlocks'] == 1, result
(root/'collection.json').write_text(json.dumps({'clientVersion':subprocess.check_output([str(binary),'--version'],text=True).strip(),
                                            'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),
                                            'fixtureSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                            'exerciseTools':exercise,'persistSession':persist_session,'mcpOutcome':options.mcp_outcome,
                                            'mcpMedia':options.mcp_media,'explicitFeatures':{'code_mode':True,'code_mode_only':True},
                                            'runs':results},indent=2)+'\n')
