import XCTest
@testable import thermo

final class TerminalLayoutTests: XCTestCase {
    func testClipsStyledTextAndResetsColor() {
        XCTAssertEqual(TerminalLayout.fit("\u{1B}[31mabcdef\u{1B}[0m", columns: 3), "\u{1B}[31mabc\u{1B}[0m")
        XCTAssertEqual(TerminalLayout.fit("abc", columns: 0), "")
    }

    func testWideAndComposedCharactersUseDisplayCells() {
        XCTAssertEqual(TerminalLayout.fit("中日ab", columns: 5), "中日a")
        XCTAssertEqual(TerminalLayout.fit("e\u{301}xy", columns: 2), "e\u{301}x")
        XCTAssertEqual(TerminalLayout.fit("👨‍👩‍👧‍👦xy", columns: 3), "👨‍👩‍👧‍👦x")
        XCTAssertEqual(TerminalLayout.fit("🇯🇵x", columns: 2), "🇯🇵")
    }

    func testUntrustedNamesCannotAddRowsOrMoveCursor() {
        XCTAssertEqual(TerminalLayout.fit("a\r\nb\t\u{7}c", columns: 10), "abc")
        XCTAssertFalse(TerminalLayout.fit("a\u{1B}[2Jb", columns: 10).contains("\u{1B}[2J"))
    }
}
