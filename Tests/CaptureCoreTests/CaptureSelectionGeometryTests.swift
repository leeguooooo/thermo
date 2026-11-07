import CoreGraphics
import XCTest
@testable import CaptureCore

final class CaptureSelectionGeometryTests: XCTestCase {
    typealias G = CaptureSelectionGeometry
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testDragInAnyDirectionNormalizesAndClampsToDisplay() {
        XCTAssertEqual(G.rect(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 100, y: 50), in: bounds), CGRect(x: 100, y: 50, width: 200, height: 150))
        XCTAssertEqual(G.rect(from: CGPoint(x: 900, y: 500), to: CGPoint(x: 1200, y: 700), in: bounds), CGRect(x: 900, y: 500, width: 100, height: 100))
    }

    func testFrontMostWindowWinsAndOffscreenPartsAreCut() {
        let front = CGRect(x: 100, y: 100, width: 200, height: 200), back = CGRect(x: 0, y: 0, width: 800, height: 500)
        XCTAssertEqual(G.window(at: CGPoint(x: 150, y: 150), in: [front, back], bounds: bounds), front)
        XCTAssertEqual(G.window(at: CGPoint(x: 600, y: 400), in: [front, back], bounds: bounds), back)
        XCTAssertNil(G.window(at: CGPoint(x: 900, y: 550), in: [front, back], bounds: bounds))
        let hanging = CGRect(x: 900, y: -50, width: 300, height: 200)
        XCTAssertEqual(G.window(at: CGPoint(x: 950, y: 10), in: [hanging], bounds: bounds), CGRect(x: 900, y: 0, width: 100, height: 150))
    }

    func testHandlesPreferCornersAndIgnoreTheInterior() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(G.handle(at: CGPoint(x: 102, y: 98), of: r), .topLeft)
        XCTAssertEqual(G.handle(at: CGPoint(x: 200, y: 203), of: r), .bottom)
        XCTAssertEqual(G.handle(at: CGPoint(x: 297, y: 150), of: r), .right)
        XCTAssertNil(G.handle(at: CGPoint(x: 200, y: 150), of: r))
        XCTAssertNil(G.handle(at: CGPoint(x: 500, y: 150), of: r))
    }

    func testResizeMovesOnlyTheDraggedEdgesAndFlipsPastTheOppositeEdge() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(G.resize(r, handle: .right, to: CGPoint(x: 350, y: 999), in: bounds), CGRect(x: 100, y: 100, width: 250, height: 100))
        XCTAssertEqual(G.resize(r, handle: .topLeft, to: CGPoint(x: 50, y: 80), in: bounds), CGRect(x: 50, y: 80, width: 250, height: 120))
        XCTAssertEqual(G.resize(r, handle: .left, to: CGPoint(x: 400, y: 0), in: bounds), CGRect(x: 300, y: 100, width: 100, height: 100))
        XCTAssertEqual(G.resize(r, handle: .bottom, to: CGPoint(x: 0, y: 900), in: bounds), CGRect(x: 100, y: 100, width: 200, height: 500))
    }

    func testMoveKeepsSizeAndStopsAtEdges() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(G.move(r, by: -500, 10, in: bounds), CGRect(x: 0, y: 110, width: 200, height: 100))
        XCTAssertEqual(G.move(r, by: 2000, 2000, in: bounds), CGRect(x: 800, y: 500, width: 200, height: 100))
    }

    func testPixelRectRoundsOutwardAndStaysInsideTheFrame() {
        let image = CGSize(width: 2000, height: 1200)
        XCTAssertEqual(G.pixelRect(CGRect(x: 10.25, y: 20.5, width: 100, height: 50), scale: 2, imageSize: image), CGRect(x: 20, y: 41, width: 201, height: 100))
        XCTAssertEqual(G.pixelRect(CGRect(x: 990, y: 590, width: 50, height: 50), scale: 2, imageSize: image), CGRect(x: 1980, y: 1180, width: 20, height: 20))
        XCTAssertNil(G.pixelRect(CGRect(x: 10, y: 10, width: 0, height: 10), scale: 2, imageSize: image))
        XCTAssertNil(G.pixelRect(CGRect(x: 10, y: 10, width: 10, height: 10), scale: .nan, imageSize: image))
        XCTAssertEqual(G.pixelSize(CGRect(x: 0, y: 0, width: 100.4, height: 50), scale: 2).width, 201)
    }

    func testHexIsZeroPaddedUppercase() {
        XCTAssertEqual(G.hex(red: 0, green: 10, blue: 255), "#000AFF")
    }

    func testDrawnPointsMapIntoTheCroppedImageWithABottomLeftOrigin() {
        let crop = CGRect(x: 200, y: 100, width: 400, height: 300)       // pixels, from rect (100,50,200,150) at 2x
        XCTAssertEqual(G.imagePoint(CGPoint(x: 100, y: 50), scale: 2, crop: crop), CGPoint(x: 0, y: 300))   // top-left
        XCTAssertEqual(G.imagePoint(CGPoint(x: 300, y: 200), scale: 2, crop: crop), CGPoint(x: 400, y: 0))  // bottom-right
    }


    /// End-to-end through the real renderer: a box drawn near the top-left of the selection must
    /// come out near the top-left of the saved image (catches a flipped y axis).
    func testMarksDrawnOnTheSelectorLandWhereTheyWereDrawnInTheSavedImage() throws {
        let width = 400, height = 300
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let crop = CGRect(x: 200, y: 100, width: width, height: height)   // selection (100,50,200,150) at 2x
        var document = CaptureDocument(image: try XCTUnwrap(ctx.makeImage()))
        // Box from (110,60) to (150,90) in selector points: 20–100 px right, 20–80 px down from the top.
        let points = [CGPoint(x: 110, y: 60), CGPoint(x: 150, y: 90)].map { G.imagePoint($0, scale: 2, crop: crop) }
        document.append(CaptureAnnotation(tool: .rectangle, points: points, color: .systemRed, width: 4))
        let image = try document.rendered()
        func isRed(x: Int, yFromTop: Int) throws -> Bool {
            var px = [UInt8](repeating: 0, count: 4)
            let one = try XCTUnwrap(CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            one.draw(try XCTUnwrap(image.cropping(to: CGRect(x: x, y: yFromTop, width: 1, height: 1))), in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return px[0] > 180 && px[1] < 120 && px[2] < 120
        }
        XCTAssertTrue(try isRed(x: 60, yFromTop: 20), "top edge near the top of the image")
        XCTAssertTrue(try isRed(x: 20, yFromTop: 50), "left edge")
        XCTAssertFalse(try isRed(x: 60, yFromTop: 280), "nothing mirrored to the bottom")
        XCTAssertFalse(try isRed(x: 60, yFromTop: 50), "inside of the box stays clear")
    }

}
