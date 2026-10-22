import AppKit
import XCTest
@testable import CaptureCore

final class CaptureStitcherTests: XCTestCase {
    private func noise(width: Int = 80, height: Int = 240) -> CGImage {
        var seed: UInt64 = 179
        var bytes = [UInt8](repeating: 255, count: width*height*4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 32)
            bytes[i+1] = UInt8(truncatingIfNeeded: seed >> 40)
            bytes[i+2] = UInt8(truncatingIfNeeded: seed >> 48)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
    }
    func testVerticalOverlapPreservesEveryPixel() throws {
        let original = noise(), a = original.cropping(to: CGRect(x: 0,y: 0,width: 80,height: 150))!, b = original.cropping(to: CGRect(x: 0,y: 100,width: 80,height: 140))!
        let result = try CaptureStitcher.append(b, to: a)
        XCTAssertEqual(result.overlap, 50); XCTAssertFalse(result.duplicate)
        XCTAssertEqual(result.image.height, 240)
        XCTAssertEqual(try CaptureDocument(image: result.image).data(), try CaptureDocument(image: original).data())
    }
    func testHorizontalOverlapPreservesEveryPixel() throws {
        let original = noise(width: 240,height: 80), a = original.cropping(to: CGRect(x: 0,y: 0,width: 150,height: 80))!, b = original.cropping(to: CGRect(x: 100,y: 0,width: 140,height: 80))!
        let result = try CaptureStitcher.append(b, to: a, direction: .horizontal)
        XCTAssertEqual(result.overlap, 50); XCTAssertEqual(result.image.width, 240)
        XCTAssertEqual(try CaptureDocument(image: result.image).data(), try CaptureDocument(image: original).data())
    }
    func testRepeatedFrameDoesNotAppend() throws {
        let image = noise(); let result = try CaptureStitcher.append(image, to: image)
        XCTAssertTrue(result.duplicate); XCTAssertEqual(result.image.height, image.height)
    }
    func testNonOverlappingFramesAreRejected() {
        let image = noise(height: 300), a = image.cropping(to: CGRect(x: 0,y: 0,width: 80,height: 100))!, b = image.cropping(to: CGRect(x: 0,y: 200,width: 80,height: 100))!
        XCTAssertThrowsError(try CaptureStitcher.append(b, to: a))
    }
    func testSolidColorCannotBeAligned() {
        let ctx = CGContext(data: nil,width: 80,height: 100,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x: 0,y: 0,width: 80,height: 100))
        let image = ctx.makeImage()!
        XCTAssertThrowsError(try CaptureStitcher.append(image,to: image))
    }
    func testDimensionMismatchIsRejected() {
        XCTAssertThrowsError(try CaptureStitcher.append(noise(width: 50),to: noise()))
    }
}

extension CaptureStitcherTests {
    func testRepeatedLastViewportAfterGrowthDoesNotAppend() throws {
        let original = noise(), a = original.cropping(to: CGRect(x: 0,y: 0,width: 80,height: 150))!, b = original.cropping(to: CGRect(x: 0,y: 100,width: 80,height: 140))!
        let grown = try CaptureStitcher.append(b,to: a)
        let repeated = try CaptureStitcher.append(b,to: grown.image)
        XCTAssertTrue(repeated.duplicate); XCTAssertEqual(repeated.image.height,240)
    }
}
