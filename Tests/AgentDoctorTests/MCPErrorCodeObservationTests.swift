import XCTest
@testable import AgentDoctor

final class MCPErrorCodeObservationTests: XCTestCase {
    func result(_ code: Any, flagged: Any = true) -> [String: Any] {
        ["isError": flagged, "content": [["type":"text", "text":"PRIVATE_DETAIL"]], "structuredContent":["code":code]]
    }
    func cli(_ code: String) -> [String: Any] { ["success":false, "code":code, "error":"PRIVATE_DETAIL"] }
    func parser() -> ToolUsageParser { ToolUsageParser(since:Date(timeIntervalSince1970:0),until:Date(timeIntervalSince1970:100)) }
    func add(_ value: Any, _ p: inout ToolUsageParser, id: String = "one", name: String = "mcp__owned__tool", endFirst: Bool = false) {
        if endFirst { p.end(host:"codex",session:"s",id:id,value:value,error:nil,time:Date(timeIntervalSince1970:2)) }
        p.start(host:"codex",session:"s",id:id,name:name,input:nil,time:Date(timeIntervalSince1970:1))
        p.end(host:"codex",session:"s",id:id,value:value,error:nil,time:Date(timeIntervalSince1970:2))
    }
    func testStructuredCodesRequireExplicitBooleanErrorFlag() {
        XCTAssertEqual(MCPErrorCodeObservation.code(in:result("invalid_argument")),"invalid_argument")
        for flag in [false,1,"true"] as [Any] { XCTAssertNil(MCPErrorCodeObservation.code(in:result("invalid_argument",flagged:flag))) }
        XCTAssertNil(MCPErrorCodeObservation.code(in:["structuredContent":["code":"invalid_argument"]]))
    }
    func testKnownCLIBridgeAndMirroredTextCountOneResult() throws {
        let value=cli("element_not_found");let text=String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)
        let envelope:[String:Any] = ["isError":true,"content":[["type":"text","text":text]],
            "structuredContent":["exitCode":1,"stdout":text,"stderr":"","response":value]]
        var p=parser();add(envelope,&p,endFirst:true);add(envelope,&p)
        let row=try XCTUnwrap(p.report().tools.first)
        XCTAssertEqual(row.completed,1);XCTAssertEqual(row.reportedErrors,1)
        XCTAssertEqual(row.reportedErrorCodes,["element_not_found":1]);XCTAssertEqual(row.unclassifiedResultErrors,0)
        XCTAssertEqual(row.returnedTextBytes,text.utf8.count)
        let encoded=String(decoding:try JSONSerialization.data(withJSONObject:envelope),as:UTF8.self)
        XCTAssertEqual(MCPErrorCodeObservation.code(in:encoded),"element_not_found")
    }
    func testCLILabelInTextIsStructuredButProseAndBusinessDataAreNot() throws {
        let text=String(decoding:try JSONSerialization.data(withJSONObject:cli("denied")),as:UTF8.self)
        XCTAssertEqual(MCPErrorCodeObservation.code(in:["isError":true,"content":[["type":"text","text":text]]]),"denied")
        for value in [
            ["isError":true,"content":[["type":"text","text":"denied: try again"]]],
            ["isError":true,"structuredContent":["data":["code":"denied"]]],
            ["isError":true,"structuredContent":["response":cli("denied")]],
            ["isError":true,"content":[["type":"image","data":text,"mimeType":"image/png"]]],
            ["isError":true,"content":[["type":"text","text":"{\\\"code\\\":\\\"denied\\\"}"]]]
        ] as [Any] { XCTAssertNil(MCPErrorCodeObservation.code(in:value)) }
    }
    func testConflictingUnsupportedAndSecretShapedLabelsStayUnclassified() throws {
        var conflict=result("first");conflict["content"]=[["type":"text","text":String(decoding:try JSONSerialization.data(withJSONObject:cli("second")),as:UTF8.self)]]
        XCTAssertNil(MCPErrorCodeObservation.code(in:conflict))
        for code in [404,"/private/path","user@example.invalid","has\nnewline","denied\n","denied\r",String(repeating:"a",count:65),"sk-abcdefghijklmnopqrst"] as [Any] {
            var p=parser();add(result(code),&p)
            let report=p.report(),row=try XCTUnwrap(report.tools.first)
            XCTAssertEqual(row.reportedErrors,1);XCTAssertEqual(row.unclassifiedResultErrors,1)
            XCTAssertEqual(row.reportedErrorCodes,[:])
            let json=String(decoding:try JSONEncoder().encode(report),as:UTF8.self)
            XCTAssertFalse(json.contains("PRIVATE_DETAIL"));XCTAssertFalse(json.contains("abcdefghijklmnopqrst"))
        }
    }
    func testOuterWrapperNeverAcquiresNestedMCPCodeAttribution() throws {
        var p=parser();add(result("denied"),&p,name:"functions.exec",endFirst:true)
        XCTAssertTrue(p.report().tools.isEmpty)
        let row=try XCTUnwrap(p.report().coverage.unattributedResults?.byTool?.first)
        XCTAssertNil(row.reportedErrorCodes);XCTAssertNil(row.unclassifiedResultErrors)
        XCTAssertNil(row.mcpErrorCodeSummary)
    }
    func testInvocationFailureHasNoMCPResultCode() throws {
        var p=parser();p.start(host:"codex",session:"s",id:"one",name:"mcp__owned__tool",input:nil,time:Date(timeIntervalSince1970:1))
        p.end(host:"codex",session:"s",id:"one",value:nil,error:nil,time:Date(timeIntervalSince1970:2),invocationFailed:true)
        let row=try XCTUnwrap(p.report().tools.first)
        XCTAssertEqual(row.invocationFailures,1);XCTAssertEqual(row.reportedErrors,0)
        XCTAssertEqual(row.reportedErrorCodes,[:]);XCTAssertNil(row.mcpErrorCodeSummary)
    }
    func testCategoryBudgetKeepsOmittedResultsInErrorTotals() throws {
        var p=parser()
        for i in 0..<65 { add(result("category_\(i)"),&p,id:String(i)) }
        for i in 0..<10 { add(result("category_64"),&p,id:"repeat_\(i)") }
        let row=try XCTUnwrap(p.report().tools.first)
        XCTAssertEqual(row.reportedErrors,75);XCTAssertEqual(row.reportedErrorCodes?.count,64)
        XCTAssertEqual(row.reportedErrorCodes?["category_64"],11)
        XCTAssertNil(row.reportedErrorCodes?["category_9"]) // stable lexical tie after the dominant category
        XCTAssertEqual(row.unclassifiedResultErrors,1);XCTAssertEqual(row.errorCodeCategoriesLimited,true)
    }
    func testLegacyReportsStayUnmeasuredAndInvalidCountsNeverBecomeZero() throws {
        var row=ToolUsageRow(id:"one",host:"codex",kind:"mcp",name:"tool");row.completed=2;row.reportedErrors=2
        let old=try JSONDecoder().decode(ToolUsageRow.self,from:JSONEncoder().encode(row))
        XCTAssertNil(old.reportedErrorCodes);XCTAssertNil(old.unclassifiedResultErrors)
        row.reportedErrorCodes=["denied":1];XCTAssertEqual(row.unclassifiedResultErrors,1)
        row.reportedErrorCodes=["denied":3];XCTAssertNil(row.unclassifiedResultErrors)
        row.reportedErrorCodes=["denied":-1];XCTAssertNil(row.unclassifiedResultErrors)
        row.reportedErrorCodes=["denied\n":1];XCTAssertNil(row.unclassifiedResultErrors)
    }
}
