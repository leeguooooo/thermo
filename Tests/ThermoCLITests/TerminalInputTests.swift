import XCTest
@testable import thermo

final class TerminalInputTests: XCTestCase {
    func testCoalescedKeysAreConsumedIndividually() {
        var input = TerminalInput()
        input.append(Array("123q".utf8))
        XCTAssertEqual(input.next(), "1")
        XCTAssertEqual(input.next(), "2")
        XCTAssertEqual(input.next(), "3")
        XCTAssertEqual(input.next(), "q")
        XCTAssertNil(input.next())
    }

    func testFragmentedArrowDoesNotBecomeQuit() {
        var input = TerminalInput()
        input.append([0x1b]); XCTAssertNil(input.next())
        input.append([0x5b]); XCTAssertNil(input.next())
        input.append([0x43]); XCTAssertEqual(input.next(), "\u{1B}[C")
        input.append([0x1b, 0x4f, 0x44]); XCTAssertEqual(input.next(), "\u{1B}[D")
    }

    func testBareEscapeExpiresButIncompleteSequenceDoesNotQuit() {
        var input = TerminalInput()
        input.append([0x1b]); XCTAssertEqual(input.next(expireEscape: true), "\u{1B}")
        input.append([0x1b, 0x5b]); XCTAssertNil(input.next(expireEscape: true))
        input.append(Array("2".utf8)); XCTAssertEqual(input.next(), "2")
    }
}
