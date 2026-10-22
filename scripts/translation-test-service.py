#!/usr/bin/env python3
"""Synthetic loopback-only translation fixture. Never use real credentials or user text."""
import argparse
import json
from pathlib import Path
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir',type=Path,required=True)
args=parser.parse_args()
root=args.output_dir.resolve();root.mkdir(parents=True,exist_ok=True)
lock=threading.Lock()
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        size=int(self.headers.get('Content-Length','0'))
        if size>1000000:self.send_error(413);return
        body=self.rfile.read(size)
        try: data=json.loads(body);texts=json.loads(data['messages'][1]['content'])
        except Exception: self.send_error(400);return
        with lock:
            with (root/'requests.jsonl').open('a') as stream:
                stream.write(json.dumps({'path':self.path,'texts':texts,'authorizationPresent':bool(self.headers.get('Authorization'))},ensure_ascii=False)+'\n')
        if self.path=='/redirect':
            self.send_response(302);self.send_header('Location',f'http://127.0.0.1:{self.server.server_port}/forbidden');self.send_header('Content-Length','0');self.end_headers();return
        if self.path=='/slow':time.sleep(2)
        translated=['你好' if text=='Hello' else '测试译文'+str(i+1) for i,text in enumerate(texts)]
        content=json.dumps(translated,ensure_ascii=False)
        if self.path=='/mismatch':content='[]'
        response=json.dumps({'choices':[{'message':{'content':content},'finish_reason':'stop'}]},ensure_ascii=False).encode()
        if self.path=='/large':response=b'x'*1048577
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(response)));self.end_headers()
        try:self.wfile.write(response)
        except (BrokenPipeError,ConnectionResetError):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
(root/'server.json').write_text(json.dumps({'endpoint':f'http://127.0.0.1:{server.server_port}/chat'})+'\n')
print(json.dumps({'port':server.server_port}),flush=True)
server.serve_forever()
