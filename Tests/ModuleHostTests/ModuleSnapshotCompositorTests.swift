import AppKit
import XCTest
@testable import ModuleHost

@MainActor final class ModuleSnapshotCompositorTests: XCTestCase {
    final class Canvas: NSView {
        let flipCoordinates: Bool
        init(flipped: Bool) { self.flipCoordinates = flipped; super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 100)) }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { flipCoordinates }
        override func draw(_ dirtyRect: NSRect) { NSColor.blue.setFill(); bounds.fill() }
    }
    func redPNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
    func testScenePlacementHonorsHostCoordinatesAndPreservesSurroundingPixels() throws {
        for flipped in [true, false] {
            let root = Canvas(flipped: flipped)
            let png = try ModuleSnapshotCompositor.capture(root, overlays: [(CGRect(x: 10, y: 10, width: 20, height: 20), try redPNG())])
            if let folder = ProcessInfo.processInfo.environment["THERMO_SNAPSHOT_TEST_OUTPUT"] {
                let directory = URL(fileURLWithPath: folder)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("flipped-\(flipped).png"))
            }
            let image = try XCTUnwrap(NSBitmapImageRep(data: png))
            let x = image.pixelsWide * 15 / 100
            let y = image.pixelsHigh * (flipped ? 15 : 85) / 100
            let inside = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(inside.redComponent, 0.9)
            XCTAssertLessThan(inside.blueComponent, 0.1)
            let outside = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(outside.blueComponent, 0.9)
        }
    }
    func testBadSceneDataFailsInsteadOfProducingABlankSuccess() {
        XCTAssertThrowsError(try ModuleSnapshotCompositor.capture(Canvas(flipped: true), overlays: [(CGRect(x: 0, y: 0, width: 20, height: 20), Data())]))
    }
}
