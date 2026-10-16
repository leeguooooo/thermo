import XCTest
import Foundation
import AgentCore
@testable import thermo

final class VolumeTrashRestoreTests: XCTestCase {
    func testWritableAPFSVolumeUsesNativeTrashAndPreservesOriginalPathConflicts() throws {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = fm.temporaryDirectory.appendingPathComponent("thermo-volume-cli-" + UUID().uuidString).standardizedFileURL
        let image = root.appendingPathComponent("owned.dmg"), mount = root.appendingPathComponent("mount"), home = root.appendingPathComponent("home")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, plist: Bool = false) -> CommandRunner.Result {
            CommandRunner.run(executable, arguments: arguments, environment: environment, timeout: 30, captureError: !plist)
        }
        func dictionary(_ output: String) throws -> [String: Any] {
            try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil) as? [String: Any])
        }
        defer {
            // Never remove a workspace until the exact owned image is confirmed detached.
            let info = run("/usr/bin/hdiutil", ["info", "-plist"], plist: true)
            if info.status == 0, let data = try? dictionary(info.output), let images = data["images"] as? [[String: Any]] {
                let owned = images.filter { ($0["image-path"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path == image.path } ?? false }
                var detached = true
                for item in owned {
                    let entities = item["system-entities"] as? [[String: Any]] ?? []
                    if let device = entities.first?["dev-entry"] as? String {
                        if run("/usr/bin/hdiutil", ["detach", device]).status != 0 { detached = false }
                    } else { detached = false }
                }
                let verification = run("/usr/bin/hdiutil", ["info", "-plist"], plist: true)
                if verification.status == 0, let data = try? dictionary(verification.output), let remaining = data["images"] as? [[String: Any]] {
                    if remaining.contains(where: { ($0["image-path"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path == image.path } ?? false }) { detached = false }
                } else { detached = false }
                if detached { try? fm.removeItem(at: root) }
                else { XCTFail("owned image detach unconfirmed; retained " + root.path) }
            } else { XCTFail("could not verify owned image state; retained " + root.path) }
        }
        XCTAssertEqual(run("/usr/bin/hdiutil", ["create", "-size", "64m", "-fs", "APFS", "-volname", "ThermoRestoreQA", image.path]).status, 0)
        let attached = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, "-plist", image.path], plist: true)
        XCTAssertEqual(attached.status, 0)
        let entities = try XCTUnwrap(try dictionary(attached.output)["system-entities"] as? [[String: Any]])
        XCTAssertTrue(entities.contains { ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path == mount.path } ?? false })
        let source = root.appendingPathComponent("main.swift"), probe = root.appendingPathComponent("probe")
        try fm.copyItem(at: repo.appendingPathComponent("Tests/Fixtures/VolumeTrashProbe.swift"), to: source)
        XCTAssertEqual(run("/usr/bin/xcrun", ["swiftc", source.path, "-o", probe.path]).status, 0)
        let trashed = run(probe.path, [mount.path])
        XCTAssertEqual(trashed.status, 0, trashed.output)
        var entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(trashed.output.utf8)) as? [String: Any])
        let original = URL(fileURLWithPath: try XCTUnwrap(entry["original"] as? String))
        let destination = URL(fileURLWithPath: try XCTUnwrap(entry["destination"] as? String))
        XCTAssertEqual(destination.deletingLastPathComponent().path, entry["nativeQuery"] as? String)
        XCTAssertTrue(destination.path.contains("/.Trashes/"))
        entry.removeValue(forKey: "nativeQuery")
        let id = UUID().uuidString
        let folder = home.appendingPathComponent("Library/Application Support/Thermo/cleanup-batches")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var journal = try JSONSerialization.data(withJSONObject: ["id": id, "created": Date().timeIntervalSinceReferenceDate]); journal.append(10)
        journal.append(try JSONSerialization.data(withJSONObject: ["entry": entry])); journal.append(10)
        try journal.write(to: folder.appendingPathComponent(id + ".jsonl"))
        let sibling = Bundle(for: VolumeTrashRestoreTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("thermo")
        let binary = fm.isExecutableFile(atPath: sibling.path) ? sibling : repo.appendingPathComponent(".build/debug/thermo")
        let ownedBuildPrefix = repo.resolvingSymlinksInPath().path + "/.build/"
        let resolvedBinary = binary.resolvingSymlinksInPath().path
        guard resolvedBinary.hasPrefix(ownedBuildPrefix) else {
            XCTFail("Selected CLI is outside the owned build directory: " + resolvedBinary + "; expected " + ownedBuildPrefix)
            return
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path; environment["THERMO_LANG"] = "en"
        func restore(_ options: [String]) -> CommandRunner.Result { run(binary.path, ["clean", "restore", id] + options + ["--json"], environment: environment) }
        let preview = restore(["--dry-run"])
        XCTAssertEqual(preview.status, 0, preview.output)
        XCTAssertTrue(preview.output.contains("\"restored\""))
        XCTAssertFalse(fm.fileExists(atPath: original.path)); XCTAssertTrue(fm.fileExists(atPath: destination.path))
        let newBytes = Data("new owned conflict".utf8), oldBytes = Data("owned volume fixture".utf8)
        try newBytes.write(to: original)
        let conflict = restore(["--yes"])
        XCTAssertNotEqual(conflict.status, 0); XCTAssertTrue(conflict.output.contains("\"conflict\""))
        XCTAssertEqual(try Data(contentsOf: original), newBytes)
        XCTAssertEqual(try Data(contentsOf: destination), oldBytes)
        try fm.removeItem(at: original)
        let restored = restore(["--yes"])
        XCTAssertEqual(restored.status, 0, restored.output)
        XCTAssertEqual(try Data(contentsOf: original), oldBytes)
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }
}
