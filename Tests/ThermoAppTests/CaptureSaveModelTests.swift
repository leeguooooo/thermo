import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureSaveModelTests:XCTestCase {
    enum Failure:Error {case fixture}
    private func image() -> CGImage {CGContext(data:nil,width:12,height:10,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!}
    func testPersistenceFailureAndInvalidStoredDataRemainVisible() throws {
        var saved=try CaptureSaveSettings().data(),fail=false
        let model=CaptureSaveModel(read:{saved},write:{if fail{throw Failure.fixture};saved=$0})
        var next=model.settings;next.after=[.copyImage];fail=true;XCTAssertFalse(model.apply(next));XCTAssertEqual(model.settings.after,[.pin]);XCTAssertEqual(try CaptureSaveSettings.decode(saved).after,[.pin])
        fail=false;XCTAssertTrue(model.apply(next));XCTAssertEqual(try CaptureSaveSettings.decode(saved),next)
        let invalid=CaptureSaveModel(read:{Data("invalid".utf8)},write:{_ in});XCTAssertTrue(invalid.invalidStoredSettings);XCTAssertThrowsError(try invalid.snapshot());XCTAssertTrue(invalid.apply(.init()));XCTAssertNoThrow(try invalid.snapshot())
    }
    func testOrderedChainUsesSameImageAndPreservesBothSaves() async throws {
        let model=CaptureSaveModel(read:{nil},write:{_ in}),image=image();var events:[String]=[]
        var options=CaptureSaveSettings();options.after=[.copyImage,.copyText,.quickSave,.pin];options.autoSave=true;options.quick.directory="/tmp/quick";options.automatic.directory="/tmp/auto"
        let result=await model.run(image,settings:options,pin:{XCTAssertTrue($0 === image);events.append("pin")},copyImage:{XCTAssertEqual(NSBitmapImageRep(data:$0)?.pixelsWide,12);events.append("image")},copyText:{XCTAssertEqual($0,"recognized");events.append("text")},recognize:{_ in events.append("ocr");return "recognized"},save:{document,destination,_ in XCTAssertTrue(document.image === image);events.append(destination.directory);return URL(fileURLWithPath:destination.directory+"/saved.png")})
        XCTAssertTrue(result);XCTAssertEqual(events,["/tmp/auto","image","ocr","text","/tmp/quick","pin"]);XCTAssertEqual(model.completed,["automaticSave","copyImage","copyText","quickSave","pin"]);XCTAssertEqual(model.saved.count,2);XCTAssertFalse(model.running)
    }
    func testFailureStopsLaterActionsAndRecoversPinWithoutRepeatingCompletedWork() async {
        let model=CaptureSaveModel(read:{nil},write:{_ in});var events:[String]=[]
        var options=CaptureSaveSettings();options.after=[.copyImage,.copyText,.quickSave];options.quick.directory="/tmp"
        let result=await model.run(image(),settings:options,pin:{_ in events.append("recovered")},copyImage:{_ in events.append("image")},copyText:{_ in events.append("text")},recognize:{_ in ""},save:{_,_,_ in events.append("save");throw Failure.fixture})
        XCTAssertFalse(result);XCTAssertEqual(events,["image","recovered"]);XCTAssertEqual(model.completed,["copyImage"]);XCTAssertNotNil(model.issue)
        events=[];options.after=[.pin,.quickSave]
        _=await model.run(image(),settings:options,pin:{_ in events.append("pin")},copyImage:{_ in},copyText:{_ in},save:{_,_,_ in throw Failure.fixture})
        XCTAssertEqual(events,["pin"])
    }
    func testWorkspaceUsesActualSavingPrivateClipboardAndEditorQuickSave() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let session=CapturePinSession(store:.init(root:root.appendingPathComponent("pins"))),workspace=CaptureWorkspace(pinSession:session),board=NSPasteboard.withUniqueName()
        defer {workspace.shutdown();session.closeAll();board.releaseGlobally();try? FileManager.default.removeItem(at:root)}
        workspace.saving=CaptureSaveModel(read:{nil},write:{_ in})
        var options=CaptureSaveSettings();options.quick.directory=root.path;options.quick.template="image";options.after=[.copyImage,.quickSave,.pin];options.autoSave=true;options.automatic.directory=root.path;options.automatic.template="automatic"
        XCTAssertTrue(workspace.saving.apply(options))
        let success=await workspace.processCaptured(image(),options:options,pasteboard:board)
        XCTAssertTrue(success);XCTAssertNotNil(board.data(forType:.png));XCTAssertEqual(workspace.saving.saved.count,2);XCTAssertEqual(session.count,1)
        let editor=try XCTUnwrap(session.activeEditor());editor.model.document.append(.init(tool:.redact,points:[.zero,CGPoint(x:12,y:10)]))
        try workspace.perform(.quickSaveImage)
        let path=try XCTUnwrap(editor.model.savedImagePath);XCTAssertTrue(path.hasSuffix("image-2.png"))
        let rep=try XCTUnwrap(NSBitmapImageRep(data:Data(contentsOf:URL(fileURLWithPath:path))))
        XCTAssertLessThan(try XCTUnwrap(rep.colorAt(x:6,y:5)?.usingColorSpace(.deviceRGB)).redComponent,0.01)
    }
    func testActualOCRSaveChainLeavesClipboardTextAndTwoImageFiles() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let workspace=CaptureWorkspace(pinSession:CapturePinSession(store:.init(root:root.appendingPathComponent("pins")))),board=NSPasteboard.withUniqueName()
        defer {workspace.shutdown();board.releaseGlobally();try? FileManager.default.removeItem(at:root)}
        workspace.saving=CaptureSaveModel(read:{nil},write:{_ in})
        let context=CGContext(data:nil,width:800,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:800,height:200))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
        ("THERMO SAVE QA 12345" as NSString).draw(at:CGPoint(x:20,y:80),withAttributes:[.font:NSFont.systemFont(ofSize:48),.foregroundColor:NSColor.black]);NSGraphicsContext.restoreGraphicsState()
        var options=CaptureSaveSettings();options.autoSave=true;options.automatic.directory=root.path;options.automatic.template="automatic";options.quick.directory=root.path;options.quick.template="quick";options.after=[.copyText,.quickSave]
        let result=await workspace.processCaptured(context.makeImage()!,options:options,pasteboard:board)
        XCTAssertTrue(result);XCTAssertTrue(board.string(forType:.string)?.contains("12345") == true);XCTAssertEqual(workspace.pinSession.count,0)
        XCTAssertEqual(workspace.saving.saved.map(\.lastPathComponent),["automatic.png","quick.png"])
        for file in workspace.saving.saved {XCTAssertEqual(NSBitmapImageRep(data:try Data(contentsOf:file))?.pixelsWide,800)}
    }
    func testDefaultPinAndExplicitEmptyChainDoNotCreateFilesOrCopy() async {
        let model=CaptureSaveModel(read:{nil},write:{_ in});var pins=0,copies=0,saves=0
        var options=CaptureSaveSettings()
        for _ in 0..<2 {
            let success=await model.run(image(),settings:options,pin:{_ in pins += 1},copyImage:{_ in copies += 1},copyText:{_ in copies += 1},save:{_,_,_ in saves += 1;return URL(fileURLWithPath:"/tmp/unexpected")})
            XCTAssertTrue(success);options.after=[]
        }
        XCTAssertEqual(pins,1);XCTAssertEqual(copies,0);XCTAssertEqual(saves,0)
    }
    func testConcurrentChainRejectedAndCancellationDoesNotRecoverPin() async {
        let model=CaptureSaveModel(read:{nil},write:{_ in});var pins=0
        var options=CaptureSaveSettings();options.after=[.copyText]
        let task=Task {await model.run(image(),settings:options,pin:{_ in pins += 1},copyImage:{_ in},copyText:{_ in XCTFail("cancelled copy")},recognize:{_ in
            let accepted=await model.run(self.image(),settings:.init(),pin:{_ in XCTFail("concurrent pin")},copyImage:{_ in},copyText:{_ in})
            XCTAssertFalse(accepted);try await Task.sleep(nanoseconds:30_000_000_000);return "late"
        })}
        while !model.running {await Task.yield()};task.cancel();let result=await task.value;XCTAssertFalse(result);XCTAssertEqual(pins,0);XCTAssertFalse(model.running)
    }
}
