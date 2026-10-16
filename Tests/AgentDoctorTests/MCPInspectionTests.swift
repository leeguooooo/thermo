import XCTest
import ThermoL10n
@testable import AgentDoctor

final class MCPInspectionTests: XCTestCase {
    var root: URL!
    var previousLanguage: Language?
    override func setUpWithError() throws {
        previousLanguage = L10n.override
        L10n.override = .english
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        L10n.override = previousLanguage
        try FileManager.default.removeItem(at: root)
    }

    func server(_ body: String) throws -> MCPServer {
        let file = root.appendingPathComponent("fixture.py")
        // The canary log also proves that no tools/call, sampling or elicitation is attempted.
        let script = """
        import sys,json,time,os
        for line in sys.stdin:
            req=json.loads(line)
            with open(\(String(reflecting: root.appendingPathComponent("requests").path)), 'a') as log:
                log.write(req.get('method','response')+'\\n')
            if 'id' not in req: continue
            result={}
            if req['method']=='initialize':
                result={'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'fixture','version':'1'},'instructions':'fixture instructions'}
            elif req['method']=='tools/list':
        \(body.split(separator: "\n", omittingEmptySubsequences: false).map { "        " + $0 }.joined(separator: "\n"))
            print(json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result}),flush=True)
        """
        try script.write(to: file, atomically: true, encoding: .utf8)
        return MCPServer(name: "fixture", agent: "fixture", source: "fixture", command: "/usr/bin/python3", args: [file.path])
    }
    var env: DoctorEnvironment { DoctorEnvironment(home: root, path: ["/usr/bin", "/bin"]) }

    func testRealChildHandshakePaginationAndRankingWithoutToolCalls() throws {
        let s = try server("""
        if req.get('params',{}).get('cursor')=='page2':
            result={'tools':[{'name':'big','description':'x'*500,'inputSchema':{'type':'object'},'outputSchema':{'type':'object'}}]}
        else:
            result={'tools':[{'name':'small','description':'small tool','inputSchema':{'type':'object'}}],'nextCursor':'page2'}
        """)
        let report = MCPInspector.inspect(s, env: env, timeout: 5)
        XCTAssertEqual(report.state, .ready, report.message)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.tools.map(\.name), ["big", "small"])
        XCTAssertNotNil(report.startupSeconds)
        XCTAssertNotNil(report.handshakeSeconds)
        XCTAssertNotNil(report.listingSeconds)
        XCTAssertGreaterThan(try XCTUnwrap(report.definitions).bytes, 500)
        let requests = try String(contentsOf: root.appendingPathComponent("requests"))
        XCTAssertEqual(requests.components(separatedBy: "\n").filter { !$0.isEmpty }, ["initialize", "notifications/initialized", "tools/list", "tools/list"])
    }

    func testRepeatedCursorFailsInsteadOfReturningPartialSuccess() throws {
        let s = try server("result={'tools':[],'nextCursor':'same'}")
        let report = MCPInspector.inspect(s, env: env, timeout: 5)
        XCTAssertEqual(report.state, .failed)
        XCTAssertFalse(report.complete)
        XCTAssertNil(report.definitions)
    }

    func testTimeoutTerminatesOnlyOwnedChild() throws {
        let s = try server("time.sleep(30)")
        let start = Date()
        let report = MCPInspector.inspect(s, env: env, timeout: 0.5)
        XCTAssertEqual(report.state, .timedOut, report.message)
        XCTAssertFalse(report.complete)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCancellationAndDisabledServersDoNotLaunch() throws {
        var s = try server("result={'tools':[]}")
        s.disabled = true
        XCTAssertEqual(MCPInspector.inspect(s, env: env, timeout: 2).state, .disabled)
        s.disabled = false
        let stopped = DoctorEnvironment(home: root, cancelled: { true })
        XCTAssertEqual(MCPInspector.inspect(s, env: stopped, timeout: 2).state, .cancelled)
        XCTAssertEqual(AgentDoctor.inspectMCP("missing", env: stopped).state, .cancelled,
                       "Cancellation during configuration discovery must not become a missing-server error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("requests").path))
    }

    func testUnsupportedURLSchemeIsNotEmptyHealthy() {
        let s = MCPServer(name: "http", agent: "fixture", source: "fixture", url: "file:///tmp/fixture-mcp")
        let report = MCPInspector.inspect(s, env: env, timeout: 1)
        XCTAssertEqual(report.state, .unsupported)
        XCTAssertFalse(report.complete)
        XCTAssertNil(report.definitions)
    }

    func testSchemaIssuesAndPrivateDescriptionsAreMeasuredWithoutExportingText() throws {
        let row = try MCPInspector.footprint(["name": "fixture", "description": "API_TOKEN=sk-abcdefghijklmnopqrst", "inputSchema": "wrong"])
        XCTAssertTrue(row.issues.contains { $0.contains("not a JSON object") })
        XCTAssertGreaterThan(row.description.bytes, 20)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(row), as: UTF8.self).contains("abcdefghijklmnopqrst"))
        XCTAssertFalse(try MCPInspector.footprint(["name": "fixture"]).issues.isEmpty)
    }

    func testEmptyListIsCompleteButMalformedListIsNot() throws {
        let empty = try server("result={'tools':[]}")
        XCTAssertTrue(MCPInspector.inspect(empty, env: env, timeout: 5).complete)
        let malformed = try server("result={'tools':'wrong'}")
        XCTAssertFalse(MCPInspector.inspect(malformed, env: env, timeout: 5).complete)
    }

    func testServerPingIsAnsweredAndSamplingIsRefused() throws {
        let s = try server("""
        print(json.dumps({'jsonrpc':'2.0','id':'ping','method':'ping'}),flush=True)
        assert json.loads(sys.stdin.readline())['result']=={}
        print(json.dumps({'jsonrpc':'2.0','id':'sample','method':'sampling/createMessage','params':{}}),flush=True)
        assert json.loads(sys.stdin.readline())['error']['code']==-32601
        result={'tools':[]}
        """)
        XCTAssertEqual(MCPInspector.inspect(s, env: env, timeout: 5).state, .ready)
    }

    func testProtocolErrorsDoNotExportServerControlledSecretText() throws {
        let s = try server("""
        print(json.dumps({'jsonrpc':'2.0','id':req['id'],'error':{'code':-32000,'message':'API_TOKEN=fixture-private-secret'}}),flush=True)
        continue
        """)
        let report = MCPInspector.inspect(s, env: env, timeout: 5)
        XCTAssertEqual(report.state, .failed)
        XCTAssertTrue(report.message.contains("-32000"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("fixture-private-secret"))
    }

    func testInvalidStdoutAndWrongResponseIDFailExplicitly() throws {
        for body in ["print('not protocol',flush=True); continue",
                     "print(json.dumps({'jsonrpc':'2.0','id':'wrong','result':{'tools':[]}}),flush=True); continue"] {
            let s = try server(body)
            let report = MCPInspector.inspect(s, env: env, timeout: 5)
            XCTAssertEqual(report.state, .failed)
            XCTAssertFalse(report.complete)
            XCTAssertNil(report.definitions)
        }
    }

    func testCancellationDuringResponseWaitIsBounded() throws {
        let s = try server("time.sleep(30)")
        let start = Date()
        let cancellable = DoctorEnvironment(home: root, cancelled: { Date().timeIntervalSince(start) > 0.6 })
        let report = MCPInspector.inspect(s, env: cancellable, timeout: 10)
        XCTAssertEqual(report.state, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testConfiguredPATHResolvesTheLauncher() throws {
        var s = try server("result={'tools':[]}")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("fixture-env").path, withDestinationPath: "/usr/bin/env")
        s.command = "fixture-env"
        s.args.insert("python3", at: 0)
        s.env["PATH"] = bin.path + ":/usr/bin:/bin"
        XCTAssertEqual(MCPInspector.inspect(s, env: env, timeout: 5).state, .ready)
    }

    func testOversizedResponseCannotBecomeAnEmptyHealthyListing() throws {
        let s = try server("result={'tools':[{'name':'huge','description':'x'*9000000,'inputSchema':{'type':'object'}}]}")
        let report = MCPInspector.inspect(s, env: env, timeout: 5)
        XCTAssertEqual(report.state, .failed, report.message)
        XCTAssertTrue(report.message.contains("size limit"))
        XCTAssertFalse(report.complete)
        XCTAssertNil(report.definitions)
    }
}
