import AppKit
import XCTest
@testable import ThermoApp

final class MenuStackImageTests: XCTestCase {
    @MainActor private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(image.size.width * 2)), pixelsHigh: Int(ceil(image.size.height * 2)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @MainActor func testBothRowsRenderInsideTheStatusHeightWithAnEmptyGap() throws {
        for height in [CGFloat(16), 18, 20] {
            for text in ["88 %\n↑ 123 KiB/s", "— °C\n↑ — KiB/s ☕︎"] {
                let image = MenuStackImage.make(text: text, showIcon: false, height: height)
                XCTAssertTrue(image.isTemplate)
                XCTAssertLessThanOrEqual(image.size.height, height)
                let rep = try bitmap(image)
                let inkRows = (0..<rep.pixelsHigh).filter { y in
                    (0..<rep.pixelsWide).contains { x in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 }
                }
                XCTAssertFalse(inkRows.isEmpty)
                XCTAssertFalse(inkRows.contains(0), "Top edge must not clip text")
                XCTAssertFalse(inkRows.contains(rep.pixelsHigh - 1), "Bottom edge must not clip text")
                let middle = rep.pixelsHigh / 2
                XCTAssertTrue(inkRows.contains { $0 < middle - 1 })
                XCTAssertTrue(inkRows.contains { $0 > middle + 1 })
                XCTAssertFalse(inkRows.contains(middle), "Rows need a clear separating gap")
            }
        }
    }

    @MainActor func testIconHasItsOwnSpaceAndLongUploadValuesStayInsideTheImage() throws {
        let text = "100 %\n↑ 123456 KiB/s ☕︎"
        let data = MenuStackImage.make(text: text, showIcon: false, height: 20)
        let combined = MenuStackImage.make(text: text, showIcon: true, height: 20)
        XCTAssertGreaterThan(combined.size.width, data.size.width)
        let rep = try bitmap(data)
        for y in 0..<rep.pixelsHigh {
            XCTAssertLessThan(rep.colorAt(x: 0, y: y)?.alphaComponent ?? 0, 0.1)
            XCTAssertLessThan(rep.colorAt(x: rep.pixelsWide - 1, y: y)?.alphaComponent ?? 0, 0.1)
        }
    }
}
