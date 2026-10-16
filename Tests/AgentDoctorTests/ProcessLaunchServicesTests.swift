import XCTest
@testable import AgentCore
@testable import AgentDoctor

final class ProcessLaunchServicesTests: XCTestCase {
    let identity = ProcessIdentity(pid:7,uid:501,started:Date(timeIntervalSince1970:100),executable:"/bin/sleep")
    func result(_ output:String, status:Int32=0, truncated:Bool=false) -> CommandRunner.Result {
        .init(status:status,output:output,timedOut:false,cancelled:false,truncated:truncated)
    }
    func domain(_ name:String, rows:String="") -> String { "\(name) = {\n\tservices = {\n\(rows)\t}\n}\n" }
    func testExplicitDomainsAndSingleServicePIDMustAgree() {
        var calls:[[String]]=[]
        let report=ProcessLaunchServices.capture(7,uid:501,identity:{ _ in self.identity },run:{ args in
            calls.append(args)
            if args[1]=="gui/501" { return self.result(self.domain(args[1],rows:"\t\t       7    (pe) \tfixture\n\t\t8 0 another-private-label\n")) }
            if args[1]=="gui/501/fixture" { return self.result("gui/501/fixture = {\n\tpid = 7\n\tstate = running\n\tchild = {\n\t\tpid = 8\n\t}\n}\n") }
            return self.result(self.domain(args[1]))
        })
        XCTAssertEqual(calls,[["print","gui/501"],["print","gui/501/fixture"],["print","user/501"]])
        XCTAssertEqual(report.state,.observed);XCTAssertTrue(report.queryComplete)
        XCTAssertEqual(report.registrations.map(\.label),["fixture"]);XCTAssertEqual(report.registrations.first?.serviceState,"running")
        XCTAssertFalse(String(decoding:try! JSONEncoder().encode(report),as:UTF8.self).contains("another-private-label"))
    }
    func testAbsentDirectPIDDoesNotBecomeUnavailable() {
        let report=ProcessLaunchServices.capture(7,uid:501,identity:{ _ in self.identity },run:{ self.result(self.domain($0[1],rows:"\t\t- 0 inactive\n\t\t0 1 stopped\n\t\t8 - another\n")) })
        XCTAssertEqual(report.state,.noneObserved);XCTAssertTrue(report.queryComplete)
    }
    func testMalformedOrWrongDomainsCannotClaimNoRegistration() {
        for text in [domain("gui/999"),"gui/501 = {\n\tservices = {\n",domain("gui/501",rows:"\t\tbad row\n"),domain("gui/501",rows:"\t\t7 0 ../escape\n"),domain("gui/501",rows:"\t\t\t7 0 nested\n")] {
            let report=ProcessLaunchServices.capture(7,uid:501,identity:{ _ in self.identity },run:{ _ in self.result(text) })
            XCTAssertEqual(report.state,.unavailable);XCTAssertFalse(report.queryComplete)
        }
    }
    func testServiceRestartOrFailedReadDoesNotAttributeOldPID() {
        for response in [result("gui/501/fixture = {\n\tpid = 8\n}\n"),result("wrong = {\n\tpid = 7\n}\n"),result("gui/501/fixture = {\n\tpid = 7\n\tpid = 7\n}\n"),result("gui/501/fixture = {\n\tpid = 7\n"),result("",status:1),result("gui/501/fixture = {\n\tpid = 7\n}\n",truncated:true)] {
            let report=ProcessLaunchServices.capture(7,uid:501,identity:{ _ in self.identity },run:{ args in
                args[1]=="gui/501" ? self.result(self.domain(args[1],rows:"\t\t7 0 fixture\n")) : args[1]=="user/501" ? self.result(self.domain(args[1])) : response
            })
            XCTAssertTrue(report.registrations.isEmpty);XCTAssertEqual(report.state,.unavailable);XCTAssertFalse(report.queryComplete)
        }
    }
    func testOneUnavailableDomainPreservesVerifiedOtherDomain() {
        let report=ProcessLaunchServices.capture(7,uid:501,identity:{ _ in self.identity },run:{ args in
            if args[1]=="gui/501" { return self.result(self.domain(args[1],rows:"\t\t7 0 fixture\n")) }
            if args[1]=="user/501" { return self.result("",status:1) }
            return self.result("gui/501/fixture = {\n\tpid = 7\n}\n")
        })
        XCTAssertEqual(report.state,.observed);XCTAssertEqual(report.registrations.count,1);XCTAssertFalse(report.queryComplete)
    }
    func testOtherUserAndChangingIdentityAreRejected() {
        var calls=0
        let other=ProcessLaunchServices.capture(7,uid:900,identity:{ _ in self.identity },run:{ _ in calls+=1;return self.result("") })
        XCTAssertEqual(calls,0);XCTAssertEqual(other.state,.unavailable)
        var readings=0
        let changed=ProcessLaunchServices.capture(7,uid:501,identity:{ _ in readings+=1;return readings==1 ? self.identity : nil },run:{ self.result(self.domain($0[1])) })
        XCTAssertEqual(changed.state,.unavailable);XCTAssertTrue(changed.registrations.isEmpty)
    }
    func testUserAndGUIRegistrationsStayDistinct() {
        let report=ProcessLaunchServices.capture(7,uid:501,identity:{ _ in self.identity },run:{ args in
            if args[1]=="gui/501" || args[1]=="user/501" { return self.result(self.domain(args[1],rows:"\t\t7 - fixture\n")) }
            return self.result(args[1]+" = {\n\tpid = 7\n}\n")
        })
        XCTAssertEqual(report.registrations.map(\.domain),["gui/501","user/501"])
        XCTAssertTrue(report.queryComplete)
    }
    func testCandidateBudgetAndNestedTablesFailClosed() {
        let rows=(0..<17).map { "\t\t7 0 label-\($0)\n" }.joined()
        XCTAssertNil(ProcessLaunchServices.labels(domain("gui/501",rows:rows),domain:"gui/501",pid:7))
        XCTAssertNil(ProcessLaunchServices.labels("gui/501 = {\n\tnested = {\n\t\tservices = {\n\t\t\t7 0 fixture\n\t\t}\n\t}\n}\n",domain:"gui/501",pid:7))
        XCTAssertEqual(ProcessLaunchServices.capture(-1).state,.unavailable)
    }
}
