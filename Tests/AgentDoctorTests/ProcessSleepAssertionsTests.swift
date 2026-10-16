import Foundation
import IOKit.pwr_mgt
import XCTest
@testable import AgentCore
@testable import AgentDoctor

final class ProcessSleepAssertionsTests: XCTestCase {
    func row(_ type:String="PreventUserIdleSystemSleep",level:Any=255,name:Any="fixture") -> NSDictionary {
        [kIOPMAssertionTypeKey:type,kIOPMAssertionLevelKey:level,kIOPMAssertionNameKey:name,"AssertPID":7]
    }
    func testOnlySelectedPIDIsReturned() {
        let report=ProcessSleepAssertions.parse([NSNumber(value:7):[row()],NSNumber(value:8):[row(name:"another-process-private-name")]],pid:7)
        XCTAssertEqual(report.state,.observed);XCTAssertTrue(report.queryComplete);XCTAssertEqual(report.assertions.count,1)
        XCTAssertEqual(report.assertions[0].active,true);XCTAssertEqual(report.assertions[0].request,.idleSystem)
        XCTAssertEqual(ProcessSleepAssertions.parse([NSNumber(value:8):[row()]],pid:7).state,.noneObserved)
    }
    func testLevelsNeverTurnUnknownIntoInactive() {
        let report=ProcessSleepAssertions.parse([NSNumber(value:7):[row(level:0),row(level:255),row(level:1),row(level:true),row(level:255.5)]],pid:7)
        XCTAssertEqual(report.assertions.map(\.active),[false,true,nil,nil,nil]);XCTAssertFalse(report.queryComplete)
    }
    func testTypesDescribeRequestsRatherThanGuaranteedEffects() {
        let rows=[row("PreventUserIdleDisplaySleep"),row("PreventDiskIdle"),row("PreventSystemSleep"),row("FutureAssertionType")]
        let report=ProcessSleepAssertions.parse([NSNumber(value:7):rows],pid:7)
        XCTAssertEqual(report.assertions.map(\.request),[.idleDisplayAndSystem,.diskIdle,.systemSleep,.other])
    }
    func testInvalidSchemaIsUnknownRatherThanEmpty() {
        for input:NSDictionary? in [nil,["7":[row()]],[NSNumber(value:7):"malformed"],[NSNumber(value:7):["malformed"]],[NSNumber(value:7):[["AssertType":"PreventUserIdleSystemSleep","AssertLevel":255,"AssertPID":8]]]] {
            let report=ProcessSleepAssertions.parse(input,pid:7);XCTAssertEqual(report.state,.unavailable);XCTAssertFalse(report.queryComplete)
        }
        let empty=ProcessSleepAssertions.parse([:],pid:7);XCTAssertEqual(empty.state,.noneObserved);XCTAssertTrue(empty.queryComplete)
    }
    func testBudgetsMaskAndEscapeNamesBeforePresentation() throws {
        let secret="fixture-sensitive-value"
        let report=ProcessSleepAssertions.parse([NSNumber(value:7):[row(name:"--api-key \(secret)\u{1b}"),row(),row()]],pid:7,maximumAssertions:2)
        XCTAssertEqual(report.assertions.count,2);XCTAssertTrue(report.limited);XCTAssertFalse(report.queryComplete)
        let encoded=String(decoding:try JSONEncoder().encode(report),as:UTF8.self)
        XCTAssertFalse(encoded.contains(secret));XCTAssertFalse(report.assertions[0].name?.contains("\u{1b}") == true)
        XCTAssertEqual(ProcessSleepAssertions.parse([:],pid:7,maximumAssertions:0).state,.unavailable)
    }
    func testUnavailablePIDDoesNotCallItNoAssertions() { XCTAssertEqual(ProcessSleepAssertions.capture(-1).state,.unavailable) }
}
