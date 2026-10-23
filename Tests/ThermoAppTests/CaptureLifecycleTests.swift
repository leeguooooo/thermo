import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureLifecycleTests:XCTestCase {
    private func root() throws -> URL {
        _=NSApplication.shared
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    private func image() throws -> CGImage {
        let ctx=try XCTUnwrap(CGContext(data:nil,width:24,height:18,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(ctx.makeImage())
    }
    private func process(_ executable:String,_ arguments:[String]=[]) -> Process {
        let value=Process();value.executableURL=URL(fileURLWithPath:executable);value.arguments=arguments
        value.standardOutput=FileHandle.nullDevice;value.standardError=FileHandle.nullDevice;return value
    }
    private func wait(until predicate:()->Bool) async throws {
        for _ in 0..<400 {if predicate(){return};try await Task.sleep(nanoseconds:5_000_000)}
        XCTFail("Lifecycle did not finish within two seconds");throw CaptureFailure.captureFailed
    }
    func testPermissionDenialDoesNotLaunchProcessOrChangePins() async throws {
        let root=try root();var checks=0,launches=0
        let workspace=CaptureWorkspace(pinSession:.init(store:.init(root:root)),screenCaptureAccess:{checks+=1;return false},makeCaptureProcess:{_ in launches+=1;return self.process("/usr/bin/true")})
        workspace.saving=CaptureSaveModel(read:{nil},write:{_ in})
        defer {workspace.shutdown();try? FileManager.default.removeItem(at:root)}
        do {_=try await workspace.captureAndWait();XCTFail("Permission denied")} catch {XCTAssertTrue(error is CaptureFailure)}
        XCTAssertEqual(checks,1);XCTAssertEqual(launches,0);XCTAssertFalse(workspace.captureBusy);XCTAssertEqual(workspace.pinSession.count,0)
    }
    func testCancelledSelectorKeepsItsSlotUntilActualProcessExit() async throws {
        let root=try root(),ready=root.appendingPathComponent("ready"),release=root.appendingPathComponent("release")
        var launched:Process?,output:URL?,checks=0,launches=0
        let workspace=CaptureWorkspace(pinSession:.init(store:.init(root:root.appendingPathComponent("pins"))),screenCaptureAccess:{checks+=1;return true},makeCaptureProcess:{url in
            launches+=1;output=url
            let script="import signal,time,pathlib,sys;signal.signal(signal.SIGTERM,lambda *args:None);pathlib.Path(sys.argv[1]).touch();end=time.monotonic()+4\nwhile not pathlib.Path(sys.argv[2]).exists() and time.monotonic()<end: time.sleep(.01)"
            let task=self.process("/usr/bin/python3",["-c",script,ready.path,release.path]);launched=task;return task
        })
        workspace.saving=CaptureSaveModel(read:{nil},write:{_ in})
        defer {try? Data().write(to:release);workspace.shutdown();try? FileManager.default.removeItem(at:root)}
        let task=Task {try await workspace.captureAndWait()}
        try await wait{FileManager.default.fileExists(atPath:ready.path)}
        XCTAssertTrue(workspace.captureBusy);task.cancel()
        do {_=try await task.value;XCTFail("Cancelled request")} catch { }
        XCTAssertFalse(workspace.capturing);XCTAssertTrue(launched?.isRunning == true);XCTAssertTrue(workspace.captureBusy)
        do {_=try await workspace.captureAndWait();XCTFail("Old selector still running")} catch {XCTAssertTrue(error is CaptureSaveFailure)}
        XCTAssertEqual(checks,1);XCTAssertEqual(launches,1)
        try Data().write(to:release);try await wait{!workspace.captureBusy}
        XCTAssertFalse(launched?.isRunning == true);XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(output).deletingLastPathComponent().path));XCTAssertEqual(workspace.pinSession.count,0)
    }
    func testEmptyCaptureCannotReusePreviousPixelsAndNextCaptureGetsNewPrivateDirectory() async throws {
        let root=try root(),source=root.appendingPathComponent("source.png")
        try CaptureDocument(image:image()).data().write(to:source)
        var outputs:[URL]=[],empty=true
        let workspace=CaptureWorkspace(pinSession:.init(store:.init(root:root.appendingPathComponent("pins"))),screenCaptureAccess:{true},makeCaptureProcess:{url in
            outputs.append(url);return empty ? self.process("/usr/bin/true") : self.process("/bin/cp",[source.path,url.path])
        })
        workspace.saving=CaptureSaveModel(read:{nil},write:{_ in})
        defer {workspace.shutdown();workspace.pinSession.closeAll();try? FileManager.default.removeItem(at:root)}
        let cancelled=try await workspace.captureAndWait();XCTAssertFalse(cancelled);XCTAssertEqual(workspace.pinSession.count,0)
        empty=false;let success=try await workspace.captureAndWait();XCTAssertTrue(success);XCTAssertEqual(workspace.pinSession.count,1)
        XCTAssertEqual(workspace.pinSession.activeEditor()?.model.document.image.width,24)
        XCTAssertEqual(Set(outputs.map(\.path)).count,2)
        for url in outputs {XCTAssertFalse(FileManager.default.fileExists(atPath:url.deletingLastPathComponent().path))}
        XCTAssertFalse(workspace.captureBusy)
    }
    func testLaunchFailureCleansPrivateDirectoryAndReleasesSlot() async throws {
        let root=try root();var output:URL?
        let workspace=CaptureWorkspace(pinSession:.init(store:.init(root:root)),screenCaptureAccess:{true},makeCaptureProcess:{url in output=url;return self.process(root.appendingPathComponent("missing").path)})
        workspace.saving=CaptureSaveModel(read:{nil},write:{_ in})
        defer {workspace.shutdown();try? FileManager.default.removeItem(at:root)}
        do {_=try await workspace.captureAndWait();XCTFail("Missing executable")} catch { }
        XCTAssertFalse(workspace.captureBusy);XCTAssertEqual(workspace.pinSession.count,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(output).deletingLastPathComponent().path))
    }
    func testOutstandingCancelledAfterActionPreventsAnotherSelector() async throws {
        let root=try root();var checks=0
        let workspace=CaptureWorkspace(pinSession:.init(store:.init(root:root)),screenCaptureAccess:{checks+=1;return true},makeCaptureProcess:{_ in XCTFail("Pending save chain must block selector");return self.process("/usr/bin/true")})
        workspace.saving=CaptureSaveModel(read:{nil},write:{_ in})
        defer {workspace.shutdown();try? FileManager.default.removeItem(at:root)}
        var continuation:CheckedContinuation<String,Never>?
        var options=CaptureSaveSettings();options.after=[.copyText]
        let pixels=try image()
        let chain=Task {await workspace.saving.run(pixels,settings:options,pin:{_ in XCTFail("Cancelled chain")},copyImage:{_ in},copyText:{_ in XCTFail("Cancelled clipboard")},recognize:{_ in await withCheckedContinuation{continuation=$0}})}
        try await wait{continuation != nil};chain.cancel()
        do {_=try await workspace.captureAndWait();XCTFail("After-action still finishing")} catch {XCTAssertTrue(error is CaptureSaveFailure)}
        let response=await CaptureCLIHost(workspace:workspace).handle(.init(action:"capture.action",arguments:["action":"pinClipboard"]))
        XCTAssertFalse(response.succeeded);XCTAssertFalse(workspace.scriptRunning)
        if case .object(let status)=try await workspace.performScriptAction("status") {XCTAssertEqual(status["capturing"],.bool(true))} else {XCTFail("Missing busy status")}
        XCTAssertEqual(checks,0);continuation?.resume(returning:"late")
        let result=await chain.value;XCTAssertFalse(result);XCTAssertFalse(workspace.captureBusy)
    }
}
