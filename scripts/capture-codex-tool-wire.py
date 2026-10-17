"""Capture Codex tool serialization with a loopback-only fake Responses endpoint.
No real model, authentication copy, or business MCP tool is used.
Usage: python3 scripts/capture-codex-tool-wire.py OUTPUT_DIRECTORY CODEX_BINARY
"""
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

exercise = '--exercise-tools' in sys.argv
if exercise:sys.argv.remove('--exercise-tools')
root = Path(sys.argv[1]).resolve()
root.mkdir(mode=0o700)
binary = Path(sys.argv[2]).resolve()
MCP = r'''
import json,sys
mode=sys.argv[1]
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
  value='OWNED_SERVER_ECHO_ACK:'+request['params']['arguments']['value']
  result={'content':[{'type':'text','text':value}],'structuredContent':{'value':value},'isError':False}
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
                program = 'text(ALL_TOOLS.filter(t => t.name.includes("wirefixture")).map(t => ({name:t.name,description:t.description})));' if number == 0 else 'const r = await tools.mcp__wirefixture__echo({value:"OWNED_ECHO_REQUEST"}); for (const c of r.content ?? []) if (c.type === "text") text(c.text);'
                message = {'id':'ctc_owned_'+str(number),'type':'custom_tool_call','status':'completed','call_id':'owned_call_'+str(number),'name':'exec','namespace':'functions','input':program}
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
        'args = '+json.dumps([str(script),mode,str(directory/'mcp-methods.jsonl')]),'startup_timeout_sec = 10',
        '[projects.'+json.dumps(str(project))+']','trust_level = "trusted"',''])
    (codex_home/'config.toml').write_text(config)
    env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(home),'CODEX_HOME':str(codex_home),
           'XDG_CONFIG_HOME':str(home/'.config'),'LANG':'en_US.UTF-8','TERM':'dumb',
           'THERMO_FAKE_PROVIDER_KEY':'owned-loopback-key','NO_PROXY':'127.0.0.1,localhost','no_proxy':'127.0.0.1,localhost'}
    proc = None
    try:
        proc = subprocess.Popen([str(binary),'exec','--json','--ephemeral','--ignore-rules','--sandbox','read-only',
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
    result['wireObservations'] = []
    for request_path in sorted(directory.glob('request-private-*.json')):
        raw = request_path.read_text()
        request = json.loads(raw)
        outputs = [item for item in request.get('input',[]) if item.get('type') == 'custom_tool_call_output']
        result['wireObservations'].append({
            'requestIndex': int(request_path.stem.rsplit('-',1)[1]),
            'inputDeclarationMarkerPresent': 'OWNED_INPUT_SCHEMA_MARKER' in raw,
            'outputDeclarationMarkerPresent': 'OWNED_OUTPUT_ONLY_MARKER' in raw,
            'serverAckInToolOutput': any('OWNED_SERVER_ECHO_ACK:OWNED_ECHO_REQUEST' in json.dumps(item.get('output')) for item in outputs),
            'rootToolsPresent': 'tools' in request,
            'additionalToolsInputPresent': any(item.get('type') == 'additional_tools' for item in request.get('input',[]))})
    if exercise:
        assert result['exitCode'] == 0 and methods.count('tools/call') == 1, result
        assert len(result['wireObservations']) == 3, result
        first, discovered, invoked = result['wireObservations']
        assert not first['inputDeclarationMarkerPresent']
        assert discovered['inputDeclarationMarkerPresent'] and invoked['serverAckInToolOutput']
        assert not any(item['outputDeclarationMarkerPresent'] for item in result['wireObservations'])
(root/'collection.json').write_text(json.dumps({'clientVersion':subprocess.check_output([str(binary),'--version'],text=True).strip(),
                                            'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),
                                            'fixtureSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                            'exerciseTools':exercise,'runs':results},indent=2)+'\n')
