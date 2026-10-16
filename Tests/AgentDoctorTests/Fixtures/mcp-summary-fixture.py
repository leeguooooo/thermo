import json,sys,time
kind=sys.argv[1]
for line in sys.stdin:
    request=json.loads(line)
    if 'id' not in request: continue
    if kind=='slow': time.sleep(30)
    if request['method']=='initialize':
        result={'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'summary-fixture','version':'1'},'instructions':'x'*(4 if kind=='small' else 12)}
    elif request['method']=='tools/list':
        tools=[{'name':'small_read','description':'Read fixture','inputSchema':{'type':'object'}}] if kind=='small' else [{'name':'large_read','description':'x'*400,'inputSchema':{'type':'object'}},{'name':'blank_description','description':'','inputSchema':{'type':'object'}}]
        result={'tools':tools}
    else: result={}
    print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
