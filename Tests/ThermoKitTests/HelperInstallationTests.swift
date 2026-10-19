import Darwin
import Foundation
import XCTest
@testable import ThermoKit

final class HelperInstallationTests: XCTestCase {
    private struct Fixture {
        let root: URL, binary: URL, plist: URL, installedBinary: URL, installedPlist: URL, tool: URL
        let log: URL, registered: URL, mode: URL
        let worker: Process?
        init(existing: Bool = true, registered: Bool = true, stopDelay: Double? = nil, holdsStop: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("helper installation '" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            binary = root.appendingPathComponent("new helper")
            plist = root.appendingPathComponent("new.plist")
            installedBinary = root.appendingPathComponent("installed/helper")
            installedPlist = root.appendingPathComponent("launchd/helper.plist")
            tool = root.appendingPathComponent("launchctl fixture")
            log = root.appendingPathComponent("calls")
            self.registered = root.appendingPathComponent("registered")
            mode = root.appendingPathComponent("failure-mode")
            let q = HelperInstaller.shellQuote
            if stopDelay != nil || holdsStop {
                if let stopDelay { precondition(stopDelay > 0 && stopDelay < 5) }
                let settling = holdsStop
                    ? "while test ! -e \(q(root.appendingPathComponent("allow-exit").path)); do /bin/sleep 0.02; done"
                    : "/bin/sleep \(stopDelay!)"
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/bin/sh")
                child.arguments = ["-c", "while test ! -e \(q(root.appendingPathComponent("stop").path)); do /bin/sleep 0.02; done; \(settling); /bin/rm -f \(q(root.appendingPathComponent("stopping").path))"]
                child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                try child.run()
                worker = child
            } else { worker = nil }
            try Data("new helper".utf8).write(to: binary)
            try HelperInstaller.plist(binary: installedBinary.path, source: "new-source").write(to: plist, atomically: true, encoding: .utf8)
            for dir in [installedBinary.deletingLastPathComponent(), installedPlist.deletingLastPathComponent()] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if existing {
                try Data("old helper".utf8).write(to: installedBinary)
                try HelperInstaller.plist(binary: installedBinary.path, source: "old-source").write(to: installedPlist, atomically: true, encoding: .utf8)
            }
            if registered { try Data().write(to: self.registered) }
            let stopHook = worker == nil ? ":" : "/usr/bin/touch \(q(root.appendingPathComponent("stopping").path)) \(q(root.appendingPathComponent("stop").path))"
            let script = """
            #!/bin/sh
            echo "$1" >> \(q(log.path))
            mode=$(/bin/cat \(q(mode.path)) 2>/dev/null)
            case "$1" in
                print)
                    if [ "$mode" = print ]; then echo "injected unknown print failure" >&2; exit 41; fi
                    if test -f \(q(self.registered.path)); then
                        \(worker == nil ? ":" : "echo 'pid = \(worker!.processIdentifier)'")
                        exit 0
                    fi
                    echo "Could not find service" >&2
                    exit 1;;
                bootout)
                    if [ "$mode" = bootout ]; then exit 42; fi
                    if test -f \(q(self.registered.path)); then
                        \(stopHook)
                    fi
                    /bin/rm -f \(q(self.registered.path));;
                bootstrap)
                    if test -f \(q(root.appendingPathComponent("stopping").path)); then exit 5; fi
                    if [ "$mode" = all-bootstrap ]; then exit 44; fi
                    if [ "$mode" = new-bootstrap ] && /usr/bin/grep -q new-source "$3"; then exit 43; fi
                    /usr/bin/touch \(q(self.registered.path));;
                *) exit 90;;
            esac
            """
            try script.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        }
        func execute(unloadAttempts: Int = 150, unloadInterval: Double = 0.1) throws -> (Int32, String) {
            let script = HelperInstaller.transactionalInstallationScript(binary: binary.path, plist: plist.path,
                installedBinary: installedBinary.path, installedPlist: installedPlist.path,
                owner: String(getuid()), group: String(getgid()), launchctl: tool.path,
                unloadAttempts: unloadAttempts, unloadInterval: unloadInterval)
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", script]
            process.standardError = pipe; process.standardOutput = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        var transactions: [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: installedBinary.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(".dev.thermo.install.") }
        }
        var calls: [String] { ((try? String(contentsOf: log)) ?? "").split(separator: "\n").map(String.init) }
        func fail(_ value: String) throws { try value.write(to: mode, atomically: true, encoding: .utf8) }
        func cleanup() {
            if let worker { if worker.isRunning { worker.terminate() }; worker.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testSuccessfulBootoutMustWaitForTheOwnedWorkerToExitBeforeBootstrap() throws {
        let f = try Fixture(stopDelay: 0.25); defer { f.cleanup() }
        let result = try f.execute()
        XCTAssertEqual(result.0, 0, result.1)
        XCTAssertEqual(try String(contentsOf: f.installedBinary), "new helper")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.registered.path))
        XCTAssertFalse(f.worker?.isRunning ?? true)
    }

    func testStopDeadlineKeepsOldFilesAndBackupWithoutBootstrappingOverLiveWorker() throws {
        let f = try Fixture(holdsStop: true); defer { f.cleanup() }
        let result = try f.execute(unloadAttempts: 2, unloadInterval: 0.01)
        XCTAssertNotEqual(result.0, 0)
        XCTAssertEqual(try String(contentsOf: f.installedBinary), "old helper")
        XCTAssertFalse(f.calls.contains("bootstrap"))
        XCTAssertTrue(f.worker?.isRunning ?? false)
        XCTAssertEqual(f.transactions.count, 1)
    }

    func testUnknownRegistrationFailureDoesNotMeanThereIsNoService() throws {
        let f = try Fixture(); defer { f.cleanup() }; try f.fail("print")
        let result = try f.execute()
        XCTAssertEqual(result.0, 41)
        XCTAssertEqual(f.calls, ["print"])
        XCTAssertEqual(try String(contentsOf: f.installedBinary), "old helper")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.registered.path))
    }

    func testStagingFailureDoesNotStopExistingDaemonOrChangeFiles() throws {
        for missingBinary in [true, false] {
            let f = try Fixture(); defer { f.cleanup() }
            if missingBinary { try FileManager.default.removeItem(at: f.binary) }
            else { try "invalid plist".write(to: f.plist, atomically: true, encoding: .utf8) }
            XCTAssertNotEqual(try f.execute().0, 0)
            XCTAssertTrue(f.calls.isEmpty)
            XCTAssertEqual(try String(contentsOf: f.installedBinary), "old helper")
            XCTAssertTrue(try String(contentsOf: f.installedPlist).contains("old-source"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.registered.path))
            XCTAssertTrue(f.transactions.isEmpty)
        }
    }

    func testNewBootstrapFailureRestoresOldFilesAndRegistrationButReportsFailure() throws {
        let f = try Fixture(); defer { f.cleanup() }; try f.fail("new-bootstrap")
        XCTAssertEqual(try f.execute().0, 43)
        XCTAssertEqual(try String(contentsOf: f.installedBinary), "old helper")
        XCTAssertTrue(try String(contentsOf: f.installedPlist).contains("old-source"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.registered.path))
        XCTAssertEqual(f.calls.filter { $0 != "print" }, ["bootout", "bootstrap", "bootout", "bootstrap"])
        XCTAssertTrue(f.transactions.isEmpty)
    }

    func testFirstInstallationFailureRemovesNewFilesAndDoesNotInventOldService() throws {
        let f = try Fixture(existing: false, registered: false); defer { f.cleanup() }; try f.fail("all-bootstrap")
        XCTAssertEqual(try f.execute().0, 44)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.installedBinary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.installedPlist.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.registered.path))
        XCTAssertEqual(f.calls.filter { $0 != "print" }, ["bootstrap", "bootout"])
        XCTAssertTrue(f.transactions.isEmpty)
    }

    func testFailedBootoutDoesNotReplaceFilesOrAttemptBootstrap() throws {
        let f = try Fixture(); defer { f.cleanup() }; try f.fail("bootout")
        XCTAssertEqual(try f.execute().0, 42)
        XCTAssertEqual(f.calls, ["print", "bootout"])
        XCTAssertEqual(try String(contentsOf: f.installedBinary), "old helper")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.registered.path))
        XCTAssertTrue(f.transactions.isEmpty)
    }

    func testFailedRecoveryPreservesBackupAndExplainsWhereItIs() throws {
        let f = try Fixture(); defer { f.cleanup() }; try f.fail("all-bootstrap")
        let result = try f.execute()
        XCTAssertEqual(result.0, 44); XCTAssertTrue(result.1.contains("recovery is incomplete"))
        let backup = try XCTUnwrap(f.transactions.first)
        XCTAssertTrue(result.1.contains(backup.resolvingSymlinksInPath().path), result.1)
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("old-helper")), "old helper")
        XCTAssertTrue(try String(contentsOf: backup.appendingPathComponent("old.plist")).contains("old-source"))
        XCTAssertEqual(try String(contentsOf: f.installedBinary), "old helper")
    }

    func testSymlinkedTargetIsRefusedWithoutStoppingDaemon() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let retained = f.root.appendingPathComponent("retained helper")
        try FileManager.default.moveItem(at: f.installedBinary, to: retained)
        try FileManager.default.createSymbolicLink(at: f.installedBinary, withDestinationURL: retained)
        XCTAssertNotEqual(try f.execute().0, 0)
        XCTAssertTrue(f.calls.isEmpty)
        XCTAssertEqual(try String(contentsOf: retained), "old helper")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: f.installedBinary.path), retained.path)
        XCTAssertTrue(f.transactions.isEmpty)
    }

    func testRegisteredServiceWithoutCompleteBackupIsNotStopped() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try FileManager.default.removeItem(at: f.installedPlist)
        XCTAssertNotEqual(try f.execute().0, 0)
        XCTAssertEqual(f.calls, ["print"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.registered.path))
        XCTAssertEqual(try String(contentsOf: f.installedBinary), "old helper")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.installedPlist.path))
        XCTAssertTrue(f.transactions.isEmpty)
    }

    func testCompleteMultilineInstallationCompilesAsPrivilegedAppleScriptWithoutExecutingIt() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let shell = HelperInstaller.transactionalInstallationScript(binary: f.binary.path, plist: f.plist.path,
            installedBinary: f.installedBinary.path, installedPlist: f.installedPlist.path,
            owner: String(getuid()), group: String(getgid()), launchctl: f.tool.path)
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", f.root.appendingPathComponent("compiled.scpt").path, "-e", HelperInstaller.privilegedAppleScript(shell)]
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try process.run(); let data = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        XCTAssertTrue(f.calls.isEmpty, "Compilation must not execute shell or launchctl")
        XCTAssertEqual(try String(contentsOf: f.installedBinary), "old helper")
    }

    func testSuccessfulFirstInstallAndUpgradeCleanPrivateStageAndSetModes() throws {
        for existing in [true, false] {
            let f = try Fixture(existing: existing, registered: existing); defer { f.cleanup() }
            XCTAssertEqual(try f.execute().0, 0)
            XCTAssertEqual(try String(contentsOf: f.installedBinary), "new helper")
            XCTAssertTrue(try String(contentsOf: f.installedPlist).contains("new-source"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.registered.path))
            XCTAssertTrue(f.transactions.isEmpty)
            for (url, mode) in [(f.installedBinary, 0o755), (f.installedPlist, 0o644)] {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, mode)
            }
        }
    }
}
