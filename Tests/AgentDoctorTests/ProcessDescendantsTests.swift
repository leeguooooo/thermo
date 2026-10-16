import AgentCore
import Foundation
import XCTest
@testable import AgentDoctor

final class ProcessDescendantsTests: XCTestCase {
    func process(_ pid: Int32,_ parent: Int32,uid: UInt32 = 501) -> AgentProcess {
        var p=AgentProcess(pid:pid,ppid:parent,uid:uid,name:"fixture-\(pid)",executable:"/fixture/\(pid)",argv:["private-argument"],cwd:"/private-cwd")
        p.sampledIdentity = .init(pid:pid,uid:uid,started:Date(timeIntervalSince1970:Double(pid)),executable:p.executable!)
        return p
    }
    func read(_ rows: [AgentProcess],nodes: Int = 128,depth: Int = 16,complete: Bool = true,allUsers: Bool = true) -> ProcessDescendants {
        let byPID=Dictionary(rows.map { ($0.pid,$0) },uniquingKeysWith:{ a,_ in a })
        return ProcessDescendants.capture(rows[0].sampledIdentity!,table:.init(entries:rows,inventoryComplete:complete,includesAllUsers:allUsers),
            identity:{ byPID[$0]?.sampledIdentity },parent:{ byPID[$0]?.ppid },maximumNodes:nodes,maximumDepth:depth)
    }
    func testAllGenerationsPreserveVerifiedEdgesAndDepth() {
        let result=read([process(10,1),process(22,10),process(21,10),process(31,21),process(40,31),process(90,1)])
        XCTAssertEqual(result.children.map(\.pid),[21,31,40,22]);XCTAssertEqual(result.children.map(\.depth),[1,2,3,1])
        XCTAssertEqual(result.children.map(\.parentPID),[10,21,31,10]);XCTAssertTrue(result.queryComplete);XCTAssertFalse(result.limited)
    }
    func testVerifiedEmptyAndIncompleteInventoryAreDistinct() {
        let root=process(10,1)
        XCTAssertEqual(read([root]).state,.noneObserved)
        let incomplete=read([root],complete:false)
        XCTAssertEqual(incomplete.state,.unavailable);XCTAssertFalse(incomplete.queryComplete);XCTAssertFalse(incomplete.inventoryComplete)
        let filtered=read([root,process(20,10)],allUsers:false)
        XCTAssertEqual(filtered.state,.observed);XCTAssertFalse(filtered.queryComplete);XCTAssertFalse(filtered.inventoryComplete)
    }
    func testDepthAndNodeLimitsDoNotLookComplete() {
        let rows=[process(10,1),process(20,10),process(21,10),process(30,20)]
        let depth=read(rows,depth:1)
        XCTAssertEqual(depth.children.map(\.pid),[20,21]);XCTAssertFalse(depth.queryComplete);XCTAssertTrue(depth.limited)
        let count=read(rows,nodes:1)
        XCTAssertEqual(count.children.map(\.pid),[20]);XCTAssertFalse(count.queryComplete);XCTAssertTrue(count.limited)
    }
    func testUnavailableIntermediateNeverConnectsItsGrandchild() {
        let root=process(10,1),child=process(20,10),grandchild=process(30,20),sibling=process(21,10)
        let rows=[root,child,grandchild,sibling],byPID=Dictionary(uniqueKeysWithValues:rows.map { ($0.pid,$0) })
        let result=ProcessDescendants.capture(root.sampledIdentity!,table:.init(entries:rows),identity:{ $0 == 20 ? nil : byPID[$0]?.sampledIdentity },parent:{ byPID[$0]?.ppid })
        XCTAssertEqual(result.children.map(\.pid),[21]);XCTAssertFalse(result.queryComplete)
    }
    func testReparentingAfterInitialCheckDiscardsWholeSubtree() {
        let rows=[process(10,1),process(20,10),process(21,10),process(30,20)],byPID=Dictionary(uniqueKeysWithValues:rows.map { ($0.pid,$0) })
        var checks=0
        let result=ProcessDescendants.capture(rows[0].sampledIdentity!,table:.init(entries:rows),identity:{ byPID[$0]?.sampledIdentity },parent:{ pid in
            if pid == 20 { checks+=1;if checks > 1 { return 1 } };return byPID[pid]?.ppid
        })
        XCTAssertEqual(result.children.map(\.pid),[21]);XCTAssertFalse(result.queryComplete)
    }
    func testPIDReuseAfterInitialCheckDiscardsWholeSubtree() {
        let rows=[process(10,1),process(20,10),process(30,20)],byPID=Dictionary(uniqueKeysWithValues:rows.map { ($0.pid,$0) })
        var checks=0
        let result=ProcessDescendants.capture(rows[0].sampledIdentity!,table:.init(entries:rows),identity:{ pid in
            var value=byPID[pid]?.sampledIdentity
            if pid == 20 { checks+=1;if checks > 2 { value?.started.addTimeInterval(1) } };return value
        },parent:{ byPID[$0]?.ppid })
        XCTAssertTrue(result.children.isEmpty);XCTAssertEqual(result.state,.unavailable);XCTAssertFalse(result.queryComplete)
    }
    func testChangedTargetInvalidatesEveryChild() {
        let rows=[process(10,1),process(20,10)],byPID=Dictionary(uniqueKeysWithValues:rows.map { ($0.pid,$0) });var checks=0
        let result=ProcessDescendants.capture(rows[0].sampledIdentity!,table:.init(entries:rows),identity:{ pid in
            var value=byPID[pid]?.sampledIdentity
            if pid == 10 { checks+=1;if checks > 1 { value?.started.addTimeInterval(1) } };return value
        },parent:{ byPID[$0]?.ppid })
        XCTAssertEqual(result.state,.unavailable);XCTAssertTrue(result.children.isEmpty)
    }
    func testDuplicatePIDAndCycleDoNotProduceRepeatedOrMisattachedNodes() {
        let duplicate=read([process(10,1),process(20,10),process(20,99),process(30,20)])
        XCTAssertEqual(duplicate.state,.unavailable);XCTAssertTrue(duplicate.children.isEmpty)
        let cycle=read([process(10,20),process(20,10)])
        XCTAssertEqual(cycle.children.map(\.pid),[20]);XCTAssertFalse(cycle.queryComplete)
    }
    func testArgvFallbackOrMismatchedIdentityIsNotAChildProof() {
        var fallback=process(20,10);fallback.executableFromArgv=true
        var mismatch=process(21,10);mismatch.uid=900
        let result=read([process(10,1),fallback,mismatch,process(30,20)])
        XCTAssertEqual(result.state,.unavailable);XCTAssertTrue(result.children.isEmpty)
    }
    func testSoftTimeBudgetReturnsExplicitLimit() {
        let rows=[process(10,1),process(20,10)],byPID=Dictionary(uniqueKeysWithValues:rows.map { ($0.pid,$0) });var tick: UInt64=0
        let result=ProcessDescendants.capture(rows[0].sampledIdentity!,table:.init(entries:rows),identity:{ byPID[$0]?.sampledIdentity },parent:{ byPID[$0]?.ppid },clock:{ defer { tick+=1_000_000_000 };return tick })
        XCTAssertTrue(result.limited);XCTAssertFalse(result.queryComplete);XCTAssertTrue(result.children.isEmpty)
    }
    func testInvalidLimitsOrUnavailableTableAreRefused() {
        let root=process(10,1)
        XCTAssertEqual(read([root],nodes:0).state,.unavailable);XCTAssertEqual(read([root],depth:65).state,.unavailable)
        let result=ProcessDescendants.capture(root.sampledIdentity!,table:.init(entries:[root],available:false),identity:{ _ in root.sampledIdentity },parent:{ _ in 1 })
        XCTAssertEqual(result.state,.unavailable);XCTAssertFalse(result.queryComplete)
    }
    func testDescendantExportNeverIncludesArgumentsOrCwdAndEscapesControlText() throws {
        var child=process(20,10,uid:900);child.name="fixture\u{1b}";child.argv=["secret-other-user"];child.cwd="/secret-working-directory"
        let result=read([process(10,1),child]);let json=String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
        XCTAssertEqual(result.children.first?.name,"fixture\\u{1B}");XCTAssertFalse(json.contains("secret-other-user"));XCTAssertFalse(json.contains("secret-working-directory"))
    }
}
