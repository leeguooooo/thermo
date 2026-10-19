import XCTest
import ThermoL10n
@testable import AgentDoctor

final class MCPHTTPTests: XCTestCase {
    var root: URL!
    var process: Process!
    var port = 0
    var previousLanguage: Language?
    override func setUpWithError() throws {
        previousLanguage = L10n.override; L10n.override = .english
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let code = #"""
import json,sys,time,threading
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
root=sys.argv[1]
class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def response(self,status,body=b'',headers={}):
        self.send_response(status)
        for k,v in headers.items(): self.send_header(k,v)
        self.send_header('Content-Length',str(len(body))); self.end_headers()
        if body: self.wfile.write(body); self.wfile.flush()
    def do_DELETE(self):
        with open(root+'/log','a') as f: f.write(json.dumps({'method':'DELETE','session':self.headers.get('Mcp-Session-Id')})+'\n')
        if self.path=='/cleanup-slow': time.sleep(0.4)
        if self.path=='/cleanup-error': return self.response(503,b'fixture-private-cleanup-error')
        if self.path=='/cleanup-unsupported': return self.response(405)
        self.response(204)
    def do_POST(self):
        req=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with open(root+'/log','a') as f:
            f.write(json.dumps({'method':req.get('method','response'),'session':self.headers.get('Mcp-Session-Id'),'version':self.headers.get('MCP-Protocol-Version'),'auth':self.headers.get('Authorization'),'path':self.path,'methodHeader':self.headers.get('Mcp-Method'),'meta':req.get('params',{}).get('_meta')})+'\n')
        if self.path=='/401': return self.response(401,b'fixture-private-secret',{'WWW-Authenticate':'Basic realm="fixture"'})
        if self.path in ['/403','/429','/503']: return self.response(int(self.path[1:]),b'fixture-private-secret')
        if self.path=='/redirect': return self.response(307,b'',{'Location':'/should-not-be-contacted'})
        if self.path=='/slow': time.sleep(30); return
        if 'id' not in req or 'method' not in req:
            if self.path=='/bad-notification': return self.response(202,b'data: invalid')
            return self.response(202)
        if self.path.startswith('/modern'):
            meta=req['params']['_meta']
            assert self.headers['MCP-Protocol-Version']==meta['io.modelcontextprotocol/protocolVersion']=='2026-07-28'
            assert self.headers['Mcp-Method']==req['method']
            assert meta['io.modelcontextprotocol/clientCapabilities']=={}
            assert not self.headers.get('Mcp-Session-Id')
            if self.path in ['/modern-version-error','/modern-missing-method']:
                code=-32022 if self.path=='/modern-version-error' else -32601
                error={'jsonrpc':'2.0','id':None,'error':{'code':code,'message':'PRIVATE_PROTOCOL_ERROR'}}
                return self.response(400 if code==-32022 else 404,json.dumps(error).encode(),{'Content-Type':'application/json'})
            if self.path=='/modern-error-result':
                invalid={'jsonrpc':'2.0','id':req['id'],'result':{'resultType':'complete','supportedVersions':['2026-07-28'],'capabilities':{}}}
                return self.response(400,json.dumps(invalid).encode(),{'Content-Type':'application/json'})
            if req['method']=='server/discover':
                result={'resultType':'complete','supportedVersions':['2026-07-28'],'capabilities':{'tools':{}}}
                if self.path=='/modern-no-tools':result['capabilities']={}
            elif req['method']=='tools/list':
                result={'resultType':'complete','tools':[{'name':'owned','description':'fixture','inputSchema':{'type':'object'}}]}
                if self.path=='/modern-input':result={'resultType':'input_required','inputRequests':[{'private_fixture':'not exported'}]}
            else:raise AssertionError('unexpected metadata operation')
        elif req.get('method')=='initialize':
            selected=self.path.removeprefix('/revision-') if self.path.startswith('/revision-') else '2025-06-18'
            result={'protocolVersion':selected,'capabilities':{'tools':{}},'serverInfo':{'name':'fixture','version':'1'}}
        else:
            if req.get('params',{}).get('cursor')=='two':
                result={'tools':[{'name':'large','description':'中文说明'*40,'inputSchema':{'type':'object'}}]}
            else: result={'tools':[{'name':'small','description':'small tool','inputSchema':{'type':'object'}}],'nextCursor':'two'}
        body=json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result},ensure_ascii=False).encode()
        headers={'Content-Type':'application/json'}
        if req.get('method')=='initialize': headers['Mcp-Session-Id']='fixture-session'
        if self.path.startswith('/modern') and req['method']=='server/discover':headers['Mcp-Session-Id']='ignored-modern-session'
        if self.path=='/bad': body=b'not json'
        if self.path=='/oversize': body=b'x'*9000000
        if self.path in ['/sse','/cr','/rpc','/incomplete','/modern-sse','/modern-rpc'] and req.get('method')=='tools/list':
            sep=b'\r' if self.path=='/cr' else b'\r\n'
            self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
            payload=b': comment'+sep+sep
            if self.path in ['/rpc','/modern-rpc']:
                for method,ident in [('ping','ping'),('sampling/createMessage','sample')]:
                    payload+=b'data: '+json.dumps({'jsonrpc':'2.0','method':method,'id':ident}).encode()+sep+sep
            if self.path!='/incomplete': payload+=b'data: '+body+sep+sep
            for i in range(0,len(payload),7): self.wfile.write(payload[i:i+7]); self.wfile.flush()
            time.sleep(0.1 if self.path=='/incomplete' else 2); self.close_connection=True
        else:
            if self.path=='/cleanup-refused' and req.get('method')=='tools/list' and req.get('params',{}).get('cursor')=='two':
                server.shutdown(); server.server_close()
            if self.path=='/no-session': headers.pop('Mcp-Session-Id',None)
            self.response(200,body,headers)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
server.daemon_threads=True
with open(root+'/port','w') as f: f.write(str(server.server_port))
server.serve_forever()
# Keep the fixture process alive after closing its listener so the last listing
# response can finish on the existing connection; cleanup uses a new connection.
threading.Event().wait()
"""#
        let file = root.appendingPathComponent("fixture_http_server.py")
        try code.write(to: file, atomically: true, encoding: .utf8)
        process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [file.path, root.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let limit = Date().addingTimeInterval(5)
        while Date() < limit {
            if let value = try? String(contentsOf: root.appendingPathComponent("port")), let parsed = Int(value) { port = parsed; return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw NSError(domain: "fixture did not start", code: 1)
    }
    override func tearDownWithError() throws {
        if process?.isRunning == true { process.terminate(); process.waitUntilExit() }
        L10n.override = previousLanguage
        if let root { try FileManager.default.removeItem(at: root) }
    }
    func server(_ path: String) -> MCPServer {
        MCPServer(name: "fixture", agent: "fixture", source: "fixture", url: "http://127.0.0.1:\(port)\(path)", headers: ["Authorization": "Bearer fixture-token"])
    }
    func inspect(_ path: String, timeout: Double = 5, protocolMode: MCPInspectionProtocol = .handshake) -> MCPInspection {
        MCPInspector.inspect(server(path), env: DoctorEnvironment(home: root), timeout: timeout, protocolMode: protocolMode)
    }
    func log() throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("log")).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
    func testNovemberRevisionUsesNegotiatedHTTPHeadersAndCleansItsSession() throws {
        let report = inspect("/revision-2025-11-25")
        XCTAssertEqual(report.state, .ready, report.message)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.protocolVersion, "2025-11-25")
        let calls = try log()
        XCTAssertEqual(calls.compactMap { $0["method"] as? String }, ["initialize", "notifications/initialized", "tools/list", "tools/list", "DELETE"])
        for call in calls.dropFirst().dropLast() {
            XCTAssertEqual(call["version"] as? String, "2025-11-25")
        }
        XCTAssertEqual(report.cleanupDetails?.reason, "closed")
    }
    func testModernJSONAndSSECarryMetadataWithoutCreatingOrDeletingSessions() throws {
        for path in ["/modern-json", "/modern-sse"] {
            let report = inspect(path, protocolMode: .stateless)
            XCTAssertEqual(report.state, .ready, report.message)
            XCTAssertTrue(report.complete)
            XCTAssertNotNil(report.discoverySeconds); XCTAssertNil(report.handshakeSeconds)
            XCTAssertEqual(report.cleanupDetails?.reason, "notNeeded")
            let calls = try log().filter { $0["path"] as? String == path }
            XCTAssertEqual(calls.compactMap { $0["method"] as? String }, ["server/discover", "tools/list"])
            for call in calls {
                XCTAssertEqual(call["methodHeader"] as? String, call["method"] as? String)
                XCTAssertEqual(call["version"] as? String, "2026-07-28")
                XCTAssertTrue(call["session"] is NSNull)
            }
        }
        XCTAssertFalse(try log().contains { $0["method"] as? String == "DELETE" })
    }
    func testModernNoToolsIsMeasuredEmptyAndInputRequiredIsIncomplete() throws {
        let empty = inspect("/modern-no-tools", protocolMode: .stateless)
        XCTAssertTrue(empty.complete); XCTAssertEqual(empty.tools.count, 0)
        XCTAssertNotNil(empty.definitions)
        let input = inspect("/modern-input", protocolMode: .stateless)
        XCTAssertEqual(input.state, .unsupported); XCTAssertFalse(input.complete)
        XCTAssertNil(input.definitions)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(input), as: UTF8.self).contains("not exported"))
        XCTAssertFalse(try log().contains { $0["method"] as? String == "DELETE" })
    }
    func testModernSSEServerRequestsAreNotAnsweredByPOST() throws {
        let report = inspect("/modern-rpc", protocolMode: .stateless)
        XCTAssertEqual(report.state, .unsupported)
        XCTAssertEqual(try log().compactMap { $0["method"] as? String }, ["server/discover", "tools/list"])
    }
    func testModernHTTPCompatibilityErrorsAreSanitizedAndNeverFallBack() throws {
        for path in ["/modern-version-error", "/modern-missing-method", "/modern-error-result"] {
            let report = inspect(path, protocolMode: .stateless)
            XCTAssertEqual(report.state, path == "/modern-error-result" ? .failed : .unsupported)
            XCTAssertFalse(report.complete); XCTAssertNil(report.definitions)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("PRIVATE_PROTOCOL_ERROR"))
        }
        XCTAssertEqual(try log().compactMap { $0["method"] as? String }, ["server/discover", "server/discover", "server/discover"])
    }
    func testJSONPaginationSessionHeadersAndOwnSessionCleanup() throws {
        let report = inspect("/json")
        XCTAssertEqual(report.state, .ready, report.message)
        XCTAssertEqual(report.tools.map(\.name), ["large", "small"])
        XCTAssertEqual(report.cleanupStatus, "closed")
        XCTAssertEqual(report.cleanupDetails?.reason, "closed")
        XCTAssertEqual(report.cleanupDetails?.httpStatusCode, 204)
        XCTAssertNil(report.startupSeconds, "HTTP has no process startup")
        let calls = try log()
        XCTAssertEqual(calls.first?["auth"] as? String, "Bearer fixture-token")
        XCTAssertTrue(calls.first?["session"] is NSNull)
        XCTAssertTrue(calls.first?["version"] is NSNull)
        XCTAssertEqual(calls.compactMap { $0["method"] as? String }, ["initialize", "notifications/initialized", "tools/list", "tools/list", "DELETE"])
        for call in calls.dropFirst() { XCTAssertEqual(call["session"] as? String, "fixture-session") }
        for call in calls.dropFirst().dropLast() { XCTAssertEqual(call["version"] as? String, "2025-06-18") }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("fixture-token"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("fixture-session"))
    }
    func testCleanupTimeoutAndHTTPFailuresAreDistinctFromSuccessfulListing() throws {
        for (path, status, reason, code) in [("/cleanup-slow", "unconfirmed", "timedOut", nil as Int?),
                                           ("/cleanup-error", "unconfirmed", "httpError", 503),
                                           ("/cleanup-unsupported", "server_retained", "unsupported", 405)] {
            let report = inspect(path)
            XCTAssertTrue(report.complete, report.message)
            XCTAssertEqual(report.state, .ready)
            XCTAssertEqual(report.cleanupStatus, status)
            let details = try XCTUnwrap(report.cleanupDetails)
            XCTAssertEqual(details.reason, reason)
            XCTAssertEqual(details.httpStatusCode, code)
            XCTAssertEqual(details.budgetSeconds, 0.25)
            XCTAssertGreaterThanOrEqual(details.elapsedSeconds, 0)
            if reason == "timedOut" { XCTAssertGreaterThanOrEqual(details.elapsedSeconds, 0.20) }
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("fixture-private-cleanup-error"))
        }
        let calls = try log()
        XCTAssertEqual(calls.filter { $0["method"] as? String == "DELETE" }.count, 3, "one close attempt per new session")
        XCTAssertFalse(calls.contains { $0["method"] as? String == "tools/call" })
    }
    func testCleanupTransportFailureAndNoSessionAreExplicit() throws {
        let noSession = inspect("/no-session")
        XCTAssertTrue(noSession.complete)
        XCTAssertEqual(noSession.cleanupStatus, "not_needed")
        XCTAssertEqual(noSession.cleanupDetails?.reason, "notNeeded")
        XCTAssertEqual(noSession.cleanupDetails?.budgetSeconds, 0)
        XCTAssertFalse(try log().contains { $0["method"] as? String == "DELETE" })
        let refused = inspect("/cleanup-refused")
        XCTAssertTrue(refused.complete, refused.message)
        XCTAssertEqual(refused.cleanupStatus, "unconfirmed")
        XCTAssertEqual(refused.cleanupDetails?.reason, "transportError")
        XCTAssertNil(refused.cleanupDetails?.httpStatusCode)
    }
    func testOldInspectionReportsDecodeWithoutCleanupDetails() throws {
        let old = MCPInspection(generated: Date(), name: "fixture", agent: "fixture", cleanupStatus: "unconfirmed")
        let data = try JSONEncoder().encode(old)
        XCTAssertNil(try JSONDecoder().decode(MCPInspection.self, from: data).cleanupDetails)
    }
    func testSSEChunksAndCRLineEndingsDoNotWaitForStreamClosure() {
        for path in ["/sse", "/cr"] {
            let report = inspect(path)
            XCTAssertEqual(report.state, .ready, report.message)
            XCTAssertEqual(report.tools.count, 2)
            XCTAssertLessThan(report.listingSeconds ?? 99, 1.5)
        }
    }
    func testAuthenticationAndRedirectNeverBecomeHealthyOrFollowed() throws {
        let auth = inspect("/401")
        XCTAssertEqual(auth.state, .authenticationRequired)
        XCTAssertEqual(auth.rejectedHTTPStatusCode, 401)
        XCTAssertTrue(auth.message.contains("HTTP 401"))
        XCTAssertTrue(auth.measurementNote.contains("separate connection"))
        XCTAssertTrue(auth.measurementNote.contains("does not establish the host connection state"))
        XCTAssertTrue(auth.measurementNote.contains("No login or business tool calls"))
        let redirect = inspect("/redirect")
        XCTAssertEqual(redirect.state, .failed)
        XCTAssertFalse(redirect.complete)
        XCTAssertFalse(try log().contains { $0["path"] as? String == "/should-not-be-contacted" })
    }
    func testRejectedHTTPStatusesStayMachineReadableWithoutResponseBodiesOrRetries() throws {
        for status in [403, 429, 503] {
            let report = inspect("/\(status)")
            XCTAssertEqual(report.rejectedHTTPStatusCode, status)
            XCTAssertEqual(report.state, status == 403 ? .authenticationRequired : .failed)
            XCTAssertFalse(report.complete)
            XCTAssertTrue(report.message.contains(String(status)))
            let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
            XCTAssertFalse(encoded.contains("fixture-private-secret"))
            XCTAssertEqual(try log().filter { $0["path"] as? String == "/\(status)" }.count, 1)
        }
        XCTAssertEqual(try log().count, 3)
    }
    func testHTTPRejectionIsAbsentForReadyAndDecodeFailuresAndSurvivesOldReportDecoding() throws {
        let ready = inspect("/json")
        XCTAssertEqual(ready.state, .ready)
        XCTAssertNil(ready.rejectedHTTPStatusCode)
        XCTAssertNil(inspect("/bad").rejectedHTTPStatusCode)
        let encoded = try JSONEncoder().encode(ready)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "rejectedHTTPStatusCode")
        let decoded = try JSONDecoder().decode(MCPInspection.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.rejectedHTTPStatusCode)
        let cleanup = inspect("/cleanup-error")
        XCTAssertNil(cleanup.rejectedHTTPStatusCode)
        XCTAssertEqual(cleanup.cleanupDetails?.httpStatusCode, 503)
    }
    func testMalformedOversizedAndTimeoutResponsesRemainIncomplete() {
        for path in ["/bad", "/oversize", "/slow"] {
            let report = inspect(path, timeout: path == "/slow" ? 0.4 : 5)
            XCTAssertFalse(report.complete)
            XCTAssertNil(report.definitions)
            XCTAssertEqual(report.state, path == "/slow" ? .timedOut : .failed, report.message)
        }
    }
    func testCancellationDuringHTTPWait() {
        let start = Date()
        let report = MCPInspector.inspect(server("/slow"), env: DoctorEnvironment(home: root, cancelled: { Date().timeIntervalSince(start) > 0.3 }), timeout: 5)
        XCTAssertEqual(report.state, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
    func testHTTPServerRequestsAreAcknowledgedWithoutModelCalls() throws {
        let report = inspect("/rpc")
        XCTAssertEqual(report.state, .ready, report.message)
        let calls = try log().compactMap { $0["method"] as? String }
        XCTAssertEqual(calls.filter { $0 == "response" }.count, 4, "ping and unsupported sampling on both pages")
        XCTAssertFalse(calls.contains("tools/call"))
    }
    func testSSEEndingWithoutResultIsIncomplete() {
        let report = inspect("/incomplete")
        XCTAssertEqual(report.state, .failed, report.message)
        XCTAssertFalse(report.complete)
        XCTAssertNil(report.definitions)
        XCTAssertEqual(report.cleanupStatus, "closed")
    }
    func testCodexAuthenticationConfigurationIsPreserved() {
        let servers = ConfigChecks.tomlServers("""
        [mcp_servers.fixture]
        url = "https://example.invalid/mcp"
        bearer_token_env_var = "FIXTURE_BEARER"
        [mcp_servers.fixture.env_http_headers]
        "X-Fixture" = "FIXTURE_HEADER"
        """, source: "fixture")
        XCTAssertEqual(servers.first?.bearerTokenEnv, "FIXTURE_BEARER")
        XCTAssertEqual(servers.first?.headerEnv, ["X-Fixture": "FIXTURE_HEADER"])
    }
    func testNonemptyNotificationAcknowledgementFails() {
        let report = inspect("/bad-notification")
        XCTAssertEqual(report.state, .failed)
        XCTAssertFalse(report.complete)
        XCTAssertEqual(report.cleanupStatus, "closed")
    }
    func testMissingAuthenticationEnvironmentAndReservedHeadersRefuseBeforeNetwork() {
        var s = server("/json")
        s.bearerTokenEnv = "THERMO_FIXTURE_MISSING_AUTH_52D44845"
        let missing = MCPInspector.inspect(s, env: DoctorEnvironment(home: root), timeout: 1)
        XCTAssertEqual(missing.state, .authenticationRequired)
        XCTAssertTrue(missing.measurementNote.contains("separate connection"))
        s.bearerTokenEnv = nil
        s.headers["Mcp-Session-Id"] = "somebody-elses-session"
        XCTAssertEqual(MCPInspector.inspect(s, env: DoctorEnvironment(home: root), timeout: 1).state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("log").path))
    }
}
