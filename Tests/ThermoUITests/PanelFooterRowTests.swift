import AppKit
import SwiftUI
import XCTest
@testable import ThermoUI

/// The menu bar panel is 372 pt wide with 12 pt padding. Its bottom row must stay inside the 348 pt left over,
/// however many icons the installed modules add.
@MainActor final class PanelFooterRowTests: XCTestCase {
    private let width: CGFloat = 348

    private func fitted(icons count: Int) -> NSSize {
        let row = PanelFooterRow {
            PanelButton(title: "Open Console", symbol: "macwindow", prominent: true) {}
        } icons: {
            ForEach(0..<count, id: \.self) { _ in Image(systemName: "gauge").frame(width: 22) }
        }
        return NSHostingController(rootView: row).sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude))
    }

    func testAFewIconsStayOnTheButtonsRow() {
        let size = fitted(icons: 5)
        XCTAssertLessThanOrEqual(size.width, width)
        XCTAssertEqual(size.height, 24, accuracy: 1)
    }

    func testMoreIconsThanFitWrapInsteadOfWideningThePanel() {
        for count in [11, 20, 40] {
            let size = fitted(icons: count)
            XCTAssertLessThanOrEqual(size.width, width, "\(count) icons")
            XCTAssertGreaterThan(size.height, 24 + 6, "\(count) icons")
        }
    }

    /// What the row was before: the same content in an HStack asks for more than the panel has.
    func testThePlainRowThisReplacesDidOverflow() {
        let plain = HStack(spacing: 6) {
            PanelButton(title: "Open Console", symbol: "macwindow", prominent: true) {}
            ForEach(0..<11, id: \.self) { _ in Image(systemName: "gauge").frame(width: 22) }
        }
        let size = NSHostingController(rootView: plain).sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude))
        XCTAssertGreaterThan(size.width, width)
    }
}
