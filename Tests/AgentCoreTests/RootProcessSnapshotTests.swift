import Foundation
import XCTest
@testable import AgentCore

final class RootProcessSnapshotTests: XCTestCase {
    let snapshot = RootProcessSnapshot(pid: 7, ppid: 1, uid: 0, name: "fixture.helper",
                                       started: Date(timeIntervalSince1970: 100))

    func testStablePublicRootMetadataHasNoPrivateDetails() throws {
        var reads = 0
        let row = try XCTUnwrap(ProcessTable.rootProcess(7, snapshot: { reads += 1; return self.snapshot },
                                                       path: { _ in "/fixture/helper" }))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(row.sampledIdentity, .init(pid: 7, uid: 0, started: snapshot.started, executable: "/fixture/helper"))
        XCTAssertEqual(row.ppid, 1); XCTAssertTrue(row.argv.isEmpty); XCTAssertNil(row.cwd)
        XCTAssertNil(row.memoryReading?.footprintKB); XCTAssertNil(row.memoryReading?.residentKB)
    }

    func testMissingMetadataPathAndWrongUserDoNotCreateRootIdentity() {
        XCTAssertNil(ProcessTable.rootProcess(7, snapshot: { nil }, path: { _ in "/fixture/helper" }))
        XCTAssertNil(ProcessTable.rootProcess(7, snapshot: { self.snapshot }, path: { _ in nil }))
        XCTAssertNil(ProcessTable.rootProcess(7, snapshot: { self.snapshot }, path: { _ in "relative" }))
        var wrong = snapshot; wrong.uid = 501
        XCTAssertNil(ProcessTable.rootProcess(7, snapshot: { wrong }, path: { _ in "/fixture/helper" }))
        wrong = snapshot; wrong.pid = 8
        XCTAssertNil(ProcessTable.rootProcess(7, snapshot: { wrong }, path: { _ in "/fixture/helper" }))
        wrong = snapshot; wrong.started = Date(timeIntervalSince1970: 0)
        XCTAssertNil(ProcessTable.rootProcess(7, snapshot: { wrong }, path: { _ in "/fixture/helper" }))
    }

    func testPIDReuseOrReparentingDuringPathReadIsRejected() {
        for reparent in [false, true] {
            var current = snapshot
            let row = ProcessTable.rootProcess(7, snapshot: { current }, path: { _ in
                if reparent { current.ppid = 8 } else { current.started.addTimeInterval(1) }
                return "/fixture/helper"
            })
            XCTAssertNil(row)
        }
    }
}
