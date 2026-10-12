import XCTest
@testable import CleanKit

final class DevelopmentPreservationTests: XCTestCase {
    func testAutomaticSelectionKeepsDevelopmentDependenciesButExplicitIDsStillWork() {
        let cache = CleanItem(id: "user-logs", category: .system, title: "Logs", safety: .safe, bytes: 10, paths: ["/fixture/logs"])
        let dependencies = [CleanCategory.devCaches, .projects, .xcode, .aiModels].enumerated().map {
            CleanItem(id: "dependency-\($0.offset)", category: $0.element, title: "Dependency", safety: .safe, bytes: 10, paths: ["/fixture/dependency-\($0.offset)"])
        }
        let report = ScanReport(items: [cache] + dependencies, denied: [], started: Date(), duration: 0)
        XCTAssertEqual(report.select(["safe"]).map(\.id), [cache.id])
        XCTAssertEqual(report.select([dependencies[0].id]).map(\.id), [dependencies[0].id])
        XCTAssertTrue(cache.automaticallySelected)
        XCTAssertTrue(dependencies.allSatisfy { !$0.automaticallySelected })
    }

    func testBrowserBuildsAreDependenciesWhileAgentLogsAreNot() {
        let browser = CleanItem(id: "playwright-browsers", category: .aiCaches, title: "Browsers", safety: .safe, bytes: 10, paths: ["/fixture/browser"])
        let logs = CleanItem(id: "claude-code-caches", category: .aiCaches, title: "Logs", safety: .safe, bytes: 10, paths: ["/fixture/logs"])
        XCTAssertFalse(browser.automaticallySelected)
        XCTAssertTrue(logs.automaticallySelected)
    }

    func testInstalledEnvironmentsAreProtectedAtDirectoryBoundaries() {
        XCTAssertTrue(DevelopmentPreservation.environment("/Users/test/Library/Developer/CoreSimulator/Devices", home: "/Users/test"))
        XCTAssertTrue(DevelopmentPreservation.environment("/Users/test/.rustup/toolchains", home: "/Users/test"))
        XCTAssertFalse(DevelopmentPreservation.environment("/Users/test/Library/Developer-not-a-sdk", home: "/Users/test"))
        XCTAssertFalse(DevelopmentPreservation.environment("/Users/test/Downloads/old.dmg", home: "/Users/test"))
    }
}
