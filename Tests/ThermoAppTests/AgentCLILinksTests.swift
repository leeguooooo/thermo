import XCTest
@testable import ThermoApp

final class AgentCLILinksTests: XCTestCase {
    private var root: String!
    private var cli: String { root + "/cli" }
    private var bin: String { root + "/bin" }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: URL(fileURLWithPath: cli))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
    }
    override func tearDownWithError() throws { try fm.removeItem(atPath: root) }

    func testBothAliasesRequireAnExecutableTarget() throws {
        try AgentCLILinks.link(directory: bin, cli: cli)
        XCTAssertTrue(AgentCLILinks.ready(directory: bin, cli: cli))
        try fm.removeItem(atPath: cli)
        XCTAssertFalse(AgentCLILinks.ready(directory: bin, cli: cli))
    }

    func testCollisionOnSecondAliasLeavesFirstUnchanged() throws {
        try fm.createSymbolicLink(atPath: bin + "/thermo", withDestinationPath: "/fixture/previous")
        try Data("keep".utf8).write(to: URL(fileURLWithPath: bin + "/thermo-use"))
        XCTAssertThrowsError(try AgentCLILinks.link(directory: bin, cli: cli))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: bin + "/thermo"), "/fixture/previous")
        XCTAssertEqual(try String(contentsOfFile: bin + "/thermo-use"), "keep")
    }

    func testSecondLinkFailureRestoresOriginalLinks() throws {
        for name in AgentCLILinks.names {
            try fm.createSymbolicLink(atPath: bin + "/" + name, withDestinationPath: "/fixture/" + name)
        }
        var creations = 0
        XCTAssertThrowsError(try AgentCLILinks.link(directory: bin, cli: cli, createLink: { path, target in
            creations += 1
            if creations == 2 { throw NSError(domain: "fixture", code: 1) }
            try self.fm.createSymbolicLink(atPath: path, withDestinationPath: target)
        }))
        for name in AgentCLILinks.names {
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: bin + "/" + name), "/fixture/" + name)
        }
    }

    func testMissingCLILeavesExistingLinksUntouched() throws {
        try fm.createSymbolicLink(atPath: bin + "/thermo", withDestinationPath: "/fixture/previous")
        XCTAssertThrowsError(try AgentCLILinks.link(directory: bin, cli: root + "/missing"))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: bin + "/thermo"), "/fixture/previous")
    }

    func testConcurrentFileCreationIsPreservedAndFirstAliasRolledBack() throws {
        XCTAssertThrowsError(try AgentCLILinks.link(directory: bin, cli: cli, createLink: { path, target in
            try self.fm.createSymbolicLink(atPath: path, withDestinationPath: target)
            try Data("concurrent fixture".utf8).write(to: URL(fileURLWithPath: self.bin + "/thermo-use"))
        }))
        XCTAssertFalse(fm.fileExists(atPath: bin + "/thermo"))
        XCTAssertEqual(try String(contentsOfFile: bin + "/thermo-use"), "concurrent fixture")
    }
}
