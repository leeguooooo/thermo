import AppKit
import CaptureCore
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ThermoApp

@MainActor final class CaptureManualImageSaveTests:XCTestCase {
    private func document() -> CaptureDocument {
        let context=CGContext(data:nil,width:24,height:16,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:24,height:16))
        var value=CaptureDocument(image:context.makeImage()!)
        value.append(.init(tool:.redact,points:[CGPoint(x:4,y:4),CGPoint(x:20,y:12)]))
        return value
    }
    func testSaveReopensDirectoryAndFormatAndExportsAnnotationsInEveryFormat() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        var stored:Data?
        for (format,type) in [(CaptureSaveFormat.png,UTType.png),(.jpeg,.jpeg),(.tiff,.tiff)] {
            let save=CaptureManualImageSave(read:{stored},write:{stored=$0})
            save.select(format)
            let url=root.appendingPathComponent("image."+format.fileExtension)
            try save.save(document(),to:url,quality:0.9)
            let source=try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?,type.identifier)
            let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil)),rep=NSBitmapImageRep(cgImage:image)
            XCTAssertEqual(image.width,24);XCTAssertLessThan(try XCTUnwrap(rep.colorAt(x:12,y:8)?.usingColorSpace(.deviceRGB)).redComponent,0.08)
            let reopened=CaptureManualImageSave(read:{stored},write:{_ in XCTFail("Read must not write")})
            XCTAssertEqual(reopened.format,format);XCTAssertEqual(reopened.directory?.path,root.path)
        }
    }
    func testUnsavedSelectionAndWriteFailureDoNotReplaceRememberedDestination() throws {
        var stored:Data?
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let save=CaptureManualImageSave(read:{nil},write:{stored=$0});save.select(.jpeg)
        try save.save(document(),to:root.appendingPathComponent("saved.jpg"),quality:0.9)
        let before=stored
        let cancelled=CaptureManualImageSave(read:{stored},write:{stored=$0});cancelled.select(.tiff)
        XCTAssertEqual(stored,before)
        XCTAssertThrowsError(try cancelled.save(document(),to:root.appendingPathComponent("missing/image.tiff"),quality:0.9))
        XCTAssertEqual(stored,before)
        XCTAssertEqual(CaptureManualImageSave(read:{stored},write:{_ in}).format,.jpeg)
    }
    func testMissingFolderKeepsFormatAndMalformedPreferencesFallBack() throws {
        let data=Data("{\"directory\":\"/missing-thermo-\(UUID().uuidString)\",\"format\":\"tiff\"}".utf8)
        let missing=CaptureManualImageSave(read:{data},write:{_ in})
        XCTAssertNil(missing.directory);XCTAssertEqual(missing.format,.tiff)
        for invalid in [Data("invalid".utf8),Data("{\"directory\":\"relative\",\"format\":\"jpeg\"}".utf8),Data(repeating:32,count:8193)] {
            let value=CaptureManualImageSave(read:{invalid},write:{_ in})
            XCTAssertNil(value.directory);XCTAssertEqual(value.format,.png)
        }
    }
    func testPanelUsesOneFormatAndSwitchingPreservesCustomName() {
        _=NSApplication.shared
        let save=CaptureManualImageSave(read:{nil},write:{_ in XCTFail("Opening or cancelling a panel must not persist")})
        let panel=NSSavePanel();save.configure(panel,name:"Thermo-test")
        XCTAssertEqual(panel.nameFieldStringValue,"Thermo-test.png");XCTAssertEqual(panel.allowedContentTypes,[.png])
        panel.nameFieldStringValue="edited.name.PNG";save.select(.jpeg)
        XCTAssertEqual(panel.nameFieldStringValue,"edited.name.jpg");XCTAssertEqual(panel.allowedContentTypes,[.jpeg])
        save.select(.tiff)
        XCTAssertEqual(panel.nameFieldStringValue,"edited.name.tiff");XCTAssertEqual(panel.allowedContentTypes,[.tiff])
        XCTAssertFalse(panel.allowsOtherFileTypes);XCTAssertNotNil(panel.accessoryView)
    }
}
