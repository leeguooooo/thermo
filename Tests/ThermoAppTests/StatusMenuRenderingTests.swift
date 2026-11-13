import AppKit
import ThermoL10n
import XCTest
@testable import ThermoApp

@MainActor final class StatusMenuRenderingTests: XCTestCase {
    func testAppKitMenuHasLocalizedProductGroupsAndOriginalKeyboardBindings() {
        let previous = L10n.override
        L10n.override = .simplifiedChinese
        defer { L10n.override = previous }
        let menu = StatusMenu.shared.make(battery: false)
        for title in ["截图与录屏", "剪贴板与贴图", "系统与硬件", "清理与存储", "更多工具"] {
            let entries = menu.items.filter { $0.title == title }
            XCTAssertEqual(entries.count, 1, title)
            XCTAssertFalse(entries.first?.submenu?.items.isEmpty ?? true, title)
        }
        XCTAssertEqual(menu.item(withTitle: tr("Open Thermo"))?.keyEquivalent, "o")
        XCTAssertEqual(menu.item(withTitle: tr("Settings…"))?.keyEquivalent, ",")
        XCTAssertEqual(menu.item(withTitle: tr("Quit Thermo"))?.keyEquivalent, "q")
        func titles(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) }
        }
        let reachable = titles(menu)
        for action in ["Capture screen…", "Scrolling capture…", "Record screen…", "Open image…",
                       "Pin clipboard as text", "Pin clipboard as LaTeX", "Restore last closed pin",
                       "Restore pin mouse interaction", "Connections", "CPU usage", "GPU usage",
                       "Memory usage", "Smart Scan", "Space Lens", "Software", "Smart Check",
                       "Check for Updates…", "About Thermo", "Quit Thermo"] {
            XCTAssertTrue(reachable.contains(tr(action)), action)
        }
        XCTAssertFalse(reachable.contains(tr("Battery charging protection")))
    }
}
