import XCTest
@testable import AgentDoctor

final class ToolUsageTimingSummaryTests: XCTestCase {
    let fixture = ToolUsageTests()
    func add(_ p: inout ToolUsageParser, id: String, start: Double, end: Double?, name: String = "mcp__owned__tool", session: String = "s", host: String = "codex", failed: Bool = false) {
        p.start(host: host, session: session, id: id, name: name, input: ["skill":"owned-skill"], time: fixture.start.addingTimeInterval(start))
        if let end { p.end(host: host, session: session, id: id, value: ["isError":false,"content":[["type":"text","text":"private-payload"]]], error:nil, time:fixture.start.addingTimeInterval(end), invocationFailed:failed) }
    }
    func testOverlapsAndGapsAreCountedAsIntervalUnionNotSumOrFirstToLastSpan() throws {
        var p = fixture.parser()
        add(&p,id:"a",start:0,end:5,name:"mcp__owned__first")
        add(&p,id:"b",start:3,end:7,name:"mcp__owned__second")
        add(&p,id:"c",start:10,end:12)
        let report=p.report(), timing=try XCTUnwrap(report.timingSummary(kind:"mcp"))
        XCTAssertEqual(timing.calls,3);XCTAssertEqual(timing.timingSamples,3)
        XCTAssertEqual(timing.summedObservedSeconds,11);XCTAssertEqual(timing.occupiedObservedSeconds,9)
        XCTAssertEqual(report.tools.compactMap(\.totalObservedSeconds).reduce(0,+),11)
    }
    func testNestingTouchingIntervalsZeroLengthAndInsertionOrderAreStable() {
        let intervals:[(Double,Double)]=[(5,9),(1,6),(2,3),(9,10),(20,20)]
        func summary(_ values:[(Double,Double)]) -> ToolUsageTimingSummary {
            var p=fixture.parser()
            for (i,value) in values.enumerated() { add(&p,id:String(i),start:value.0,end:value.1) }
            return p.report().timingSummary(kind:"mcp")!
        }
        let a=summary(intervals),b=summary(intervals.reversed())
        XCTAssertEqual(a,b);XCTAssertEqual(a.summedObservedSeconds,11);XCTAssertEqual(a.occupiedObservedSeconds,9)
    }
    func testFractionalOffsetsArePreservedInsteadOfRoundedIntoCoincidentCalls() throws {
        var p=fixture.parser()
        add(&p,id:"first",start:1,end:6)
        add(&p,id:"shifted",start:1.00025,end:6.00025)
        let timing=try XCTUnwrap(p.report().timingSummary(kind:"mcp"))
        XCTAssertEqual(try XCTUnwrap(timing.summedObservedSeconds),10,accuracy:0.000001)
        XCTAssertEqual(try XCTUnwrap(timing.occupiedObservedSeconds),5.00025,accuracy:0.000001)
        XCTAssertGreaterThan(try XCTUnwrap(timing.occupiedObservedSeconds),5)
    }
    func testDifferentSessionsAndHostsUseSameTimelineWhileCategoriesStaySeparate() throws {
        var p=fixture.parser()
        add(&p,id:"same",start:1,end:6,session:"secret-session-a")
        add(&p,id:"same",start:2,end:5,session:"secret-session-b",host:"claude")
        add(&p,id:"outer",start:0,end:10,name:"functions.exec")
        add(&p,id:"skill",start:3,end:4,name:"Skill",host:"claude")
        let report=p.report()
        XCTAssertEqual(report.timingSummary(kind:"mcp")?.occupiedObservedSeconds,5)
        XCTAssertEqual(report.timingSummary(kind:"mcp")?.summedObservedSeconds,8)
        XCTAssertEqual(report.timingSummary(kind:"outer")?.occupiedObservedSeconds,10)
        XCTAssertEqual(report.timingSummary(kind:"skill")?.occupiedObservedSeconds,1)
        let encoded=String(decoding:try JSONEncoder().encode(report),as:UTF8.self)
        XCTAssertFalse(encoded.contains("secret-session"));XCTAssertFalse(encoded.contains("private-payload"))
    }
    func testWindowAndIncompletePairsDoNotInventTimingOrClipPartialCalls() throws {
        var p=fixture.parser()
        add(&p,id:"before",start:-1,end:5)
        add(&p,id:"after",start:10,end:101)
        add(&p,id:"missing",start:20,end:nil)
        add(&p,id:"reversed",start:30,end:29)
        add(&p,id:"instant",start:40,end:40)
        let timing=try XCTUnwrap(p.report().timingSummary(kind:"mcp"))
        XCTAssertEqual(timing.calls,4);XCTAssertEqual(timing.timingSamples,1)
        XCTAssertEqual(timing.callsWithoutUsableTiming,3)
        XCTAssertEqual(timing.occupiedObservedSeconds,0);XCTAssertEqual(timing.summedObservedSeconds,0)
    }
    func testHostFailurePairsCountButCompletionWithoutStartRemainsUnknown() throws {
        var p=fixture.parser();add(&p,id:"failed",start:1,end:3,failed:true)
        p.consume(fixture.event("event_msg",["type":"mcp_tool_call_end","call_id":"no-start",
            "invocation":["server":"owned","tool":"tool"],"result":["Ok":["isError":false,"content":[]]]],4),host:"codex",session:"s")
        let report=p.report(),timing=try XCTUnwrap(report.timingSummary(kind:"mcp"))
        XCTAssertEqual(timing.calls,2);XCTAssertEqual(timing.timingSamples,1)
        XCTAssertEqual(timing.callsWithoutUsableTiming,1);XCTAssertEqual(timing.occupiedObservedSeconds,2)
        XCTAssertEqual(report.tools.first?.invocationFailures,1)
    }
    func testMirroredCallsAreCountedOnceAndReportingDoesNotMutateIntervals() {
        var p=fixture.parser()
        add(&p,id:"one",start:1,end:4);add(&p,id:"one",start:1,end:4)
        let a=p.report().timingSummary(kind:"mcp"),b=p.report().timingSummary(kind:"mcp")
        XCTAssertEqual(a,b);XCTAssertEqual(a?.timingSamples,1);XCTAssertEqual(a?.summedObservedSeconds,3)
    }
    func testOldReportsAndNoUsablePairsDoNotClaimZeroElapsedTime() throws {
        var report=fixture.parser().report();report.timingSummaries=nil
        let decoder=JSONDecoder();let old=try decoder.decode(ToolUsageReport.self,from:JSONEncoder().encode(report))
        XCTAssertNil(old.timingSummary(kind:"mcp"))
        var p=fixture.parser();add(&p,id:"missing",start:1,end:nil)
        let timing=try XCTUnwrap(p.report().timingSummary(kind:"mcp"))
        XCTAssertEqual(timing.timingSamples,0);XCTAssertEqual(timing.callsWithoutUsableTiming,1)
        XCTAssertNil(timing.occupiedObservedSeconds);XCTAssertNil(timing.summedObservedSeconds)
    }
    func testInvalidOrConflictingDecodedSummariesRemainUnavailable() throws {
        var p=fixture.parser();add(&p,id:"one",start:1,end:4)
        var report=p.report();var summary=try XCTUnwrap(report.timingSummary(kind:"mcp"))
        summary.occupiedObservedSeconds=4;XCTAssertFalse(summary.isConsistent)
        summary.occupiedObservedSeconds = .nan;XCTAssertFalse(summary.isConsistent)
        summary.occupiedObservedSeconds=3;summary.callsWithoutUsableTiming=1;XCTAssertFalse(summary.isConsistent)
        report.timingSummaries=[summary];XCTAssertNil(report.timingSummary(kind:"mcp"))
        summary.callsWithoutUsableTiming=0;report.timingSummaries=[summary,summary]
        XCTAssertNil(report.timingSummary(kind:"mcp"))
        summary.calls=2;summary.callsWithoutUsableTiming=1;report.timingSummaries=[summary]
        XCTAssertNil(report.timingSummary(kind:"mcp"))
        var accumulator=ToolUsageTimingAccumulator()
        accumulator.observe(start:fixture.start,end:Date(timeIntervalSinceReferenceDate:.infinity))
        XCTAssertNil(accumulator.summary(kind:"mcp").occupiedObservedSeconds)
    }
}
