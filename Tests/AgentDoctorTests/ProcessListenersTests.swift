import XCTest
@testable import AgentCore
@testable import AgentDoctor

final class ProcessListenersTests: XCTestCase {
    func result(_ output:String, status:Int32=0, timedOut:Bool=false, truncated:Bool=false) -> CommandRunner.Result {
        .init(status:status,output:output,timedOut:timedOut,cancelled:false,truncated:truncated)
    }
    func record(_ fd:Int,_ family:String,_ address:String) -> String { "f\(fd)\0t\(family)\0PTCP\0n\(address)\0\n" }
    func testMachineFieldsArePIDScopedAndDeduplicateEndpoints() {
        let output="p7\0\n"+record(3,"IPv4","127.0.0.1:8000")+record(4,"IPv6","[::1]:8001")+record(5,"IPv4","127.0.0.1:8000")
        let report=ProcessListeners.parse(result(output),pid:7)
        XCTAssertEqual(report.state,.observed);XCTAssertTrue(report.queryComplete);XCTAssertEqual(report.endpoints.count,2)
        XCTAssertEqual(report.endpoints.map(\.port),[8000,8001]);XCTAssertTrue(report.endpoints.allSatisfy { $0.addressKind == .loopback })
        XCTAssertEqual(ProcessListeners.parse(result(output),pid:8).state,.unavailable)
    }
    func testNoMatchIsDifferentFromPermissionTimeoutAndMalformedOutput() {
        let none=ProcessListeners.parse(result("",status:1),pid:7)
        XCTAssertEqual(none.state,.noneObserved);XCTAssertTrue(none.queryComplete)
        for input in [result("lsof: permission denied\n",status:1),result("",status:-1,timedOut:true),result(""),result("p7\0\nf3\0tIPv4\0PTCP\0nmalformed:80\0\n")] {
            let report=ProcessListeners.parse(input,pid:7);XCTAssertEqual(report.state,.unavailable);XCTAssertFalse(report.queryComplete)
        }
    }
    func testTruncationRetainsOnlyCompleteKnownRecords() {
        let output="p7\0\n"+record(3,"IPv4","127.0.0.1:8000")+"f4\0tIPv4\0PTCP\0n127.0.0.1:80"
        let report=ProcessListeners.parse(result(output,truncated:true),pid:7)
        XCTAssertEqual(report.state,.observed);XCTAssertEqual(report.endpoints.map(\.port),[8000]);XCTAssertFalse(report.queryComplete);XCTAssertTrue(report.limited)
    }
    func testAddressKindsDoNotClaimInternetReachability() throws {
        XCTAssertEqual(try XCTUnwrap(ProcessListeners.endpoint("*:8000",family:"IPv4")).addressKind,.wildcardAddress)
        XCTAssertEqual(try XCTUnwrap(ProcessListeners.endpoint("0.0.0.0:8000",family:"IPv4")).addressKind,.wildcardAddress)
        XCTAssertEqual(try XCTUnwrap(ProcessListeners.endpoint("127.42.1.2:8000",family:"IPv4")).addressKind,.loopback)
        XCTAssertEqual(try XCTUnwrap(ProcessListeners.endpoint("[::]:8000",family:"IPv6")).addressKind,.wildcardAddress)
        XCTAssertEqual(try XCTUnwrap(ProcessListeners.endpoint("[fe80::1%en0]:8000",family:"IPv6")).addressKind,.specifiedAddress)
        for value in ["localhost:80","127.0.0.1:+80","127.0.0.1:0","127.0.0.1:99999","127.0.0.1:80->8.8.8.8:80","127.0.0.1:\u{1b}80"] { XCTAssertNil(ProcessListeners.endpoint(value,family:"IPv4")) }
    }
    func testBudgetAndUnexpectedPIDNeverBecomeComplete() {
        let output="p7\0\n"+record(3,"IPv4","127.0.0.1:8000")+record(4,"IPv4","127.0.0.1:8001")+record(5,"IPv4","127.0.0.1:8002")
        let report=ProcessListeners.parse(result(output),pid:7,maximumEndpoints:2)
        XCTAssertEqual(report.endpoints.count,2);XCTAssertTrue(report.limited);XCTAssertFalse(report.queryComplete)
        XCTAssertEqual(ProcessListeners.parse(result(output+"p8\0\n"),pid:7).state,.unavailable)
    }
}
