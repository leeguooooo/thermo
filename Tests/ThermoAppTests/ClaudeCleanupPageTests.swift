import XCTest
@testable import CleanKit
@testable import ThermoApp

final class ClaudeCleanupPageTests: XCTestCase {
    func testStandaloneNavigation() {
        XCTAssertEqual(MainPage(argument: "claude-cleanup"), .claudeCleanup)
        XCTAssertEqual(MainPage(argument: "claude-cleanup:privacy"), .privacyTools)
    }
    @MainActor func testResetStartsUnselectedAndFolderSelectionExcludesItsChildren() {
        let model = ClaudeCleanupModel()
        XCTAssertTrue(model.selected.isEmpty)
        func candidate(_ target: ClaudeResetTarget, status: ClaudeResetCandidate.Status = .available) -> ClaudeResetCandidate {
            .init(target: target, path: "/fixture/" + target.relativePath, status: status, reason: nil, bytes: 1, snapshot: "fixture")
        }
        model.toggle(candidate(.credentials))
        model.toggle(candidate(.settings))
        XCTAssertEqual(model.selected, [.credentials, .settings])
        model.toggle(candidate(.codeData))
        XCTAssertEqual(model.selected, [.codeData])
        model.toggle(candidate(.globalConfig))
        XCTAssertEqual(model.selected, [.codeData, .globalConfig])
        model.toggle(candidate(.credentials))
        XCTAssertEqual(model.selected, [.credentials, .globalConfig])
        model.toggle(candidate(.desktopData, status: .blocked))
        XCTAssertFalse(model.selected.contains(.desktopData))
        model.busy = true
        model.toggle(candidate(.settings))
        XCTAssertFalse(model.selected.contains(.settings))
    }
}
