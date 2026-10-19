"""Controlled Release CLI checks; only owned files and a stdio fixture are used."""
from pathlib import Path
import json,subprocess,os,tempfile,sys,datetime,hashlib,re
binary=Path(sys.argv[1]).resolve()
binary_before=hashlib.sha256(binary.read_bytes()).hexdigest()
source=Path(__file__).resolve().parent.parent
checks=[]
with tempfile.TemporaryDirectory(prefix='thermo-release-surfaces-') as directory:
 root=Path(directory);home=root/'home';home.mkdir();env={'PATH':'/usr/bin:/bin:/opt/homebrew/bin','HOME':str(home),'CFFIXED_USER_HOME':str(home),'THERMO_LANG':'en'}
 def run(args,success=True):
  p=subprocess.run([str(binary),*args],env=env,capture_output=True,text=True,timeout=30)
  assert p.returncode==(0 if success else 1),(p.returncode,p.stderr)
  if not success:assert 'thermo: Invalid run metadata, metrics or token accounting declaration' in p.stderr,p.stderr
  return p
 records=json.loads((source/'docs/examples/task-comparison.json').read_text())
 path=root/'records.json';path.write_text(json.dumps(records))
 normal=json.loads(run(['agents','compare',str(path),'--json']).stdout);assert normal['matchedPairs']==3
 for row in records['runs']:row['comparisonCheck']='failed'
 path.write_text(json.dumps(records));blocked=json.loads(run(['agents','compare',str(path),'--json']).stdout)
 assert blocked['matchedPairs']==0 and blocked['reportedBaseline']['passed']==2 and blocked['reportedCandidate']['timeout']==1
 assert blocked['inputTokens']['samples']==blocked['seconds']['samples']==0 and 'passRateDifferencePercentagePoints' not in blocked
 assert all(x['reason']=='comparison_check_failed' for x in blocked['excluded'])
 records['schemaVersion']=1
 for row in records['runs']:row.pop('comparisonCheck')
 path.write_text(json.dumps(records));legacy=json.loads(run(['agents','compare',str(path),'--json']).stdout)
 assert legacy['comparisonCheckUnverifiedRuns']==6 and legacy['matchedPairs']==0
 records['schemaVersion']=2;path.write_text(json.dumps(records));run(['agents','compare',str(path),'--json'],success=False)
 checks.append('post-run checks exclude invalid/legacy pairs, retain all outcomes and reject incomplete v2 records')

 media=json.dumps({'content':[{'type':'image','data':'PRIVATE_MEDIA_FIXTURE…559290 chars truncated…','mimeType':'image/png'}]},ensure_ascii=False)
 now=datetime.datetime.now(datetime.timezone.utc).timestamp();events=[]
 values=[('encoded',{'content':[{'type':'text','text':media}],'isError':False}),('native',{'content':[{'type':'image','data':'PRIVATE_MEDIA_FIXTURE','mimeType':'image/png'}],'isError':False})]
 for n,(name,result) in enumerate(values):
  events.append({'type':'event_msg','timestamp':datetime.datetime.fromtimestamp(now-5+n,datetime.timezone.utc).isoformat().replace('+00:00','Z'),'payload':{'type':'item_completed','started_at_ms':int((now-7+n)*1000),'completed_at_ms':int((now-5+n)*1000),'item':{'type':'McpToolCall','id':'owned_'+name,'server':'owned','tool':name,'status':'completed','result':result}}})
 path=root/'usage.jsonl';path.write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in events))
 for encoding in ['heuristic','cl100k_base']:
  text=run(['agents','usage','--agent','codex','--log-file',str(path),'--encoding',encoding,'--json']).stdout
  assert 'PRIVATE_MEDIA_FIXTURE' not in text
  report=json.loads(text);a=next(x for x in report['tools'] if x['name']=='encoded');b=next(x for x in report['tools'] if x['name']=='native')
  assert a['serializedMediaTextResults']==a['truncationMarkerResults']==1 and a['returnedTextBytes']==len(media.encode())
  assert b['serializedMediaTextResults']==b['truncationMarkerResults']==0 and b['returnedTextBytes']==0 and b['nonTextBlocks']==1
 checks.append('serialized media/truncation markers remain separate from native image blocks and text accounting in both encodings')

 script=root/'fixture.py';log=root/'rpc.jsonl';catalog=root/'catalog.json'
 script.write_text('''import json,sys
tools=json.load(open(sys.argv[1]))
for line in sys.stdin:
 try:r=json.loads(line)
 except ValueError:continue
 m=r.get('method','')
 with open(sys.argv[2],'a') as f:f.write(json.dumps({'method':m})+'\\n')
 if 'id' not in r:continue
 result={'jsonrpc':'2.0','id':r['id']}
 if m=='initialize':result['result']={'protocolVersion':r['params']['protocolVersion'],'capabilities':{'tools':{}},'serverInfo':{'name':'owned-release-fixture','version':'1'}}
 elif m=='tools/list':result['result']={'tools':tools}
 else:result['error']={'code':-32601,'message':'No business methods in this fixture'}
 print(json.dumps(result),flush=True)
''')
 schemas={'valid':{'type':'object','$defs':{'Step':{'type':'string'}},'properties':{'x':{'$ref':'#/$defs/Step'}}},'broken':{'type':'object','properties':{'x':{'$ref':'#/$defs/PRIVATE_MISSING'}}},'boolean':{'type':'object','properties':{'x':False}},'identified':{'type':'object','$id':'urn:owned:fixture','properties':{'x':{'$ref':'#/$defs/PRIVATE_MISSING'}}}}
 catalog.write_text(json.dumps([{'name':name,'description':'Owned offline fixture','inputSchema':schema} for name,schema in schemas.items()]))
 (home/'.codex').mkdir();(home/'.codex/config.toml').write_text('[mcp_servers.owned_release]\ncommand = "/usr/bin/python3"\nargs = '+json.dumps([str(script),str(catalog),str(log)])+'\n')
 text=run(['agents','inspect','owned_release','--agent','codex','--timeout','5','--json']).stdout;assert 'PRIVATE_MISSING' not in text
 report=json.loads(text);assert report['complete'] and report['state']=='ready' and len(report['tools'])==4
 for row in report['tools']:assert len(row['issues'])==(1 if row['name']=='broken' else 0)
 assert not any(json.loads(x)['method']=='tools/call' for x in log.read_text().splitlines())
 checks.append('local missing schema target diagnosed, valid/boolean/identified schemas not misreported; no tool call or reference leakage')
 plugin=home/'.codex/plugins/cache/owned/fixture/1';(plugin/'.codex-plugin').mkdir(parents=True);(plugin/'references').mkdir()
 (plugin/'.codex-plugin/plugin.json').write_text(json.dumps({'name':'fixture','skills':['./','.']}))
 (plugin/'SKILL.md').write_text('---\nname: owned-root\ndescription: fixture\n---\n[valid](references/guide)\n[missing](references/absent)\n')
 (plugin/'references/guide').write_text('fixture')
 context=json.loads(run(['agents','context','--agent','codex','--json']).stdout);assert len(context['skills'])==1
 item=context['skills'][0];footprint=item['skillFootprint'];assert footprint['scope']=='cache' and not item.get('actions')
 issues=footprint['quality']['issues']
 assert footprint['quality']['checkedLocalReferences']==2 and len(issues)==2
 assert {(x['code'],x.get('target')) for x in issues}=={('missing_local_reference','references/absent'),('plugin_root_skill_layout',None)}
 assert item['severity']=='info'
 checks.append('root-declared cached Skill counted once with an informational layout hint and no mutation actions; extensionless references checked')
 logs=home/'.codex/sessions';logs.mkdir();clock=datetime.datetime.now(datetime.timezone.utc)
 def count_event(seconds,value):
  return {'type':'event_msg','timestamp':(clock+datetime.timedelta(seconds=seconds)).isoformat(),'payload':{'type':'token_count','info':{'total_token_usage':{'input_tokens':value,'output_tokens':20},'last_token_usage':{'input_tokens':99999,'output_tokens':99999}}}}
 a=logs/'rollout-11111111-1111-4111-8111-111111111111.jsonl';b=logs/'rollout-22222222-2222-4222-8222-222222222222.jsonl'
 events=[count_event(-9,100),count_event(-8,120),count_event(-8,120),count_event(-9,100),count_event(-7,110)]
 events.append({'type':'token_usage_record','timestamp':(clock-datetime.timedelta(seconds=6)).isoformat(),'payload':{'response_id':'resp_owned','usage':{'input_tokens':25,'output_tokens':2}}})
 a.write_text(''.join(json.dumps(x)+'\n' for x in events));b.write_text(''.join(json.dumps(x)+'\n' for x in [count_event(-5,200),count_event(-5,201)]))
 usage=json.loads(run(['agents','usage','--agent','codex','--json']).stdout);snapshots=usage['cumulativeTokenSnapshots'];assert len(snapshots)==2
 assert [x['inputTokens'] for x in snapshots if 'inputTokens' in x]==[110]
 conflict=next(x for x in snapshots if x['conflictingLatestRecords']);assert 'inputTokens' not in conflict and 'outputTokens' not in conflict
 assert usage['sessionTokens'][0]['inputTokens']==25 and usage['sessionTokens'][0]['requests']==1
 assert not usage['tools'] and usage['coverage']['unsupportedUsageRecords']==0
 checks.append('latest cumulative counters, decreases and conflicts stay separate from requests and tools')

 def protocol(offset,payload):
  return {'type':'response_item','timestamp':(clock+datetime.timedelta(seconds=offset)).isoformat(),'payload':payload}
 blocks=json.dumps([{'type':'input_text','text':'fixture-result'}, {'type':'input_image','image_url':'data:image/png;base64,PRIVATE_NAMESPACE_IMAGE'}])
 namespaced=[
  protocol(-20,{'type':'function_call','call_id':'owned-ns','namespace':'mcp__owned_format','name':'inspect','arguments':'PRIVATE_NAMESPACE_ARGUMENT'}),
  protocol(-17,{'type':'function_call_output','call_id':'owned-ns','output':blocks}),
  protocol(-16,{'type':'function_call','call_id':'owned-legacy','name':'mcp__owned_format__inspect','arguments':'PRIVATE_NAMESPACE_ARGUMENT'}),
  protocol(-15,{'type':'function_call_output','call_id':'owned-legacy','output':json.dumps({'isError':False,'content':[{'type':'text','text':'legacy'}]})}),
  protocol(-14,{'type':'function_call','call_id':'owned-clock','namespace':'clock','name':'inspect','arguments':'PRIVATE_NAMESPACE_ARGUMENT'}),
  protocol(-12,{'type':'function_call_output','call_id':'owned-clock','output':json.dumps([{'type':'input_text','text':'clock'}])})]
 path=root/'namespaced.jsonl';path.write_text(''.join(json.dumps(x)+'\n' for x in namespaced))
 text=run(['agents','usage','--agent','codex','--log-file',str(path),'--encoding','cl100k_base','--json']).stdout
 namespaced_report=json.loads(text);rows=namespaced_report['tools']
 assert len(rows)==1 and rows[0]['server']=='owned_format' and rows[0]['name']=='inspect'
 row=rows[0]
 assert row['calls']==row['completed']==row['timingSamples']==2, 'separate Codex MCP namespace must group with its legacy name'
 assert row['returnedTextBytes']==20 and row['nonTextBlocks']==1 and row['unknownErrorStatus']==1
 assert row['reportedErrors']==0 and row['totalObservedSeconds']==4
 outer=namespaced_report['coverage']['unattributedResults']['byTool']
 assert len(outer)==1 and outer[0]['name']=='clock.inspect' and outer[0]['calls']==1
 for private in ['PRIVATE_NAMESPACE_ARGUMENT','PRIVATE_NAMESPACE_IMAGE','fixture-result']:assert private not in text
 checks.append('separate Codex namespaces group with legacy MCP names; native images excluded and same-name outer tools stay distinct')
 # Result envelopes and text-only host blocks have different structured-content coverage.
 coverage=row.get('structuredContent')
 assert coverage is not None, 'structured-content coverage was not measured'
 assert coverage['inspectedResultObjects']==coverage['unobservableResults']==1
 assert coverage['structuredResults']==0
 body={'value':'PRIVATE_STRUCTURED_VALUE'}
 structured=[
  protocol(-8,{'type':'function_call','call_id':'owned-structured','namespace':'mcp__owned_format','name':'structured','arguments':'PRIVATE_STRUCTURED_ARGUMENT'}),
  protocol(-6,{'type':'function_call_output','call_id':'owned-structured','output':json.dumps({'isError':False,'content':[{'type':'text','text':'OK'}],'structuredContent':body})})]
 path=root/'structured.jsonl';path.write_text(''.join(json.dumps(x)+'\n' for x in structured))
 text=run(['agents','usage','--agent','codex','--log-file',str(path),'--encoding','cl100k_base','--json']).stdout
 row=json.loads(text)['tools'][0];usage=row['structuredContent']
 assert row['returnedTextBytes']==2 and usage['jsonBytes']==len(json.dumps(body,separators=(',',':'),ensure_ascii=False).encode())
 assert usage['structuredResults']==usage['alongsideContentResults']==usage['inspectedResultObjects']==1
 assert usage['unobservableResults']==usage['unavailableJSONResults']==0 and usage['jsonReferenceTokens']>0
 assert 'PRIVATE_STRUCTURED_VALUE' not in text and 'PRIVATE_STRUCTURED_ARGUMENT' not in text
 checks.append('structured JSON is measured separately from acknowledgment text; unavailable envelopes stay unknown and payloads are not exported')
 shapes=[('object',{'n':1}),('array',[{'text':'PRIVATE_JSON_ARRAY'}]*20),('string','PRIVATE_JSON_STRING'),('number',42),('boolean',True),('null',None)]
 events=[]
 for i,(name,value) in enumerate(shapes):
  events.extend([protocol(-40+i*3,{'type':'function_call','call_id':'json-'+name,'name':'mcp__owned_values__'+name,'arguments':'PRIVATE_JSON_ARGUMENT'}),
                 protocol(-39+i*3,{'type':'function_call_output','call_id':'json-'+name,'output':json.dumps({'isError':False,'content':[{'type':'text','text':'OK'}],'structuredContent':value})})])
 path=root/'json-values.jsonl';path.write_text(''.join(json.dumps(x)+'\n' for x in events))
 text=run(['agents','usage','--agent','codex','--log-file',str(path),'--encoding','cl100k_base','--sort','structured','--json']).stdout
 value_report=json.loads(text);rows=value_report['tools'];assert len(rows)==6 and rows[0]['name']=='array'
 for row in rows:
  value=dict(shapes)[row['name']];usage=row['structuredContent']
  assert usage['jsonBytes']==len(json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode())
  assert usage['structuredResults']==usage['inspectedResultObjects']==usage['alongsideContentResults']==1
  assert usage['unavailableJSONResults']==0 and usage['jsonReferenceTokens']>0 and row['returnedTextBytes']==2
 assert 'PRIVATE_JSON_' not in text
 summary=value_report['mcpStructuredSummary']
 assert value_report['singleLogWindow']=='head'
 assert summary['totalJSONBytes']==summary['knownJSONBytes']==sum(x['structuredContent']['jsonBytes'] for x in rows)
 assert summary['totalJSONTokens']==sum(x['structuredContent']['jsonReferenceTokens'] for x in rows)
 assert summary['completedResults']==summary['checkedEnvelopes']==6 and summary['missingResults']==0
 human=run(['agents','usage','--agent','codex','--log-file',str(path),'--encoding','cl100k_base','--sort','structured']).stdout
 assert 'Observed MCP structured JSON total within selected logs:' in human
 assert human.count('JSON value measurement does not infer')==1, 'shared JSON caveats must not repeat on every row'
 tail_report=json.loads(run(['agents','usage','--agent','codex','--log-file',str(path),'--tail','--encoding','cl100k_base','--sort','structured','--json']).stdout)
 assert tail_report['singleLogWindow']=='tail' and tail_report['complete']
 assert tail_report['tools']==value_report['tools'] and tail_report['mcpStructuredSummary']==summary
 incomplete=events+[protocol(-5,{'type':'function_call','call_id':'json-missing','name':'mcp__owned_values__missing','arguments':'{}'})]
 partial=root/'json-missing.jsonl';partial.write_text(''.join(json.dumps(x)+'\n' for x in incomplete))
 partial_summary=json.loads(run(['agents','usage','--agent','codex','--log-file',str(partial),'--encoding','cl100k_base','--json']).stdout)['mcpStructuredSummary']
 assert partial_summary['missingResults']==1 and partial_summary['knownJSONBytes']==summary['knownJSONBytes']
 assert partial_summary.get('totalJSONBytes') is None and partial_summary.get('totalJSONTokens') is None
 checks.append('all JSON value shapes are measured, null differs from absence, array ranking recovers and returned-text accounting stays separate')
 checks.append('structured JSON totals cover all MCP rows; missing replies preserve the known subset while totals stay unknown')
 checks.append('explicit selected-file head and tail windows are recorded; a small tail preserves complete row measurements')
 ordering=[]
 values=[('ascii','a'*1000,{'n':1}),('unicode','你好'*100,{'n':2}),('wide','OK',{'body':'PRIVATE_SORT_BODY '*100}),('zero','OK',None),('unknown','OK',None)]
 for i,(name,ack,body) in enumerate(values):
  result={'isError':False,'content':[{'type':'text','text':ack}]}
  if body is not None:result['structuredContent']=body
  output=json.dumps([{'type':'input_text','text':'OK'}]) if name=='unknown' else json.dumps(result)
  ordering.extend([protocol(-18+i*3,{'type':'function_call','call_id':'sort-'+name,'name':'mcp__owned_sort__'+name,'arguments':'PRIVATE_SORT_ARGUMENT'}),protocol(-16+i*3,{'type':'function_call_output','call_id':'sort-'+name,'output':output})])
 path=root/'ordering.jsonl';path.write_text(''.join(json.dumps(x)+'\n' for x in ordering))
 args=['agents','usage','--agent','codex','--log-file',str(path),'--encoding','cl100k_base','--no-color']
 text=json.loads(run(args+['--json']).stdout);structured=json.loads(run(args+['--sort','structured','--json']).stdout)
 assert text['toolOrdering']=='text' and structured['toolOrdering']=='structured'
 assert text['tools'][0]['name']=='unicode', 'default CLI order must use reference tokens rather than bytes'
 assert [x['name'] for x in structured['tools']][0]=='wide' and [x['name'] for x in structured['tools']][-2:]==['zero','unknown']
 assert {x['id']:x for x in text['tools']}=={x['id']:x for x in structured['tools']}
 human=run(args+['--sort','structured','--all']).stdout
 assert re.findall(r'^owned_sort / ([a-z_]+) \[codex, mcp\]$',human,re.M)==[x['name'] for x in structured['tools']]
 assert 'share of observed mcp returned-text tokens' not in human
 assert 'PRIVATE_SORT_' not in json.dumps(structured) and 'PRIVATE_SORT_' not in human
 checks.append('CLI text and structured token order is declared in JSON, shared with human output, preserves metrics and keeps known zero before unknown')
assert hashlib.sha256(binary.read_bytes()).hexdigest()==binary_before, 'input binary changed during contract checks'
print(json.dumps({'fixtureOnly':True,'binarySHA256':binary_before,'groupsPassed':len(checks),'checks':checks,'modelsOrDevicesUsed':False},indent=2))
# Test: python3 scripts/verify-ai-diagnostics-contract.py /path/to/thermo
