import CleanKit
import XCTest
@testable import thermo

final class UpdateSourceReportTests: XCTestCase {
    func testCompleteSourceJSONUsesReportObject() throws {
        let command = AppsCommand(app: App(args: try Args(["--json"])))
        var output = ""
        try command.writeUpdateSources(.init(sources: [], roots: ["/fixture"]), write: { output = $0 })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(json["complete"] as? Bool, true); XCTAssertNotNil(json["sources"]); XCTAssertNotNil(json["issues"])
    }
    func testIncompleteJSONIsPrintedBeforeFailing() throws {
        let command = AppsCommand(app: App(args: try Args(["--json"])))
        let report = NativeUpdateSourcesReport(sources: [], issues: [.init("Could not inspect application directory", path: "/fixture")])
        var output = ""
        XCTAssertThrowsError(try command.writeUpdateSources(report, write: { output = $0 }))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(json["complete"] as? Bool, false)
        XCTAssertEqual((json["issues"] as? [[String: Any]])?.count, 1)
    }
    func testIncompleteInventoryRequiresExactPathInsteadOfPotentiallyAmbiguousName() throws {
        let app = InstalledApp(path: "/fixture/Known.app", name: "Known", bundleID: "com.example.known")
        let source = try XCTUnwrap(NativeAppUpdates.sources(apps: [app]).first)
        let report = NativeUpdateSourcesReport(sources: [source], issues: [.init("unreadable", path: "/other")])
        let command = AppsCommand(app: App(args: try Args([])))
        XCTAssertThrowsError(try command.updateSource("Known", in: report))
        XCTAssertEqual(try command.updateSource(app.path, in: report).app.path, app.path)
    }
    func testKnownMetadataIssueDoesNotPreventNameSelectionWithinCompleteScope() throws {
        let app = InstalledApp(path: "/fixture/Known.app", name: "Known", bundleID: "com.example.known")
        let source = try XCTUnwrap(NativeAppUpdates.sources(apps: [app]).first)
        let report = NativeUpdateSourcesReport(sources: [source], issues: [.init("metadata unknown", path: "/other.app", affectsScope: false)])
        XCTAssertFalse(report.complete); XCTAssertTrue(report.scopeComplete)
        let command = AppsCommand(app: App(args: try Args([])))
        XCTAssertEqual(try command.updateSource("Known", in: report).app.path, app.path)
        XCTAssertThrowsError(try command.updateSource("com.example.known", in: report))
        XCTAssertEqual(try command.updateSource("com.example.known", in: .init(sources: [source])).app.path, app.path)
    }

}
