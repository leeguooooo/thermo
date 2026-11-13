import Foundation
import ThermoKit
import XCTest
@testable import ThermoApp

final class AppInstallationTests: XCTestCase {
    func testExecutableReplacementIsDetectedEvenWithSameVersionAndSize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("com.example.thermo-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("Thermo")
        try Data("old".utf8).write(to: executable)
        let launched = try XCTUnwrap(AppExecutableStamp(url: executable))
        XCTAssertEqual(launched, AppExecutableStamp(url: executable))
        try Data("new".utf8).write(to: executable, options: .atomic)
        XCTAssertNotEqual(launched, AppExecutableStamp(url: executable))
    }

    func testDisplayedVersionIsCompiledIntoTheRunningExecutable() {
        XCTAssertTrue(AppInfo.version == ThermoVersion.string || AppInfo.version.hasPrefix(ThermoVersion.string + " ("))
    }

    @MainActor func testCancelledQuitNeverStartsAnotherInstance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("com.example.thermo-relaunch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("opened")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let script = AppInstallationMonitor.relaunchScript.replacingOccurrences(of: "-lt 60", with: "-lt 2")
            .replacingOccurrences(of: "exec /usr/bin/open", with: "exec /usr/bin/touch")
        process.arguments = ["-c", script, "test-relaunch", String(getpid()), marker.path]
        try process.run(); process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let exited = Process(); exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run(); exited.waitUntilExit()
        let relaunch = Process(); relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", script, "test-relaunch", String(exited.processIdentifier), marker.path]
        try relaunch.run(); relaunch.waitUntilExit()
        XCTAssertEqual(relaunch.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}
