import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureBatchImageExportModelTests:XCTestCase {
    private func document() throws -> CaptureDocument {
        _=NSApplication.shared
        let c=try XCTUnwrap(CGContext(data:nil,width:80,height:60,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));return CaptureDocument(image:try XCTUnwrap(c.makeImage()))
    }
    private func wait(_ model:CaptureBatchImageExportModel) async throws {
        for _ in 0..<1000 {if !model.running{return};try await Task.sleep(nanoseconds:10_000_000)}
        model.cancel();XCTFail("batch export did not become terminal")
    }
    func testScopeIncludesHiddenAndLockedImagesButNotClosedOrTypedAndCapturesUnsavedStateWithoutHistory() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("batch-plan-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=CapturePinLibraryStore(root:root);var library=try store.load();let first=library.currentGroupID,other=CapturePinGroup(name:"Other");library.groups.append(other)
        var a=CaptureSavedPin(groupID:first);a.hidden=true
        var b=CaptureSavedPin(groupID:first);b.locked=true
        var closed=CaptureSavedPin(groupID:first);closed.closedAt=Date()
        var text=CaptureSavedPin(groupID:first);text.contentKind="text"
        let c=CaptureSavedPin(groupID:other.id),doc=try document();library.pins=[a,b,closed,text,c]
        try store.save(library,documents:Dictionary(uniqueKeysWithValues:library.pins.map{($0.id,doc)}),contents:[text.id:.text(.init(plain:"typed"))])
        let session=CapturePinSession(store:.init(root:root));defer{session.closeAll()}
        XCTAssertEqual(try session.batchImageItems(group:nil).count,3);XCTAssertEqual(try session.batchImageItems(group:first).count,2)
        session.batchExport.selectedGroupID=other.id;session.batchExport.allGroups=true
        XCTAssertEqual(try session.batchExport.itemsForExport(from:session).count,3)
        session.batchExport.allGroups=false
        XCTAssertEqual(try session.batchExport.itemsForExport(from:session).map(\.id),[c.id],"Changing scope is read immediately without waiting for a SwiftUI render")
        session.restoreWindows();let model=try XCTUnwrap(session.windows[a.id]?.model)
        model.document.append(.init(tool:.rectangle,points:[.zero,CGPoint(x:20,y:20)]));try model.applyColorAction(.grayscale)
        let plan=try session.batchImageItems(group:first),snapshot=try XCTUnwrap(plan.first{$0.id==a.id})
        guard case .document(let captured)=snapshot.source else{return XCTFail("loaded model was not captured")}
        XCTAssertEqual(captured.annotations.count,1);XCTAssertTrue(captured.imageAdjustments.grayscale);XCTAssertFalse(captured.canUndo)
        let persisted=try session.store.document(for:a);XCTAssertTrue(persisted.annotations.isEmpty);XCTAssertTrue(persisted.imageAdjustments.isDefault)
    }
    func testAsyncExportBlocksQuitButNotCaptureAndProducesOneCompleteResult() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("batch-model-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let session=CapturePinSession(store:.init(root:root.appendingPathComponent("pins"))),workspace=CaptureWorkspace(pinSession:session),doc=try document()
        workspace.saving=CaptureSaveModel(read:{nil},write:{_ in})
        defer{workspace.shutdown();for window in NSApp.windows where window.title=="贴图分组与历史" || window.title=="Pin groups and history" {window.close()}}
        var annotated=doc;annotated.append(.init(tool:.text,points:[CGPoint(x:2,y:10)],color:NSColor(deviceRed:1,green:0,blue:0,alpha:1),text:"Batch QA"))
        let items=(0..<2).map{index in CaptureBatchImageItem(id:UUID(),groupID:session.library.currentGroupID,groupName:"Group",title:String(index),source:.document(annotated))}
        session.batchExport.start(items,destination:root,format:.png);session.batchExport.start([],destination:root,format:.png)
        XCTAssertEqual(session.batchExport.total,2);XCTAssertFalse(workspace.captureBusy);XCTAssertEqual(workspace.terminationReply(.terminateNow),.terminateCancel)
        try await wait(session.batchExport);let result=try XCTUnwrap(session.batchExport.result);XCTAssertNil(session.batchExport.issue);XCTAssertEqual(result.images.count,2);XCTAssertEqual(session.batchExport.completed,2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:result.folder.path).count,3)
        XCTAssertEqual(try Data(contentsOf:result.folder.appendingPathComponent(result.images[0].file)),try annotated.data())
    }
    func testImmediateCancellationReachesAnAtomicTerminalStateWithoutHiddenStagingFiles() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("batch-cancel-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let model=CaptureBatchImageExportModel(),doc=try document()
        let items=(0..<8).map{index in CaptureBatchImageItem(id:UUID(),groupID:UUID(),groupName:"QA",title:String(index),source:.document(doc))}
        model.start(items,destination:root,format:.png);model.cancel();try await wait(model)
        XCTAssertFalse(model.cancelling)
        let files=try FileManager.default.contentsOfDirectory(atPath:root.path)
        XCTAssertFalse(files.contains{$0.hasPrefix(".thermo-batch-")})
        if let result=model.result {XCTAssertEqual(result.images.count,8);XCTAssertEqual(files.count,1)}
        else {XCTAssertNotNil(model.issue);XCTAssertTrue(files.isEmpty)}
    }
}
