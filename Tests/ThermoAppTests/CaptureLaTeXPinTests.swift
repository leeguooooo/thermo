import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

final class CaptureLaTeXPinTests:XCTestCase {
    @MainActor func testClipboardRecognizesLaTeXAndSupportsExplicitTextOverride() throws {
        let board=NSPasteboard.withUniqueName();defer { board.releaseGlobally() };board.setString("$$\\frac{1}{2}$$",forType:.string)
        guard case .content(.latex(let formula))=try CapturePinClipboard.read(board) else { return XCTFail("Expected formula") }
        XCTAssertEqual(formula.expression,"\\frac{1}{2}")
        guard case .content(.text)=try CapturePinClipboard.read(board,asText:true) else { return XCTFail("Expected text override") }
        board.clearContents();board.setString("a+b",forType:.string)
        guard case .content(.latex)=try CapturePinClipboard.read(board,asLaTeX:true) else { return XCTFail("Expected forced formula") }
    }
    @MainActor func testSourceCopyPreservesExactInputOnPrivatePasteboard() throws {
        let board=NSPasteboard.withUniqueName();defer { board.releaseGlobally() }
        let input="  \\[\\sum_{k=0}^{n} k\\]  "
        try CapturePinClipboard.copy(.latex(.init(source:input)),to:board);XCTAssertEqual(board.string(forType:.string),input)
        let formula=CaptureLaTeX(source:input)
        try CapturePinClipboard.copyFormula(formula,format:.mathml,to:board);XCTAssertTrue(board.string(forType:.string)?.contains("<munderover") == true)
        XCTAssertEqual(board.data(forType:.init("public.mathml")),board.string(forType:.string)?.data(using:.utf8))
        try CapturePinClipboard.copyFormula(formula,format:.svg,to:board);XCTAssertTrue(board.string(forType:.string)?.hasPrefix("<svg ") == true)
        XCTAssertEqual(board.data(forType:.init("public.svg-image")),board.string(forType:.string)?.data(using:.utf8))
        let before=board.string(forType:.string)
        XCTAssertThrowsError(try CapturePinClipboard.copyFormula(.init(source:"\\notACommand"),format:.svg,to:board));XCTAssertEqual(board.string(forType:.string),before)
    }
    @MainActor func testFailedFormulaEditRetainsSavedSourceAndBlocksClose() throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let session=CapturePinSession(store:.init(root:root)),id=try session.open(.latex(.init(source:"x^2"))),editor=try XCTUnwrap(session.windows[id])
        XCTAssertThrowsError(try editor.model.updatePinContent(.latex(.init(source:"\\frac{"))))
        XCTAssertFalse(editor.windowShouldClose(try XCTUnwrap(editor.window)))
        XCTAssertEqual(try session.store.snapshot(for:session.library.pins[0]).content,.latex(.init(source:"x^2")))
        editor.model.revertUnsavedPinText();try editor.model.updatePinContent(.latex(.init(source:"\\sqrt{x}")));try session.flush();session.closeAll()
        let next=CapturePinSession(store:.init(root:root));try next.restore(id);XCTAssertEqual(next.windows[id]?.model.pinContent,.latex(.init(source:"\\sqrt{x}")));next.closeAll()
    }
}
