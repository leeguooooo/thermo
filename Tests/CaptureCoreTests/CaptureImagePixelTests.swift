import AppKit
import XCTest
@testable import CaptureCore

final class CaptureImagePixelTests:XCTestCase {
    private func image(_ bytes:[UInt8],width:Int,height:Int,info:CGBitmapInfo) throws -> CGImage {
        let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData)),space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
        return try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:space,bitmapInfo:info,provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    private var rgba:CGBitmapInfo {CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)}
    func testCoordinatesUseTopLeftAndDoNotMixAdjacentPixels() throws {
        let image=try image([255,0,0,255,0,0,255,255,0,255,0,255,255,255,255,255],width:2,height:2,info:rgba)
        let red=try CaptureImagePixelReader.read(image,x:0,y:0),blue=try CaptureImagePixelReader.read(image,x:1,y:0),green=try CaptureImagePixelReader.read(image,x:0,y:1)
        XCTAssertEqual(red.color.formatted(.hex),"#FF0000");XCTAssertEqual(blue.color.formatted(.hex),"#0000FF");XCTAssertEqual(green.color.formatted(.hex),"#00FF00");XCTAssertEqual(green.y,1)
    }
    func testPremultipliedAlphaIsConvertedToStraightColorAndTransparentIsStable() throws {
        let image=try image([64,32,16,128,0,0,0,0],width:2,height:1,info:rgba)
        let half=try CaptureImagePixelReader.read(image,x:0,y:0),transparent=try CaptureImagePixelReader.read(image,x:1,y:0)
        XCTAssertEqual(half.color.red,128);XCTAssertEqual(half.color.green,64);XCTAssertEqual(half.color.blue,32);XCTAssertEqual(half.color.alpha,128.0/255,accuracy:0.00001)
        XCTAssertEqual(half.color.formatted(.hex),"#80402080");XCTAssertEqual(transparent.color.formatted(.hex),"#00000000")
    }
    func testBgraSourceLayoutIsConvertedCorrectly() throws {
        let image=try image([30,20,10,255],width:1,height:1,info:.init(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue))
        XCTAssertEqual(try CaptureImagePixelReader.read(image,x:0,y:0).color.formatted(.hex),"#0A141E")
    }
    func testOutsideCoordinatesAreRejected() throws {
        let image=try image([255,0,0,255],width:1,height:1,info:rgba)
        for point in [(-1,0),(0,-1),(1,0),(0,1),(Int.max,Int.max)] {XCTAssertThrowsError(try CaptureImagePixelReader.read(image,x:point.0,y:point.1))}
    }
}
