import XCTest
@testable import thermo

final class DevCommandTests: XCTestCase {
    func testDevCommandsAreInTheContractAndHelp() throws {
        XCTAssertNoThrow(try CommandContract.validate(Args(["dev", "new", "com.example.x", "--dir", "/tmp", "--name", "X"])))
        XCTAssertNoThrow(try CommandContract.validate(Args(["dev", "test", "folder", "--update"])))
        XCTAssertThrowsError(try CommandContract.validate(Args(["dev", "build", "--update"])), "--update belongs to dev test only")
        XCTAssertThrowsError(try CommandContract.validate(Args(["dev", "run", "--dry-run"])))
        let help = CommandHelp.text(for: ["dev"], capabilities: CommandHelp.capabilities)
        for verb in ["dev new ID", "dev build", "dev run", "dev test"] { XCTAssertTrue(help.contains(verb), verb) }
    }

    func testNewWritesARunnableTemplateWithoutTheApp() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-dev-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let app = App(args: try Args(["dev", "new", "com.example.cli", "--dir", parent.path]))
        try DevCommand(app: app).run(["new", "com.example.cli"])
        for path in ["module.json", "src/module.wat", "views/main.json", "fixtures/main.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent("cli/" + path).path), path)
        }
        XCTAssertThrowsError(try DevCommand(app: app).run(["new"]))
        XCTAssertThrowsError(try DevCommand(app: app).run(["frobnicate"]))
    }
}
