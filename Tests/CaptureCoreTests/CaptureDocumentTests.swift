import AppKit
import XCTest
@testable import CaptureCore

final class CaptureDocumentTests: XCTestCase {
    func testLoadedPixelsRemainReadableAfterTemporarySourceIsRemoved() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer {try? FileManager.default.removeItem(at:url)}
        try CaptureDocument(image:image()).data().write(to:url)
        let loaded=try CaptureDocument.load(url)
        try FileManager.default.removeItem(at:url)
        XCTAssertEqual(pixel(loaded,x:50,y:10),[255,255,255,255])
        XCTAssertEqual(pixel(loaded,x:50,y:60),[255,0,0,255])
        let data=try CaptureDocument(image:loaded).data()
        let exported=try XCTUnwrap(NSBitmapImageRep(data:data)?.cgImage)
        XCTAssertEqual(pixel(exported,x:50,y:60),[255,0,0,255])
    }
    private func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 40, width: 100, height: 40))
        return ctx.makeImage()!
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width*image.height*4)
        data.withUnsafeMutableBytes { bytes in
            let ctx = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width*4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = ((image.height-1-y)*image.width+x)*4
        return Array(data[offset..<offset+4])
    }
    func testCropUsesCanvasCoordinatesAndCanUndo() throws {
        var document = CaptureDocument(image: image())
        // Crop top half in bottom-left canvas coordinates. Must keep red, not white.
        try document.crop(to: CGRect(x: 10, y: 45, width: 60, height: 25))
        XCTAssertEqual(document.image.width, 60); XCTAssertEqual(document.image.height, 25)
        XCTAssertEqual(pixel(document.image, x: 20, y: 12), [255,0,0,255])
        document.undo(); XCTAssertEqual(document.image.width, 100)
        document.redo(); XCTAssertEqual(document.image.height, 25)
    }
    func testOpaqueRedactionSurvivesPNGRoundTrip() throws {
        var document = CaptureDocument(image: image())
        document.append(.init(tool: .redact, points: [CGPoint(x: 10,y: 10), CGPoint(x: 60,y: 60)], color: .clear))
        let data = try document.data()
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage)
        XCTAssertEqual(pixel(decoded, x: 30, y: 30), [0,0,0,255])
        XCTAssertEqual(pixel(decoded, x: 80, y: 10), [255,255,255,255])
    }
    func testAnnotationUndoBranchDiscardsRedo() throws {
        var document = CaptureDocument(image: image())
        let annotation = CaptureAnnotation(tool: .rectangle, points: [.zero, CGPoint(x: 30,y: 30)])
        document.append(annotation); document.undo()
        XCTAssertTrue(document.canRedo); XCTAssertEqual(document.annotations.count, 0)
        document.append(annotation); XCTAssertFalse(document.canRedo)
        document.undo(); document.redo(); XCTAssertEqual(document.annotations.count, 1)
    }
    func testOutsideCropDoesNotMutateDocument() {
        var document = CaptureDocument(image: image())
        XCTAssertThrowsError(try document.crop(to: CGRect(x: 200,y: 200,width: 10,height: 10)))
        XCTAssertEqual(document.image.width, 100); XCTAssertFalse(document.canUndo)
    }
    func testCropBakesAnnotationsAndUndoRestoresEditableState() throws {
        var document = CaptureDocument(image: image())
        document.append(.init(tool: .redact, points: [.zero, CGPoint(x: 100, y: 80)]))
        try document.crop(to: CGRect(x: 10,y: 10,width: 20,height: 20))
        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertEqual(pixel(document.image, x: 10,y: 10), [0,0,0,255])
        document.undo(); XCTAssertEqual(document.annotations.count, 1); XCTAssertEqual(document.image.width, 100)
        document.undo(); XCTAssertTrue(document.annotations.isEmpty)
    }
    func testAllAnnotationRenderersExport() throws {
        for tool in CaptureTool.allCases where tool != .crop && tool != .move {
            var document = CaptureDocument(image: image())
            document.append(.init(tool: tool, points: [CGPoint(x: 20,y: 20), CGPoint(x: 60,y: 60)], text: "1"))
            XCTAssertFalse(try document.data().isEmpty, tool.rawValue)
        }
    }
}

extension CaptureDocumentTests {
    func testRotateAndFlipAreUndoableAndPreservePixels() throws {
        var document = CaptureDocument(image: image())
        let original = try document.data()
        for _ in 0..<4 { try document.transform(rotateClockwise: true) }
        XCTAssertEqual(try document.data(),original)
        try document.transform(flipHorizontal: true); try document.transform(flipHorizontal: true)
        XCTAssertEqual(try document.data(),original)
        document.undo(); document.redo(); XCTAssertEqual(try document.data(),original)
    }
}
