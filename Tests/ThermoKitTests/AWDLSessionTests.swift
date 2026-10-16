import Foundation
import XCTest
@testable import ThermoKit

final class AWDLSessionTests: XCTestCase {
    let owner="11111111-1111-1111-1111-111111111111"
    final class Rig {
        var interface: AWDLInterfaceState? = .init(index:15,up:true)
        var disk: AWDLRestoreRecord?
        var time: TimeInterval=100
        var boot: String?="22222222-2222-2222-2222-222222222222"
        var saveFails=false,clearFails=false,loadFails=false,readFails=false,ignoreWrite=false,writeThrowsAfterChange=false
        var events: [String]=[]
        func controller() -> AWDLSessionController {
            .init(io:.init(read:{
                if self.readFails { throw AWDLError("read failed") };return self.interface
            },write:{ index,up in
                self.events.append(up ? "up" : "down")
                XCTAssertNotNil(self.disk,"durable recovery record must precede writes")
                guard self.interface?.index == index else { throw AWDLError("identity changed") }
                if !self.ignoreWrite { self.interface?.up=up }
                if self.writeThrowsAfterChange { throw AWDLError("reported write failure") }
            }),store:.init(load:{
                if self.loadFails { throw AWDLError("cannot load") };return self.disk
            },save:{ value in
                self.events.append("save")
                if self.saveFails { throw AWDLError("cannot save") };XCTAssertNil(self.disk);self.disk=value
            },clear:{ value in
                self.events.append("clear")
                if self.clearFails { throw AWDLError("cannot clear") };XCTAssertEqual(self.disk,value);self.disk=nil
            }),boot:{ self.boot },clock:{ self.time })
        }
    }
    func testDurableIntentPrecedesDisableAndVerifiedRestorePrecedesClear() throws {
        let rig=Rig(),c=rig.controller();try c.begin(owner:owner,seconds:60)
        XCTAssertEqual(rig.events,["save","down"]);XCTAssertFalse(rig.interface!.up)
        XCTAssertEqual(c.snapshot(for:owner).phase,.active);XCTAssertTrue(c.snapshot(for:owner).ownedByCaller)
        try c.end(owner:owner)
        XCTAssertEqual(rig.events,["save","down","up","clear"]);XCTAssertTrue(rig.interface!.up);XCTAssertNil(rig.disk)
        XCTAssertEqual(c.snapshot().phase,.idle)
    }
    func testPersistenceFailureNeverChangesTheInterface() {
        let rig=Rig();rig.saveFails=true;let c=rig.controller()
        XCTAssertThrowsError(try c.begin(owner:owner,seconds:60));XCTAssertEqual(rig.events,["save"]);XCTAssertTrue(rig.interface!.up)
    }
    func testAlreadyDownRestoresDownWithoutAnyInterfaceWrite() throws {
        let rig=Rig();rig.interface?.up=false;let c=rig.controller()
        try c.begin(owner:owner,seconds:60);try c.end(owner:owner)
        XCTAssertEqual(rig.events,["save","clear"]);XCTAssertFalse(rig.interface!.up)
    }
    func testExpiryAndBackwardsClockRestoreWithoutResuming() throws {
        for end in [99.0,161.0,Double.nan] {
            let rig=Rig(),c=rig.controller();try c.begin(owner:owner,seconds:60);rig.time=end;c.tick()
            XCTAssertEqual(c.snapshot().phase,.idle);XCTAssertTrue(rig.interface!.up);XCTAssertNil(rig.disk)
            rig.time=200;c.tick();XCTAssertEqual(rig.events.filter { $0 == "down" }.count,1)
        }
    }
    func testRestartRestoresSavedOriginalInsteadOfResumingSession() throws {
        let rig=Rig();var first: AWDLSessionController?=rig.controller()
        try first!.begin(owner:owner,seconds:3600);first=nil
        let restarted=rig.controller()
        XCTAssertTrue(rig.interface!.up);XCTAssertNil(rig.disk);XCTAssertEqual(restarted.snapshot().phase,.idle)
        XCTAssertEqual(restarted.snapshot().lastEndReason,"helperStarted")
    }
    func testUnconfirmedRestoreRetainsRecordAndRetries() throws {
        let rig=Rig(),c=rig.controller();try c.begin(owner:owner,seconds:60)
        rig.ignoreWrite=true;XCTAssertThrowsError(try c.end(owner:owner))
        XCTAssertNotNil(rig.disk);XCTAssertEqual(c.snapshot().phase,.recovering)
        XCTAssertThrowsError(try c.begin(owner:owner,seconds:60))
        rig.ignoreWrite=false;c.tick()
        XCTAssertTrue(rig.interface!.up);XCTAssertNil(rig.disk);XCTAssertEqual(c.snapshot().phase,.idle)
    }
    func testFailedReadbackAfterStartRestoresAndThrows() {
        let rig=Rig();rig.ignoreWrite=true;let c=rig.controller()
        XCTAssertThrowsError(try c.begin(owner:owner,seconds:60))
        XCTAssertTrue(rig.interface!.up);XCTAssertNil(rig.disk);XCTAssertEqual(c.snapshot().phase,.idle)
    }
    func testReportedWriteFailureStillVerifiesActualRecovery() throws {
        let rig=Rig(),c=rig.controller();try c.begin(owner:owner,seconds:60)
        rig.writeThrowsAfterChange=true;try c.end(owner:owner)
        XCTAssertTrue(rig.interface!.up);XCTAssertNil(rig.disk)
    }
    func testOwnerIsolationDuplicateStartAndDisconnect() throws {
        let rig=Rig(),c=rig.controller();try c.begin(owner:owner,seconds:60)
        let other="33333333-3333-3333-3333-333333333333"
        XCTAssertThrowsError(try c.begin(owner:owner,seconds:60));XCTAssertThrowsError(try c.end(owner:other))
        c.disconnected(owner:other);XCTAssertFalse(rig.interface!.up)
        c.disconnected(owner:owner);XCTAssertTrue(rig.interface!.up);XCTAssertNil(rig.disk)
    }
    func testChangedInterfaceOrBootNeverReceivesAnOldRestoreWrite() throws {
        for changeBoot in [false,true] {
            let rig=Rig(),c=rig.controller();try c.begin(owner:owner,seconds:60)
            let before=rig.events.count
            if changeBoot { rig.boot="44444444-4444-4444-4444-444444444444" }
            else { rig.interface = .init(index:16,up:false) }
            c.tick()
            XCTAssertEqual(Array(rig.events.dropFirst(before)),["clear"]);XCTAssertNil(rig.disk)
            XCTAssertEqual(c.snapshot().lastEndReason,changeBoot ? "bootChanged" : "interfaceReplaced")
        }
    }
    func testMissingInterfaceAtRecoveryDoesNotWriteAnotherInterface() throws {
        let rig=Rig(),c=rig.controller();try c.begin(owner:owner,seconds:60)
        rig.interface=nil;let before=rig.events.count;c.tick()
        XCTAssertEqual(Array(rig.events.dropFirst(before)),["clear"]);XCTAssertNil(rig.disk)
    }
    func testUnreadableIdentityOrLeaseBlocksWithoutInventingOriginalFlags() {
        let rig=Rig();rig.loadFails=true;let c=rig.controller()
        XCTAssertThrowsError(try c.begin(owner:owner,seconds:60));XCTAssertTrue(rig.events.isEmpty)
        rig.loadFails=false;rig.boot=nil
        XCTAssertThrowsError(try c.begin(owner:owner,seconds:60));XCTAssertTrue(rig.events.isEmpty)
    }
    func testReadFailureDuringActiveModeRetainsRecoveryUntilKnownAgain() throws {
        let rig=Rig(),c=rig.controller();try c.begin(owner:owner,seconds:60)
        rig.readFails=true;c.tick();XCTAssertNotNil(rig.disk);XCTAssertEqual(c.snapshot().phase,.recovering)
        rig.readFails=false;c.tick();XCTAssertTrue(rig.interface!.up);XCTAssertNil(rig.disk)
    }
    func testRecordCleanupFailureIsNotReportedAsCompleteRecovery() throws {
        let rig=Rig(),c=rig.controller();try c.begin(owner:owner,seconds:60)
        rig.clearFails=true;XCTAssertThrowsError(try c.end(owner:owner))
        XCTAssertTrue(rig.interface!.up);XCTAssertNotNil(rig.disk);XCTAssertEqual(c.snapshot().phase,.recovering)
        rig.clearFails=false;c.tick();XCTAssertNil(rig.disk)
    }
    func testInvalidRequestsCannotCreateLeaseOrWrite() {
        let rig=Rig(),c=rig.controller()
        for seconds in [0,59,3601,Int.max] { XCTAssertThrowsError(try c.begin(owner:owner,seconds:seconds)) }
        XCTAssertThrowsError(try c.begin(owner:"arbitrary-owner",seconds:60));XCTAssertTrue(rig.events.isEmpty)
    }
    func testBootUUIDCaseDoesNotDiscardARealRecovery() {
        let rig=Rig();rig.boot="ABCDEFAB-2222-2222-2222-222222222222";rig.interface?.up=false
        rig.disk = .init(index:15,wasUp:true,bootSession:rig.boot!.lowercased())
        let c=rig.controller();XCTAssertTrue(rig.interface!.up);XCTAssertEqual(c.snapshot().lastEndReason,"helperStarted")
        XCTAssertEqual(rig.events,["up","clear"])
    }
    func testRecoveredReadDoesNotKeepAStaleQueryError() {
        let rig=Rig(),c=rig.controller();rig.readFails=true;XCTAssertNotNil(c.snapshot().error)
        rig.readFails=false;XCTAssertNil(c.snapshot().error);XCTAssertTrue(c.snapshot().interfaceQueryComplete)
    }
}
