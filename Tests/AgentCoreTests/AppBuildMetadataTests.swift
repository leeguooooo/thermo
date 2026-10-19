import XCTest
@testable import AgentCore

final class AppBuildMetadataTests: XCTestCase {
    private let sha = String(repeating: "a", count: 40)
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func app(_ root: URL, info: [String: Any]) throws -> URL {
        let contents = root.appendingPathComponent("Owned.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let cli = contents.appendingPathComponent("Helpers/thermo")
        try Data().write(to: cli)
        return cli
    }
    func testCleanAndDirtyAreExplicitPackageClaims() {
        for state in ["clean", "dirty"] {
            let value = AppBuildMetadata(info: ["CFBundleShortVersionString": "1.1.32", "CFBundleVersion": "508", "ThermoBuildSourceCommit": sha, "ThermoBuildWorkingTree": state])
            XCTAssertEqual(value.version, "1.1.32"); XCTAssertEqual(value.build, "508")
            XCTAssertEqual(value.sourceCommit, sha); XCTAssertEqual(value.workingTree.rawValue, state)
        }
        XCTAssertEqual(AppBuildMetadata(info: ["ThermoBuildSourceCommit": String(repeating: "b", count: 64)]).sourceCommit?.count, 64)
    }
    func testLegacyOrMalformedMetadataStaysUnknownWithoutLeakingValues() throws {
        let old = AppBuildMetadata(info: ["CFBundleShortVersionString": "1.1.32", "CFBundleVersion": "508"])
        XCTAssertNil(old.sourceCommit); XCTAssertEqual(old.workingTree, .unknown)
        let invalid = AppBuildMetadata(info: ["CFBundleShortVersionString": "PRIVATE_TOKEN", "CFBundleVersion": "private/path", "ThermoBuildSourceCommit": "PRIVATE_TOKEN", "ThermoBuildWorkingTree": "clean"])
        XCTAssertNil(invalid.sourceCommit); XCTAssertNil(invalid.version); XCTAssertNil(invalid.build)
        XCTAssertEqual(invalid.workingTree, .unknown)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(invalid), as: UTF8.self).contains("PRIVATE"))
        XCTAssertEqual(AppBuildMetadata(info: ["ThermoBuildSourceCommit": sha, "ThermoBuildWorkingTree": true]).workingTree, .unknown)
    }
    func testContainingExecutableAndItsSymlinkReadSameApp() throws {
        let root = try folder();let cli = try app(root, info: ["ThermoBuildSourceCommit": sha, "ThermoBuildWorkingTree": "clean"])
        let link = root.appendingPathComponent("thermo-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)
        XCTAssertEqual(AppBuildMetadata.containingCLI(executable: cli)?.sourceCommit, sha)
        XCTAssertEqual(AppBuildMetadata.containingCLI(executable: link)?.sourceCommit, sha)
    }
    func testOutsideAppAndWrongLocationsCannotBorrowNeighborMetadata() throws {
        let root = try folder();_ = try app(root, info: ["ThermoBuildSourceCommit": sha])
        XCTAssertNil(AppBuildMetadata.containingCLI(executable: root.appendingPathComponent("thermo")))
        XCTAssertNil(AppBuildMetadata.containingCLI(executable: root.appendingPathComponent("Owned.app/Contents/Other/thermo")))
        XCTAssertNil(AppBuildMetadata.containingCLI(executable: nil))
        XCTAssertNil(AppBuildMetadata.containingCLI(executable: URL(string: "https://example.invalid/Owned.app/Contents/Helpers/thermo")))
    }
    func testMalformedOversizedAndNonregularInfoAreRefusedWithoutBlocking() throws {
        let root = try folder();let cli = try app(root, info: [:]);let info = cli.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        for data in [Data("not a plist".utf8), Data(repeating: 32, count: 1_048_577)] {
            try data.write(to: info);XCTAssertNil(AppBuildMetadata.containingCLI(executable: cli))
        }
        try FileManager.default.removeItem(at: info)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: false)
        XCTAssertNil(AppBuildMetadata.containingCLI(executable: cli))
    }
}
