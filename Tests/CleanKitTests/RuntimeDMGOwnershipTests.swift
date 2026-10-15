import AgentCore
@testable import CleanKit
import Darwin
import Foundation
import XCTest

/// Real mount and kernel process enumeration; no user applications or user Trash are changed.
final class RuntimeDMGOwnershipTests: XCTestCase {
    var home = ""
    var child: Process?
    var childIdentity: ProcessIdentity?
    var uncertainAttach = false
    var image: String { home + "/fixture.dmg" }
    var mount: String { home + "/mounted" }
    var installed: String { home + "/Applications/RuntimeFixture.app" }
    var portable: String { mount + "/Portable.app" }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-runtime-dmg-" + UUID().uuidString)
            .resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard stopOwnedChild() else { XCTFail("owned test process did not stop; workspace preserved: " + home); return }
        guard NativeDiskImage.detachOwned(image), !uncertainAttach else { XCTFail("owned test mount cleanup is uncertain; workspace preserved: " + home); return }
        try FileManager.default.removeItem(atPath: home)
    }

    func command(_ executable: String, _ arguments: [String], timeout: Double = 45) throws {
        let result = CommandRunner.run(executable, arguments: arguments, timeout: timeout, outputLimit: 16_384)
        guard result.status == 0, !result.timedOut, !result.truncated else {
            throw NSError(domain: "RuntimeDMGFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: result.output])
        }
    }

    func stopOwnedChild() -> Bool {
        guard let child else { return true }
        if child.isRunning {
            guard let identity = childIdentity, ProcessTable.identity(child.processIdentifier) == identity else { return false }
            child.terminate()
            let until = Date().addingTimeInterval(2)
            while child.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning {
                guard ProcessTable.identity(child.processIdentifier) == identity else { return false }
                kill(child.processIdentifier, SIGKILL)
            }
        }
        child.waitUntilExit()
        return !child.isRunning
    }

    /// Use actual kernel entries, restricted to this test's process world for isolation.
    func fixtureProcesses() -> ProcessTable {
        let actual = ProcessTable.current(.init(cpu: false))
        let pids: Set<pid_t> = [getpid(), child?.processIdentifier ?? -1]
        return ProcessTable(entries: actual.entries.filter { pids.contains($0.pid) }, available: actual.available)
    }

    func moveToFixtureTrash(_ path: String) throws -> URL {
        let trash = home + "/.Trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        let destination = URL(fileURLWithPath: trash + "/" + UUID().uuidString + ".app")
        try FileManager.default.moveItem(atPath: path, toPath: destination.path)
        return destination
    }

    func testReadOnlyDMGRunningCopyKeepsSharedDataAndInvalidatesAnEarlierPlan() throws {
        let id = "com.example.runtimeqa.f" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let executable = installed + "/Contents/MacOS/Fixture"
        try FileManager.default.createDirectory(atPath: (executable as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let source = home + "/fixture.swift"
        try """
        import Foundation
        import AppKit
        import Darwin
        let observedHome = NSHomeDirectory()
        try Data(observedHome.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard observedHome == CommandLine.arguments[2] else { exit(17) }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { exit(0) }
            app.run()
        }
        """.write(toFile: source, atomically: true, encoding: .utf8)
        try command("/usr/bin/xcrun", ["swiftc", "-O", source, "-o", executable])
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "Fixture", "CFBundleName": "RuntimeFixture",
                                   "CFBundleVersion": "1", "CFBundlePackageType": "APPL", "LSBackgroundOnly": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: installed + "/Contents/Info.plist"))
        try command("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", installed])
        try FileManager.default.createDirectory(atPath: home + "/package", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: installed, toPath: home + "/package/Portable.app")
        try command("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", home + "/package", "-format", "UDZO", image])
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
        uncertainAttach = true
        try command("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, image])
        uncertainAttach = false
        var volume = statfs()
        XCTAssertEqual(statfs(mount, &volume), 0)
        XCTAssertNotEqual(volume.f_flags & UInt32(MNT_RDONLY), 0)

        let cache = home + "/Library/Caches/" + id
        let named = home + "/Library/Caches/RuntimeFixture"
        let payload = Data("fixture data".utf8)
        for path in [cache, named] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try payload.write(to: URL(fileURLWithPath: path + "/data"))
        }
        let target = try XCTUnwrap(AppUninstaller.read(installed))
        let roots = [home + "/Applications"]
        let before = AppUninstaller.plan(target, installed: [target], home: home, processes: fixtureProcesses(), ownershipDirectories: roots)
        XCTAssertNil(before.blocked)
        XCTAssertTrue(before.paths.contains(cache)); XCTAssertTrue(before.paths.contains(named))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: portable + "/Contents/MacOS/Fixture")
        let proof = home + "/observed-home.txt"
        process.arguments = [proof, home]
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        child = process
        childIdentity = ProcessTable.identity(process.processIdentifier)
        XCTAssertNotNil(childIdentity)
        let until = Date().addingTimeInterval(8)
        while process.isRunning && !FS.exists(proof) && Date() < until { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(try String(contentsOfFile: proof), home, "fixture must use its isolated home before starting AppKit")
        let actual = fixtureProcesses()
        XCTAssertTrue(actual.available)
        let entry = try XCTUnwrap(actual.entries.first { $0.pid == process.processIdentifier })
        let observedExecutable = try XCTUnwrap(entry.executable)
        XCTAssertEqual(FileIdentity.of(observedExecutable), FileIdentity.of(portable + "/Contents/MacOS/Fixture"))

        let stale = AppUninstaller.uninstall(before, home: home, processes: fixtureProcesses, ownershipDirectories: roots, move: moveToFixtureTrash)
        XCTAssertTrue(stale.removed.isEmpty)
        XCTAssertTrue(FS.exists(installed)); XCTAssertTrue(FS.exists(cache)); XCTAssertTrue(FS.exists(named))
        for path in [cache, named] { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path + "/data")), payload) }
        let current = AppUninstaller.plan(target, installed: [target], home: home, processes: actual, ownershipDirectories: roots)
        XCTAssertNil(current.blocked)
        XCTAssertEqual(current.paths, [installed])
        XCTAssertTrue(current.ownershipKept?.contains(cache) == true)
        XCTAssertTrue(current.ownershipKept?.contains(named) == true)
        let result = AppUninstaller.uninstall(current, home: home, processes: fixtureProcesses, ownershipDirectories: roots, move: moveToFixtureTrash)
        XCTAssertEqual(result.removed, [installed])
        XCTAssertTrue(result.failed.isEmpty, "\(result.failed)")
        XCTAssertTrue(FS.exists(cache)); XCTAssertTrue(FS.exists(named)); XCTAssertTrue(process.isRunning)
        for path in [cache, named] { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path + "/data")), payload) }
        XCTAssertEqual(ProcessTable.identity(process.processIdentifier), childIdentity)
        XCTAssertTrue(stopOwnedChild())
        XCTAssertTrue(NativeDiskImage.detachOwned(image))
    }
}
