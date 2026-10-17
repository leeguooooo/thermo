import Foundation
import XCTest
@testable import ThermoKit

final class HelperInstallationTests: XCTestCase {
    func testInstallationShellReportsEachFailedStepAndDoesNotContinue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for failure in 0..<4 {
            let markers = (0..<4).map { root.appendingPathComponent("failure \(failure) step '\($0)") }
            let steps = markers.enumerated().map { index, marker in
                index == failure ? "/usr/bin/false" : "/usr/bin/touch " + HelperInstaller.shellQuote(marker.path)
            }
            let status = try run(HelperInstaller.installationScript(bootout: "/usr/bin/true", steps: steps))
            XCTAssertEqual(status, 1)
            for (index, marker) in markers.enumerated() {
                XCTAssertEqual(FileManager.default.fileExists(atPath: marker.path), index < failure)
            }
        }
    }

    func testFirstInstallationCanProceedWithoutAnExistingDaemon() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("installed")
        XCTAssertEqual(try run(HelperInstaller.installationScript(bootout: "/usr/bin/false", steps: [
            "/usr/bin/touch " + HelperInstaller.shellQuote(marker.path), "/usr/bin/true"
        ])), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    private func run(_ script: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
}
