import AppKit
import XCTest
@testable import CaptureCore

final class CaptureSaveTests:XCTestCase {
    private func image() -> CGImage {
        let ctx=CGContext(data:nil,width:32,height:24,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.red.cgColor);ctx.fill(CGRect(x:0,y:0,width:16,height:24));return ctx.makeImage()!
    }
    func testSettingsRoundTripAndInvalidConfigurations() throws {
        var value=CaptureSaveSettings();XCTAssertEqual(try .decode(value.data()),value);XCTAssertEqual(value.after,[.pin]);XCTAssertFalse(value.autoSave)
        value.after=[.copyImage,.copyImage];XCTAssertThrowsError(try value.data());value.after=[.quickSave];XCTAssertFalse(value.valid)
        value.quick.directory="/tmp";value.autoSave=true;XCTAssertFalse(value.valid);value.automatic.directory="/tmp";XCTAssertTrue(value.valid)
        value.quality = .nan;XCTAssertFalse(value.valid)
        XCTAssertThrowsError(try CaptureSaveSettings.decode(Data(repeating:32,count:65537)))
        let unknown=String(data:try CaptureSaveSettings().data(),encoding:.utf8)!.replacingOccurrences(of:"\"pin\"",with:"\"unknown\"")
        XCTAssertThrowsError(try CaptureSaveSettings.decode(Data(unknown.utf8)))
    }
    func testDateDimensionsUUIDAndSubfolderTemplates() throws {
        let uuid=UUID(uuidString:"00000000-0000-0000-0000-000000000123")!
        let path=try CaptureSaveNaming.relativePath(template:"$yyyy$/$MM$/Thermo-$yyyy-MM-dd_HH-mm-ss-SSS$-%width%x%height%-%uuid%-%os%.png",width:32,height:24,format:.jpeg,date:Date(timeIntervalSince1970:0),uuid:uuid,timeZone:TimeZone(secondsFromGMT:0)!)
        XCTAssertEqual(path,"1970/01/Thermo-1970-01-01_00-00-00-000-32x24-00000000-0000-0000-0000-000000000123-Mac.jpg")
        for bad in ["", "/tmp/shot", "../shot", "a/../shot", "a//shot", ".hidden/shot", "a\\b", "a\n", "$unknown$", "%HOME%", "file:name", String(repeating:"a",count:201)] {
            XCTAssertThrowsError(try CaptureSaveNaming.relativePath(template:bad,width:32,height:24,format:.png),bad)
        }
    }
    func testExclusiveSavesDoNotOverwriteFilesOrFollowSymlinks() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),outside=root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let doc=CaptureDocument(image:image()),destination=CaptureSaveDestination(directory:root.path,template:"2026/shot")
        let first=try CaptureImageSave.save(doc,to:destination,quality:0.9),original=try Data(contentsOf:first)
        let second=try CaptureImageSave.save(doc,to:destination,quality:0.9)
        XCTAssertEqual(second.lastPathComponent,"shot-2.png");XCTAssertEqual(try Data(contentsOf:first),original)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:first.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("redirect").path,withDestinationPath:outside.path)
        XCTAssertThrowsError(try CaptureImageSave.save(doc,to:.init(directory:root.path,template:"redirect/nope"),quality:0.9))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:outside.path).isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:first.deletingLastPathComponent().path).contains{$0.hasPrefix(".thermo-save")})
        XCTAssertThrowsError(try CaptureImageSave.save(doc,to:.init(directory:root.appendingPathComponent("absent").path),quality:0.9))
    }
    func testConcurrentCollisionWritersEachPublishCompleteUniqueImages() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let document=CaptureDocument(image:image()),destination=CaptureSaveDestination(directory:root.path,template:"same"),lock=NSLock()
        var urls:[URL]=[],failures:[Error]=[]
        DispatchQueue.concurrentPerform(iterations:8) { _ in
            do {let url=try CaptureImageSave.save(document,to:destination,quality:1);lock.lock();urls.append(url);lock.unlock()}
            catch {lock.lock();failures.append(error);lock.unlock()}
        }
        XCTAssertTrue(failures.isEmpty);XCTAssertEqual(Set(urls).count,8)
        for url in urls {XCTAssertEqual(NSBitmapImageRep(data:try Data(contentsOf:url))?.pixelsWide,32)}
    }
    func testImageFormatsPreserveSizeAndJPEGFlattensTransparency() throws {
        let doc=CaptureDocument(image:image())
        for format in CaptureSaveFormat.allCases {
            let data=try CaptureImageSave.encode(doc,format:format,quality:0.9),rep=try XCTUnwrap(NSBitmapImageRep(data:data))
            XCTAssertEqual(rep.pixelsWide,32);XCTAssertEqual(rep.pixelsHigh,24)
            let color=try XCTUnwrap(rep.colorAt(x:28,y:12)?.usingColorSpace(.deviceRGB))
            if format == .jpeg {XCTAssertGreaterThan(color.redComponent,0.95);XCTAssertGreaterThan(color.greenComponent,0.95);XCTAssertGreaterThan(color.blueComponent,0.95)} else {XCTAssertLessThan(color.alphaComponent,0.01)}
        }
    }
}
