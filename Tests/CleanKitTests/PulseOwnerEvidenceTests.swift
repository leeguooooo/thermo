import AgentCore
import Foundation
import XCTest
@testable import CleanKit

final class PulseOwnerEvidenceTests: XCTestCase {
    func process(_ pid: Int32,parent: Int32,exe: String) -> AgentProcess {
        var value=AgentProcess(pid:pid,ppid:parent,uid:501,name:"fixture",executable:exe)
        value.sampledIdentity = .init(pid:pid,uid:501,started:Date(timeIntervalSince1970:10000+Double(pid)),executable:exe)
        return value
    }
    func testDetailedRowsRequireMatchingSampledIdentitiesAndCurrentParents() {
        let child=process(10,parent:20,exe:"/usr/bin/node")
        let terminal=process(20,parent:1,exe:"/Applications/Terminal.app/Contents/MacOS/Terminal")
        let rows: [Int32:AgentProcess]=[10:child,20:terminal]
        let ids=rows.mapValues { $0.sampledIdentity! }
        let sampler=PulseSampler()
        XCTAssertEqual(sampler.owner(of:child,in:rows,identity:{ ids[$0] },parent:{ rows[$0]?.ppid }),"Terminal")
        var changed=ids;changed[20]?.started.addTimeInterval(1)
        XCTAssertNil(sampler.owner(of:child,in:rows,identity:{ changed[$0] },parent:{ rows[$0]?.ppid }))
        changed=ids;changed[20]?.uid=502
        XCTAssertNil(sampler.owner(of:child,in:rows,identity:{ changed[$0] },parent:{ rows[$0]?.ppid }))
        changed=ids;changed[20]?.executable="/usr/bin/false"
        XCTAssertNil(sampler.owner(of:child,in:rows,identity:{ changed[$0] },parent:{ rows[$0]?.ppid }))
        XCTAssertNil(sampler.owner(of:child,in:rows,identity:{ ids[$0] },parent:{ $0 == 10 ? 1 : rows[$0]?.ppid }))
        var unknown=child;unknown.sampledIdentity=nil
        XCTAssertNil(sampler.owner(of:unknown,in:rows,identity:{ ids[$0] },parent:{ rows[$0]?.ppid }))
    }
    func testDetailedRowsRecheckEarlierNodesBeforeReturningAnAncestor() {
        let child=process(10,parent:20,exe:"/usr/bin/node")
        let terminal=process(20,parent:1,exe:"/Applications/Terminal.app/Contents/MacOS/Terminal")
        let rows: [Int32:AgentProcess]=[10:child,20:terminal];var reads=0
        let owner=PulseSampler().owner(of:child,in:rows,identity:{ pid in
            if pid == 10 { reads += 1;if reads > 1 { return nil } }
            return rows[pid]?.sampledIdentity
        },parent:{ rows[$0]?.ppid })
        XCTAssertNil(owner)
    }
    func testDetailedRowsDoNotInventAnOwnerForLaunchdChildrenOrParentCycles() {
        let direct=process(10,parent:1,exe:"/usr/bin/node")
        XCTAssertNil(PulseSampler().owner(of:direct,in:[10:direct],identity:{ _ in direct.sampledIdentity },parent:{ _ in 1 }))
        let a=process(10,parent:20,exe:"/usr/bin/node"),b=process(20,parent:10,exe:"/usr/bin/python3")
        let rows: [Int32:AgentProcess]=[10:a,20:b]
        XCTAssertNil(PulseSampler().owner(of:a,in:rows,identity:{ rows[$0]?.sampledIdentity },parent:{ rows[$0]?.ppid }))
    }
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
