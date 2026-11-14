import Foundation
import XCTest
@testable import ModuleKit

final class ModuleCommandLeaseTests: XCTestCase {
    private let feature="com.example.lease"
    private func home() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-lease-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        addTeardownBlock{try? FileManager.default.removeItem(at:root)}
        return root
    }
    private func child(_ mode:String,home:URL) throws -> Process {
        let binary=Bundle(for:Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ModuleLeaseProbe")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:binary.path),binary.path)
        let process=Process();process.executableURL=binary;process.arguments=[home.path,feature,mode]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run()
        let deadline=Date().addingTimeInterval(5)
        while process.isRunning && Date()<deadline && !FileManager.default.fileExists(atPath:home.appendingPathComponent("ready").path) {Thread.sleep(forTimeInterval:0.01)}
        guard FileManager.default.fileExists(atPath:home.appendingPathComponent("ready").path) else {
            try? Data().write(to:home.appendingPathComponent("done"));process.waitUntilExit()
            throw NSError(domain:"ModuleLeaseProbe",code:1,userInfo:[NSLocalizedDescriptionKey:"Child did not acquire its real command lease"])
        }
        return process
    }
    private func finish(_ child:Process,home:URL) {
        try? Data().write(to:home.appendingPathComponent("done"));child.waitUntilExit()
    }
    func testACommandInAnotherProcessRefusesSwitchingOffUntilItReturns() throws {
        let root=try home(),process=try child("blocking",home:root)
        defer{finish(process,home:root)}
        XCTAssertThrowsError(try ModuleCommandLease.quiesce(feature:feature,home:root.path))
        finish(process,home:root)
        let stop=try ModuleCommandLease.quiesce(feature:feature,home:root.path)
        XCTAssertTrue(stop.readersFinished);stop.release()
        XCTAssertEqual(process.terminationStatus,0)
    }
    func testWatchCooperatesWithStoppingAndNewCommandsCannotSlipIn() throws {
        let root=try home(),process=try child("watch",home:root)
        defer{finish(process,home:root)}
        let stop=try ModuleCommandLease.quiesce(feature:feature,home:root.path)
        defer{stop.release()}
        XCTAssertThrowsError(try ModuleCommandLease.begin(feature:feature,home:root.path,enabled:{true}))
        let deadline=Date().addingTimeInterval(3)
        while process.isRunning && Date()<deadline {Thread.sleep(forTimeInterval:0.01)}
        XCTAssertFalse(process.isRunning,"the owned probe exits itself; no signal is sent")
        XCTAssertTrue(stop.readersFinished)
        stop.release()
        XCTAssertThrowsError(try ModuleCommandLease.begin(feature:feature,home:root.path,enabled:{false}))
    }
    func testMultipleDescriptorsKeepReadersAliveUntilEveryLeaseEnds() throws {
        let root=try home()
        var first:ModuleCommandLease?=try ModuleCommandLease.begin(feature:feature,interruptible:true,home:root.path,enabled:{true})
        var second:ModuleCommandLease?=try ModuleCommandLease.begin(feature:feature,interruptible:true,home:root.path,enabled:{true})
        let stop=try ModuleCommandLease.quiesce(feature:feature,home:root.path)
        XCTAssertNotNil(first);XCTAssertNotNil(second)
        XCTAssertFalse(stop.readersFinished)
        first=nil;XCTAssertFalse(stop.readersFinished)
        second=nil;XCTAssertTrue(stop.readersFinished)
        stop.release()
    }
    func testDisabledAdmissionCannotLeaveAReaderBehind() throws {
        let root=try home()
        XCTAssertThrowsError(try ModuleCommandLease.begin(feature:feature,home:root.path,enabled:{false}))
        let stop=try ModuleCommandLease.quiesce(feature:feature,home:root.path)
        XCTAssertTrue(stop.readersFinished);stop.release()
    }
    func testInvalidIdentifierCannotCreateDirectories() throws {
        let root=try home()
        XCTAssertThrowsError(try ModuleCommandLease.begin(feature:"../escape",home:root.path,enabled:{true}))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }
    func testSymlinkedLeaseAndDirectoryCannotReachOutsideThePrivateLocation() throws {
        let root=try home(),outside=try home(),target=outside.appendingPathComponent("keep")
        try Data("owned fixture".utf8).write(to:target)
        let stop=try ModuleCommandLease.quiesce(feature:feature,home:root.path);stop.release()
        let admission=root.appendingPathComponent("Library/Application Support/Thermo/command-leases/"+feature+".admission")
        try FileManager.default.removeItem(at:admission)
        try FileManager.default.createSymbolicLink(at:admission,withDestinationURL:target)
        XCTAssertThrowsError(try ModuleCommandLease.begin(feature:feature,home:root.path,enabled:{true}))
        XCTAssertEqual(try Data(contentsOf:target),Data("owned fixture".utf8))
        let another=try home()
        try FileManager.default.createSymbolicLink(at:another.appendingPathComponent("Library"),withDestinationURL:outside)
        XCTAssertThrowsError(try ModuleCommandLease.begin(feature:feature,home:another.path,enabled:{true}))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:outside.path),["keep"])
    }
}
