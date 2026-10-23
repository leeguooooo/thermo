import AppKit
import XCTest
@testable import CaptureCore

final class CaptureBatchImageExportTests:XCTestCase {
    private func document() throws -> CaptureDocument {
        let c=try XCTUnwrap(CGContext(data:nil,width:80,height:60,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));c.setFillColor(NSColor.red.cgColor);c.fill(CGRect(x:0,y:0,width:80,height:60));return CaptureDocument(image:try XCTUnwrap(c.makeImage()))
    }
    private func root() throws -> URL {let u=FileManager.default.temporaryDirectory.appendingPathComponent("batch-export-"+UUID().uuidString);try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true);return u}
    private func item(_ doc:CaptureDocument,title:String="same") -> CaptureBatchImageItem {.init(id:UUID(),groupID:UUID(),groupName:"QA group",title:title,source:.document(doc))}
    func testBatchPublishesUniqueSafeFilesAndManifestWithMatchingPixels() throws {
        let root=try root();defer{try? FileManager.default.removeItem(at:root)};try Data("keep".utf8).write(to:root.appendingPathComponent("keep.txt"))
        let doc=try document(),title="../../same / "+String(repeating:"中文",count:100)
        let result=try CaptureBatchImageExport.run([item(doc,title:title),item(doc,title:title)],in:root,format:.png)
        let manifest=try JSONDecoder().decode(CaptureBatchImageManifest.self,from:Data(contentsOf:result.folder.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.version,1);XCTAssertEqual(manifest.images.count,2);XCTAssertEqual(Set(manifest.images.map(\.file)).count,2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:result.folder.path).count,3)
        for entry in manifest.images {
            XCTAssertFalse(entry.file.contains("/"));XCTAssertLessThan(entry.file.utf8.count,150)
            XCTAssertEqual(try Data(contentsOf:result.folder.appendingPathComponent(entry.file)),try doc.data());XCTAssertEqual(entry.width,80);XCTAssertEqual(entry.title,title)
        }
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("keep.txt")),"keep")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix(".thermo-batch-")})
    }
    func testFailureAndCancellationRemoveStagedFilesWithoutTouchingExistingFiles() throws {
        let doc=try document()
        for cancellation in [false,true] {
            let root=try root();defer{try? FileManager.default.removeItem(at:root)};try Data("keep".utf8).write(to:root.appendingPathComponent("keep.txt"))
            var done=0,encoded=0
            XCTAssertThrowsError(try CaptureBatchImageExport.run([item(doc),item(doc)],in:root,format:.png,checkCancellation:{if cancellation && done==1 {throw CancellationError()}},progress:{count,_ in done=count},encode:{document,format,quality in
                encoded += 1;if !cancellation && encoded==2 {throw CaptureFailure.exportFailed}
                return try CaptureImageSave.encode(document,format:format,quality:quality)
            }))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["keep.txt"])
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("keep.txt")),"keep")
        }
    }
    func testSymlinkDestinationAndInvalidPlansDoNotWriteAnyFiles() throws {
        let root=try root();defer{try? FileManager.default.removeItem(at:root)};let target=root.appendingPathComponent("real"),link=root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        let i=item(try document())
        XCTAssertThrowsError(try CaptureBatchImageExport.run([i],in:link,format:.png));XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:target.path).isEmpty)
        XCTAssertThrowsError(try CaptureBatchImageExport.run([],in:target,format:.png));XCTAssertThrowsError(try CaptureBatchImageExport.run([i,i],in:target,format:.png));XCTAssertThrowsError(try CaptureBatchImageExport.run([i],in:target,format:.jpeg,quality:.nan))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:target.path).isEmpty)
    }
    func testSavedSnapshotIncludesColorAdjustmentsAndMissingSnapshotDoesNotPublish() throws {
        let root=try root();defer{try? FileManager.default.removeItem(at:root)};let store=CapturePinLibraryStore(root:root.appendingPathComponent("pins"));var library=try store.load();let pin=CaptureSavedPin(groupID:library.currentGroupID);library.pins=[pin]
        var doc=try document();try doc.applyImageAdjustments(.init(inverted:true));let saved=try store.save(library,documents:[pin.id:doc]),p=try XCTUnwrap(saved.pins.first)
        let result=try CaptureBatchImageExport.run([.init(id:p.id,groupID:p.groupID,groupName:"Group",title:"Saved",source:.saved(root:store.root,pin:p))],in:root,format:.png)
        XCTAssertEqual(try Data(contentsOf:result.folder.appendingPathComponent(result.images[0].file)),try doc.data())
        let before=try FileManager.default.contentsOfDirectory(atPath:root.path).sorted();var missing=p;missing.snapshotID=UUID()
        XCTAssertThrowsError(try CaptureBatchImageExport.run([.init(id:p.id,groupID:p.groupID,groupName:"Group",title:"Missing",source:.saved(root:store.root,pin:missing))],in:root,format:.png))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path).sorted(),before)
    }
    func testEachOfferedFormatProducesDecodableFilesWithItsOwnExtension() throws {
        let root=try root();defer{try? FileManager.default.removeItem(at:root)}
        let doc=try document()
        for format in CaptureSaveFormat.allCases {
            let result=try CaptureBatchImageExport.run([item(doc)],in:root,format:format,quality:0.7),entry=result.images[0]
            XCTAssertEqual((entry.file as NSString).pathExtension,format.fileExtension)
            let rep=try XCTUnwrap(NSBitmapImageRep(data:Data(contentsOf:result.folder.appendingPathComponent(entry.file))))
            XCTAssertEqual(rep.pixelsWide,80);XCTAssertEqual(rep.pixelsHigh,60)
        }
    }
}
