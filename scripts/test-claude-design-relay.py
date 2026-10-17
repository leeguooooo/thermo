"""Offline protocol tests for the installed Design relay. No Keychain or vendor requests.
Usage: python3 scripts/test-claude-design-relay.py RELAY_PY
"""
import importlib.util
import json
from pathlib import Path
import sys
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.dont_write_bytecode = True
TARGET = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location('owned_design_relay', TARGET)
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)
relay.token = lambda: 'owned-fixture-token'
def deny_credentials():
    raise AssertionError('Real credentials must not be accessed')
relay.credential = deny_credentials


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.release = threading.Event()
        self.stream_closed = threading.Event()
        self.requests = []
        owner = self
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *args):
                pass
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                owner.requests.append({'path': self.path, 'message': request, 'version': self.headers.get('MCP-Protocol-Version'),
                                       'session': self.headers.get('Mcp-Session-Id')})
                if self.path == '/http-error':
                    body = b'owned-private-error-body'
                    self.send_response(503); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
                if self.path == '/redirect':
                    self.send_response(307); self.send_header('Location', '/must-not-follow'); self.send_header('Content-Length', '0'); self.end_headers(); return
                if 'id' not in request:
                    self.send_response(202); self.send_header('Content-Length', '0'); self.end_headers(); return
                result = {'jsonrpc': '2.0', 'id': request['id'], 'result': {'ok': '中文', 'protocolVersion': '2025-06-18'}}
                if self.path == '/json' or self.path == '/batch-json':
                    value = result if self.path == '/json' else [{'jsonrpc': '2.0', 'method': 'notifications/progress'}, result]
                    body = json.dumps(value).encode()
                    self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.send_header('Mcp-Session-Id', 'owned-session'); self.end_headers(); self.wfile.write(body); return
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
                progress = {'jsonrpc': '2.0', 'method': 'notifications/progress', 'params': {'progress': 1}}
                messages = [progress]
                if self.path == '/wrong-id':
                    messages.append({'jsonrpc': '2.0', 'id': 'other', 'result': {}})
                elif self.path == '/incomplete':
                    pass
                elif self.path == '/rpc-error':
                    messages.append({'jsonrpc': '2.0', 'id': request['id'], 'error': {'code': -1, 'message': 'fixture'}})
                else:
                    messages += [{'jsonrpc': '2.0', 'id': False, 'result': {}}, result]
                for message in messages:
                    body = ('data: ' + json.dumps(message, ensure_ascii=False) + '\r\n\r\n').encode()
                    for offset in range(0, len(body), 3):
                        self.wfile.write(body[offset:offset+3]); self.wfile.flush()
                if self.path == '/open':
                    owner.release.wait(timeout=3)
                owner.stream_closed.set(); self.close_connection = True
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.release.set(); self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=2)

    def client(self, path):
        relay.ENDPOINT = 'http://127.0.0.1:' + str(self.server.server_port) + path
        client = relay.DesignMCP()
        client.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), relay.NoRedirect())
        return client

    def request(self):
        return {'jsonrpc': '2.0', 'id': 0, 'method': 'tools/list', 'params': {}}

    def test_matching_response_returns_while_stream_is_still_open(self):
        replies = self.client('/open').request(self.request())
        self.assertEqual(replies[-1]['result']['ok'], '中文')
        self.assertFalse(self.stream_closed.is_set(), 'RPC completion must not wait for stream EOF')
        self.assertEqual(len(self.requests), 1)

    def test_progress_and_boolean_id_are_not_the_requested_response(self):
        replies = self.client('/open').request(self.request())
        self.assertEqual(len(replies), 3)
        self.assertIs(replies[1]['id'], False)
        self.assertIs(type(replies[-1]['id']), int)

    def test_line_endings_bom_multiline_and_utf8_chunk_boundaries(self):
        class Chunks:
            def __init__(self, body): self.body = body
            def read1(self, count):
                out, self.body = self.body[:2], self.body[2:]
                return out
        for separator in (b'\n', b'\r\n', b'\r'):
            body = b'\xef\xbb\xbf: comment' + separator + b'data: {"id":0,' + separator + 'data: "result":"中文"}'.encode() + separator + separator
            self.assertEqual(list(relay.sse_messages(Chunks(body))), [{'id': 0, 'result': '中文'}])

    def test_sse_rpc_error_is_preserved(self):
        replies = self.client('/rpc-error').request(self.request())
        self.assertEqual(replies[-1]['error']['code'], -1)

    def test_incomplete_and_unrelated_streams_fail_without_retry(self):
        for path in ('/wrong-id', '/incomplete'):
            with self.assertRaisesRegex(RuntimeError, 'stream ended before the matching response'):
                self.client(path).request(self.request())
        self.assertEqual(len(self.requests), 2)

    def test_unterminated_event_is_not_a_response(self):
        class Body:
            def __init__(self): self.data = b'data: {"id":0,"result":{}}\n'
            def read1(self, size):
                value, self.data = self.data, b''
                return value
        self.assertEqual(list(relay.sse_messages(Body())), [])

    def test_json_batch_and_protocol_session_headers(self):
        client = self.client('/json')
        client.request({'jsonrpc': '2.0', 'id': 'init', 'method': 'initialize', 'params': {}})
        self.assertEqual(client.protocol, '2025-06-18')
        self.assertEqual(client.request({'jsonrpc': '2.0', 'method': 'notifications/initialized'}), [])
        self.assertEqual(self.requests[-1]['session'], 'owned-session')
        self.assertEqual(self.requests[-1]['version'], '2025-06-18')
        self.assertEqual(len(self.client('/batch-json').request(self.request())), 2)

    def test_error_bodies_and_redirects_are_not_forwarded(self):
        with self.assertRaisesRegex(RuntimeError, 'HTTP 503') as caught:
            self.client('/http-error').request(self.request())
        self.assertNotIn('owned-private-error-body', str(caught.exception))
        with self.assertRaisesRegex(RuntimeError, 'HTTP 307'):
            self.client('/redirect').request(self.request())
        self.assertFalse(any(x['path'] == '/must-not-follow' for x in self.requests))


if __name__ == '__main__':
    unittest.main()
