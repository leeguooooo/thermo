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
        XCTAssertTrue(warning?.contains("ln -sf '\(app.path)/Contents/Helpers/thermo' '\(copy)'") == true)
        XCTAssertNil(App.staleCopyWarning(executable: copy, version: "1.1.25", apps: [app.path]), "same version")
        XCTAssertNil(App.staleCopyWarning(executable: copy, version: "1.1.100", apps: [app.path]), "newer than the app")
        XCTAssertNil(App.staleCopyWarning(executable: app.path + "/Contents/Helpers/thermo", version: "1.1.18", apps: [app.path]))
        XCTAssertNil(App.staleCopyWarning(executable: copy, version: "1.1.18", apps: [dir.appendingPathComponent("None.app").path]))
    }
}
