import AppKit
import XCTest
@testable import CaptureCore

final class CaptureSelectionMarkupTests: XCTestCase {
    private func mark(_ tool: CaptureTool, _ x: CGFloat = 10, text: String = "") -> CaptureSelectionMark {
        CaptureSelectionMark(tool: tool, points: [CGPoint(x: x, y: 10), CGPoint(x: x + 20, y: 30)], text: text)
    }

    func testUndoAndRedoWalkTheMarksOfThisCapture() {
        var markup = CaptureSelectionMarkup()
        XCTAssertFalse(markup.canUndo); XCTAssertFalse(markup.canRedo)
        markup.add(mark(.rectangle)); markup.add(mark(.arrow))
        markup.undo()
        XCTAssertEqual(markup.marks.map(\.tool), [.rectangle]); XCTAssertTrue(markup.canRedo)
        markup.undo(); markup.undo()
        XCTAssertEqual(markup.marks.count, 0); XCTAssertFalse(markup.canUndo)
        markup.redo(); markup.redo(); markup.redo()
        XCTAssertEqual(markup.marks.map(\.tool), [.rectangle, .arrow]); XCTAssertFalse(markup.canRedo)
    }

    func testANewMarkClearsTheRedoRecord() {
        var markup = CaptureSelectionMarkup()
        markup.add(mark(.rectangle)); markup.add(mark(.arrow)); markup.undo()
        markup.add(mark(.mosaic))
        XCTAssertFalse(markup.canRedo)
        markup.redo()
        XCTAssertEqual(markup.marks.map(\.tool), [.rectangle, .mosaic])
    }

    func testSequenceNumbersContinueFromTheHighestRemainingBadge() {
        var markup = CaptureSelectionMarkup()
        XCTAssertEqual(markup.nextNumber, 1)
        markup.add(mark(.number, text: "1")); markup.add(mark(.rectangle)); markup.add(mark(.number, text: "2"))
        XCTAssertEqual(markup.nextNumber, 3)
        markup.undo(); markup.undo()
        XCTAssertEqual(markup.nextNumber, 2)
    }

    /// The copied image carries the marks: a red box drawn on a white selection shows up in the output pixels.
    func testRenderedImageCarriesTheMarksAtTheirSelectionPosition() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        let image = try XCTUnwrap(ctx.makeImage())
        var markup = CaptureSelectionMarkup()
        XCTAssertNil(try markup.rendered(onto: image, crop: CGRect(x: 0, y: 0, width: 100, height: 80), scale: 1), "No marks: the crop is used as is")
        markup.add(CaptureSelectionMark(tool: .rectangle, points: [CGPoint(x: 20, y: 10), CGPoint(x: 60, y: 50)]))
        markup.add(CaptureSelectionMark(tool: .number, points: [CGPoint(x: 80, y: 60)], text: "1"))
        let output = try XCTUnwrap(try markup.rendered(onto: image, crop: CGRect(x: 0, y: 0, width: 100, height: 80), scale: 1))
        XCTAssertEqual(output.width, 100); XCTAssertEqual(output.height, 80)
        // Selector points are top-left; (20, 30) lies on the box's left edge, (40, 30) inside it.
        XCTAssertTrue(isRed(output, x: 20, y: 30)); XCTAssertFalse(isRed(output, x: 40, y: 30))
        // The badge centre holds the white label; 12 px left is still inside the ≥18 px filled circle.
        XCTAssertTrue(isRed(output, x: 68, y: 60), "The sequence badge is filled at its point")
    }

    /// Only the user's explicit choice runs: copy by default, a pin only from 钉在桌面, and a
    /// script or configured action keeps the steps it asked for.
    func testOutputsRunOnlyWhatWasChosen() {
        XCTAssertEqual(CaptureSelectionOutput.primary(confirm: nil).steps, [.copyImage])
        XCTAssertEqual(CaptureSelectionOutput.primary(confirm: [.quickSave]).steps, [.quickSave])
        XCTAssertEqual(CaptureSelectionOutput.pin.steps, [.pin])
        XCTAssertEqual(CaptureSelectionOutput.copyImage.steps, [.copyImage])
        XCTAssertEqual(CaptureSelectionOutput.copyText.steps, [.copyText])
        XCTAssertEqual(CaptureSelectionOutput.saved(copyAfterSave: false).steps, [])
        XCTAssertEqual(CaptureSelectionOutput.saved(copyAfterSave: true).steps, [.copyImage])
        XCTAssertNil(CaptureSelectionOutput.confirm(override: nil, scripted: false, saved: [.pin]), "Interactive capture copies, not the saved pin chain")
        XCTAssertEqual(CaptureSelectionOutput.confirm(override: nil, scripted: true, saved: [.pin, .copyImage]), [.pin, .copyImage])
        XCTAssertEqual(CaptureSelectionOutput.confirm(override: [.copyText], scripted: true, saved: [.pin]), [.copyText])
        XCTAssertEqual(CaptureSelectionOutput.confirm(override: [.quickSave], scripted: false, saved: [.pin]), [.quickSave])
    }

    private func isRed(_ image: CGImage, x: Int, y: Int) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGImage rows run top to bottom; draw the wanted pixel into the 1×1 context.
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return bytes[0] > 180 && bytes[1] < 120 && bytes[2] < 120
    }
}
