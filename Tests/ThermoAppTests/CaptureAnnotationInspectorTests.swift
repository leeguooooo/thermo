import AppKit
import XCTest
@testable import ThermoApp

final class CaptureAnnotationInspectorTests:XCTestCase {
    @MainActor func testUndoAndRedoKeepInspectorInSyncWithSelectedObject() throws {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let model=CaptureEditorModel(image:try XCTUnwrap(ctx.makeImage()))
        model.document.append(.init(tool:.mosaic,points:[CGPoint(x:10,y:10),CGPoint(x:40,y:40)]))
        model.selectAnnotation(0);model.annotationOptions.strength=36;model.applySelectedStyle()
        XCTAssertEqual(model.document.annotations[0].options.strength,36)
        model.undoAnnotation();XCTAssertEqual(model.document.annotations[0].options.strength,12);XCTAssertEqual(model.annotationOptions.strength,12)
        model.redoAnnotation();XCTAssertEqual(model.annotationOptions.strength,36)
    }
    @MainActor func testRemovingObjectClearsInvalidSelection() throws {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let model=CaptureEditorModel(image:try XCTUnwrap(ctx.makeImage()))
        model.document.append(.init(tool:.rectangle,points:[.zero,CGPoint(x:20,y:20)]));model.selectAnnotation(0)
        model.undoAnnotation();XCTAssertNil(model.selectedAnnotation)
    }
}
