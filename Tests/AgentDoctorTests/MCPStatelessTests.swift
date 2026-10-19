import XCTest
import ThermoL10n
@testable import AgentDoctor

final class MCPStatelessTests: XCTestCase {
    var home: URL!
    var language: Language?
    override func setUpWithError() throws {
        language = L10n.override; L10n.override = .english
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        L10n.override = language
        try FileManager.default.removeItem(at: home)
    }
    func inspect(_ scenario: String = "normal", timeout: Double = 5) throws -> MCPInspection {
        let script = #"""
import sys,json,time
scenario,log=sys.argv[1:]
for line in sys.stdin:
 req=json.loads(line)
 with open(log,'a') as f:f.write(req.get('method','response')+'\n')
 if req['method']=='notifications/cancelled':
  assert req['params']['requestId']=='thermo-1'
  break
 assert req['method'] in ['server/discover','tools/list']
 meta=req['params']['_meta']
 assert meta['io.modelcontextprotocol/protocolVersion']=='2026-07-28'
 assert meta['io.modelcontextprotocol/clientCapabilities']=={}
 assert meta['io.modelcontextprotocol/clientInfo']['name']=='thermo-inspector'
 if scenario=='timeout':time.sleep(30)
 if scenario=='cancel-aware':continue
 if scenario=='server-request':
  print(json.dumps({'jsonrpc':'2.0','id':'server-ping','method':'ping'}),flush=True)
  continue
 if req['method']=='server/discover':
  result={'resultType':'complete','supportedVersions':['2026-07-28'],'capabilities':{'tools':{}},'instructions':'PRIVATE_DISCOVERY_INSTRUCTIONS'}
  if scenario=='unsupported':result['supportedVersions']=['2099-01-01']
  if scenario=='bad-capabilities':result['capabilities']['tools']=True
 else:
  if req['params'].get('cursor')=='two':result={'resultType':'complete','tools':[{'name':'wide','description':'x'*400,'inputSchema':{'type':'object'}}]}
  else:result={'resultType':'complete','tools':[{'name':'small','description':'owned','inputSchema':{'type':'object'}}],'nextCursor':'two'}
 if scenario=='absent-resultType':result.pop('resultType')
 if scenario=='input-discovery' and req['method']=='server/discover' or scenario=='input-list' and req['method']=='tools/list':
  result={'resultType':'input_required','inputRequests':[{'PRIVATE_INPUT_REQUIRED':True}]}
 if scenario=='unknown-result':result['resultType']='extension_unknown'
 print(json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result}),flush=True)
"""#
        let file = home.appendingPathComponent("server.py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let server = MCPServer(name: "owned", agent: "fixture", source: "fixture", command: "/usr/bin/python3", args: [file.path, scenario, home.appendingPathComponent("requests").path])
        return MCPInspector.inspect(server, env: DoctorEnvironment(home: home), timeout: timeout, protocolMode: .stateless)
    }
    func methods() throws -> [String] { try String(contentsOf: home.appendingPathComponent("requests")).split(separator: "\n").map(String.init) }
    func testStatelessDiscoveryPaginationRankingAndPrivateInstructions() throws {
        let report = try inspect()
        XCTAssertEqual(report.state, .ready, report.message)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.protocolVersion, "2026-07-28")
        XCTAssertEqual(report.requestedProtocol, .stateless)
        XCTAssertNil(report.handshakeSeconds)
        XCTAssertNotNil(report.discoverySeconds)
        XCTAssertEqual(report.tools.map(\.name), ["wide", "small"])
        XCTAssertEqual(try methods(), ["server/discover", "tools/list", "tools/list"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("PRIVATE_DISCOVERY_INSTRUCTIONS"))
    }
    func testModernOutputSchemaCanDescribeNonObjectValuesWithoutChangingMeasurements() throws {
        for output: [String: Any] in [["type":"array", "items":["type":"string"]], ["type":"string"], [:]] {
            let tool: [String: Any] = ["name":"schema", "description":"Owned", "inputSchema":["type":"object"], "outputSchema":output]
            let legacy = try MCPInspector.footprint(tool)
            let modern = try MCPInspector.footprint(tool, protocolMode: .stateless)
            XCTAssertEqual(legacy.issues.count, 1)
            XCTAssertTrue(modern.issues.isEmpty)
            XCTAssertEqual(legacy.definition, modern.definition)
            XCTAssertEqual(legacy.outputSchema, modern.outputSchema)
        }
        let malformed: [String: Any] = ["name":"bad", "description":"Owned", "inputSchema":["type":"array"], "outputSchema":false]
        XCTAssertEqual(try MCPInspector.footprint(malformed, protocolMode: .stateless).issues.count, 2)
    }
    func testMissingResultTypeUsesCompleteCompatibilityRule() throws {
        XCTAssertTrue(try inspect("absent-resultType").complete)
    }
    func testUnadvertisedProtocolAndMalformedCapabilitiesStopBeforeListing() throws {
        for scenario in ["unsupported", "bad-capabilities", "unknown-result", "input-discovery"] {
            try? FileManager.default.removeItem(at: home.appendingPathComponent("requests"))
            let report = try inspect(scenario)
            XCTAssertEqual(report.state, .unsupported, report.message)
            XCTAssertFalse(report.complete); XCTAssertNil(report.definitions)
            XCTAssertEqual(try methods(), ["server/discover"])
        }
    }
    func testInputRequiredDoesNotResumeOrExposeClientInteraction() throws {
        let report = try inspect("input-list")
        XCTAssertEqual(report.state, .unsupported)
        XCTAssertFalse(report.complete); XCTAssertNil(report.definitions)
        XCTAssertEqual(try methods(), ["server/discover", "tools/list"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("PRIVATE_INPUT_REQUIRED"))
    }
    func testServerRequestsDoNotProduceJSONRPCClientResponses() throws {
        let report = try inspect("server-request")
        XCTAssertEqual(report.state, .unsupported)
        XCTAssertEqual(try methods(), ["server/discover"])
    }
    func testTimeoutDoesNotRestartOrFallBackToHandshake() throws {
        let start = Date(), report = try inspect("timeout", timeout: 0.4)
        XCTAssertEqual(report.state, .timedOut)
        XCTAssertFalse(report.complete)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(try methods(), ["server/discover"])
    }
    func testOlderReportsLeaveProtocolModeAndDiscoveryTimingUnknown() throws {
        let report = try inspect()
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        value.removeValue(forKey: "requestedProtocol"); value.removeValue(forKey: "discoverySeconds")
        let old = try JSONDecoder().decode(MCPInspection.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertNil(old.requestedProtocol); XCTAssertNil(old.discoverySeconds)
    }
    func testTimeoutNotifiesThePendingStdioRequestBeforeShutdown() throws {
        let report = try inspect("cancel-aware", timeout: 0.4)
        XCTAssertEqual(report.state, .timedOut)
        XCTAssertEqual(try methods(), ["server/discover", "notifications/cancelled"])
    }
}
