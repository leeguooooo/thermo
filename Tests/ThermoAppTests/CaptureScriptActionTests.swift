import AppKit
import CaptureCore
import CaptureScriptCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureScriptActionTests:XCTestCase {
    private func worker() throws -> URL {
        var folder=Bundle(for:Self.self).bundleURL
        for _ in 0..<8 {let candidate=folder.appendingPathComponent("thermo-capture-script");if FileManager.default.isExecutableFile(atPath:candidate.path){return candidate};folder.deleteLastPathComponent()};throw CaptureScriptFailure.unavailable
    }
    func testScriptMutatesRealPinModelsAndPersistsResults() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),session=CapturePinSession(store:.init(root:root)),workspace=CaptureWorkspace(pinSession:session),board=NSPasteboard.withUniqueName()
        defer{workspace.shutdown();session.closeAll();board.releaseGlobally();try? FileManager.default.removeItem(at:root)}
        workspace.scriptWorker=try worker();workspace.scriptPasteboard=board;board.setString("QA script text",forType:.string)
        let result=try await workspace.executeScript("thermo.perform('pinText');for(let i=0;i<3;i++)thermo.perform('toggleLock');thermo.perform('hidePins');if(thermo.perform('status').pins===1)thermo.perform('showPins');return thermo.perform('status');")
        guard case .object(let status)=result.value else{return XCTFail("missing status")};XCTAssertEqual(status["pins"],.number(1))
        let pin=try XCTUnwrap(session.library.pins.last);XCTAssertTrue(pin.locked);XCTAssertFalse(pin.hidden)
        let saved=try session.store.load(defaultName:"Default");XCTAssertEqual(saved.pins.last?.locked,true)
        if case .text(let text)?=session.activeEditor()?.model.pinContent {XCTAssertEqual(text.plain,"QA script text")} else {XCTFail("expected text pin")}
        let caught=try await workspace.executeScript("try{thermo.perform('rotate')}catch(e){return e.message};")
        guard case .string(let error)=caught.value else{return XCTFail("missing action error")};XCTAssertFalse(error.isEmpty)
    }
    func testScriptImageTransformsQuickSaveAndPrivateClipboard() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let session=CapturePinSession(store:.init(root:root.appendingPathComponent("pins"))),workspace=CaptureWorkspace(pinSession:session),board=NSPasteboard.withUniqueName()
        defer{workspace.shutdown();session.closeAll();board.releaseGlobally();try? FileManager.default.removeItem(at:root)}
        workspace.scriptWorker=try worker();workspace.scriptPasteboard=board;workspace.saving=CaptureSaveModel(read:{nil},write:{_ in})
        var options=CaptureSaveSettings();options.quick.directory=root.path;options.quick.template="script-image";XCTAssertTrue(workspace.saving.apply(options))
        let image=CGContext(data:nil,width:12,height:10,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        board.setData(try CaptureDocument(image:image).data(),forType:.png)
        _=try await workspace.executeScript("thermo.perform('pinClipboard');thermo.perform('rotate');thermo.perform('flip');thermo.perform('quickSaveImage');thermo.perform('copyImage');return thermo.perform('status');")
        let file=root.appendingPathComponent("script-image.png"),rep=try XCTUnwrap(NSBitmapImageRep(data:Data(contentsOf:file)))
        XCTAssertEqual(rep.pixelsWide,10);XCTAssertEqual(rep.pixelsHigh,12);XCTAssertEqual(NSBitmapImageRep(data:try XCTUnwrap(board.data(forType:.png)))?.pixelsHigh,12)
    }
    func testScriptShortcutDispatchesSourceAndCanBeCancelled() async throws {
        let backend=CaptureShortcutModelTests.Backend(),model=CaptureShortcutModel(backend:backend,read:{nil},write:{_ in},pinFocused:{false},execute:{_ in XCTFail("script must not dispatch enum without source")})
        defer{model.shutdown()}
        var received:[String]=[]
        model.executeScript={source in received.append(source);return .init(value:.number(7),logs:["ran"])}
        let entry=CaptureShortcutEntry(action:.script,script:"return 7;");model.run(entry)
        while model.scriptRunning{await Task.yield()};XCTAssertEqual(received,["return 7;"]);XCTAssertTrue(model.scriptOutput.contains("ran"));XCTAssertTrue(model.scriptOutput.contains("7"))
        model.executeScript={_ in try await Task.sleep(nanoseconds:10_000_000_000);return .init(value:.null,logs:[])}
        model.run(entry);XCTAssertTrue(model.scriptRunning);model.cancelScript()
        while model.scriptRunning{await Task.yield()};XCTAssertNotNil(model.issue)
    }
    func testBusyAndAlreadyCancelledScreenshotRequestsDoNotOpenCaptureUI() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),workspace=CaptureWorkspace(pinSession:CapturePinSession(store:.init(root:root)))
        defer{workspace.shutdown();try? FileManager.default.removeItem(at:root)}
        workspace.capturing=true
        do{_=try await workspace.captureAndWait();XCTFail("busy capture")}catch{XCTAssertTrue(error is CaptureSaveFailure)}
        workspace.capturing=false
        let task=Task {withUnsafeCurrentTask{$0?.cancel()};return try await workspace.captureAndWait()}
        do{_=try await task.value;XCTFail("cancelled capture")}catch{XCTAssertTrue(error is CancellationError)}
        XCTAssertFalse(workspace.capturing)
    }
    func testUnsupportedAndRecursiveActionsFailBeforeLaunchingOtherFlows() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),workspace=CaptureWorkspace(pinSession:CapturePinSession(store:.init(root:root)));workspace.scriptWorker=try worker()
        defer{workspace.shutdown();try? FileManager.default.removeItem(at:root)}
        for action in ["script","recording","scrolling","saveImage","unknown"] {
            do{_=try await workspace.executeScript("thermo.perform('"+action+"');");XCTFail("unsupported action")}catch{XCTAssertTrue(error is CaptureScriptFailure)}
        }
    }
}
