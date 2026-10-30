import XCTest
@testable import CleanKit
@testable import ThermoApp

final class ClaudeCleanupPageTests: XCTestCase {
    private func measured(_ target: ClaudeResetTarget, bytes: Int64,
                          status: ClaudeResetCandidate.Status = .available,
                          snapshot: String? = "measured") -> ClaudeResetCandidate {
        .init(target: target, path: "/fixture/" + target.relativePath, status: status,
              reason: nil, bytes: bytes, snapshot: snapshot)
    }

    @MainActor func testLocalDataCountsFoldersOnceAndKeepsGlobalStateSeparate() {
        let model = ClaudeCleanupModel()
        model.candidates = [measured(.credentials, bytes: 3), measured(.settings, bytes: 5),
                            measured(.codeData, bytes: 100), measured(.globalConfig, bytes: 7),
                            measured(.desktopIdentity, bytes: 1), measured(.desktopData, bytes: 200)]
        XCTAssertEqual(model.localBytes, 307)
        XCTAssertFalse(model.partiallyMeasured)
        model.toggle(model.candidates[1])
        model.toggle(model.candidates[3])
        XCTAssertEqual(model.pickedBytes, 12)
    }

    @MainActor func testUnmeasuredFolderReportsPartialDataWithoutHidingKnownFiles() {
        let model = ClaudeCleanupModel()
        model.candidates = [measured(.codeData, bytes: 0, status: .blocked, snapshot: nil),
                            measured(.settings, bytes: 1_000), measured(.globalConfig, bytes: 400),
                            measured(.desktopData, bytes: 0, status: .missing, snapshot: nil)]
        XCTAssertTrue(model.partiallyMeasured)
        XCTAssertEqual(model.localBytes, 1_400)
        model.candidates.removeFirst()
        XCTAssertFalse(model.partiallyMeasured, "A missing path is different from an unmeasured existing folder")
    }

    func testStandaloneNavigation() {
        XCTAssertEqual(MainPage(argument: "claude-cleanup"), .claude(.reset))
        XCTAssertEqual(MainPage(argument: "claude-cleanup:privacy"), .claude(.privacy))
        XCTAssertEqual(MainPage(argument: "claude"), .claude(.accounts))
        XCTAssertEqual(MainPage(argument: "claude:reset"), .claude(.reset))
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
