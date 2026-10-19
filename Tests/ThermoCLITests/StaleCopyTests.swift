import XCTest
@testable import thermo

final class StaleCopyTests: XCTestCase {
    func testWarnsOnlyForAnOlderCopyOutsideTheApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = dir.appendingPathComponent("Thermo.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try (["CFBundleShortVersionString": "1.1.25"] as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let copy = "/Users/x/.local/bin/thermo"
        let warning = App.staleCopyWarning(executable: copy, version: "1.1.18", apps: [app.path])
        XCTAssertTrue(warning?.contains("1.1.18") == true && warning?.contains("1.1.25") == true)
        XCTAssertTrue(warning?.contains("App CLI for future commands: '\(app.path)/Contents/Helpers/thermo'.") == true)
        XCTAssertFalse(warning?.contains("ln -") == true, "a copied or pinned binary is not an installation target")
        XCTAssertNil(App.staleCopyWarning(executable: copy, version: "1.1.25", apps: [app.path]), "same version")
        XCTAssertNil(App.staleCopyWarning(executable: copy, version: "1.1.100", apps: [app.path]), "newer than the app")
        XCTAssertNil(App.staleCopyWarning(executable: app.path + "/Contents/Helpers/thermo", version: "1.1.18", apps: [app.path]))
        XCTAssertNil(App.staleCopyWarning(executable: copy, version: "1.1.18", apps: [dir.appendingPathComponent("None.app").path]))
    }
    func testFutureCommandHandlesQuotedAppPathWithoutReplacingPinnedCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = dir.appendingPathComponent("Thermo's $(printf injected).app")
        let helper = app.appendingPathComponent("Contents/Helpers/thermo")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try (["CFBundleShortVersionString": "9.0"] as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try "#!/bin/sh\nprintf '%s\\n' \"$1\"\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let pinned = dir.appendingPathComponent("fixed candidate")
        let original = Data("owned pinned binary".utf8)
        try original.write(to: pinned)
        let warning = try XCTUnwrap(App.staleCopyWarning(executable: pinned.path, version: "1.0", apps: [app.path]))
        let marker = "App CLI for future commands: "
        let start = try XCTUnwrap(warning.range(of: marker)).upperBound
        XCTAssertTrue(warning.hasSuffix("."))
        let command = String(warning[start..<warning.index(before: warning.endIndex)])
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec " + command + " --hint-probe"]
        process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "--hint-probe\n")
        XCTAssertEqual(try Data(contentsOf: pinned), original)
        XCTAssertFalse((try pinned.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
    }

}
