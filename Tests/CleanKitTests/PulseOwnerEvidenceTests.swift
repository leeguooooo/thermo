import AgentCore
import Foundation
import XCTest
@testable import CleanKit

final class PulseOwnerEvidenceTests: XCTestCase {
    func usage(_ pid: Int32, parent: Int32) -> ProcessUsage {
        var p = ProcessUsage(pid:pid,ppid:parent,uid:501,name:"fixture")
        p.started = Date(timeIntervalSince1970:10000+Double(pid));return p
    }
    func testAncestorUsesMatchingStartUIDAndCurrentParentRelation() {
        let child=usage(10,parent:20), ancestor=usage(20,parent:1)
        let identities: [Int32:ProcessIdentity] = [10:.init(pid:10,uid:501,started:child.started!,executable:"/usr/bin/node"),20:.init(pid:20,uid:501,started:ancestor.started!,executable:"/Applications/Terminal.app/Contents/MacOS/Terminal")]
        let owner=PulseSampler().owner(of:child,in:[10:child,20:ancestor],identity:{ identities[$0] },parent:{ $0==10 ? 20 : 1 })
        XCTAssertEqual(owner,"Terminal")
    }
    func testReusedPIDUnknownStartAndReparentingDoNotProduceAnOwner() {
        let child=usage(10,parent:20), ancestor=usage(20,parent:1)
        var identities: [Int32:ProcessIdentity] = [10:.init(pid:10,uid:501,started:child.started!,executable:"/usr/bin/node"),20:.init(pid:20,uid:501,started:ancestor.started!,executable:"/Applications/Terminal.app/Contents/MacOS/Terminal")]
        identities[20]?.started.addTimeInterval(1)
        XCTAssertNil(PulseSampler().owner(of:child,in:[10:child,20:ancestor],identity:{ identities[$0] },parent:{ $0==10 ? 20 : 1 }))
        identities[20]?.started = ancestor.started!
        XCTAssertNil(PulseSampler().owner(of:child,in:[10:child,20:ancestor],identity:{ identities[$0] },parent:{ _ in 1 }))
        var unknown=child;unknown.started=nil
        XCTAssertNil(PulseSampler().owner(of:unknown,in:[10:unknown,20:ancestor],identity:{ identities[$0] },parent:{ $0==10 ? 20 : 1 }))
    }
}
