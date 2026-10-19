import XCTest
import ThermoKit
@testable import thermo

final class VersionReportTests: XCTestCase {
    func testStandaloneVersionReportExplicitlyLeavesAppUnknown() throws {
        let report = App.versionReport(executable: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual(object["cliVersion"] as? String, ThermoVersion.string)
        XCTAssertTrue(object["appPackage"] is NSNull)
    }
    func testPackageVersionIsNotSubstitutedForCompiledCLIOrInferredFromIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = root.appendingPathComponent("Owned.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = contents.appendingPathComponent("Helpers/thermo");try Data().write(to: cli)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "9.9.9", "CFBundleVersion": "508"], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let report = App.versionReport(executable: cli)
        XCTAssertEqual(report.cliVersion, ThermoVersion.string)
        XCTAssertEqual(report.appPackage?.version, "9.9.9")
        XCTAssertNil(report.appPackage?.sourceCommit)
    }
}
