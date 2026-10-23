import AppKit
import AgentCore
import CaptureCore
import CaptureScriptCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureCLIHostTests:XCTestCase {
    private func worker() throws->URL {
        var folder=Bundle(for:Self.self).bundleURL
        for _ in 0..<8{let file=folder.appendingPathComponent("thermo-capture-script");if FileManager.default.isExecutableFile(atPath:file.path){return file};folder.deleteLastPathComponent()};throw CaptureScriptFailure.unavailable
    }
    private func report(_ response:AppControlResponse)throws->CaptureCLIReport{try JSONDecoder().decode(CaptureCLIReport.self,from:XCTUnwrap(response.values["capture"]?.data(using:.utf8)))}
    func testActualScriptCompletionStatusAndReplayRejection() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),workspace=CaptureWorkspace(pinSession:CapturePinSession(store:.init(root:root))),host=CaptureCLIHost(workspace:workspace)
        defer{workspace.shutdown();try? FileManager.default.removeItem(at:root)};workspace.scriptWorker=try worker()
        let request=AppControlRequest(action:"capture.run",arguments:["source":"console.log('cli');return thermo.perform('status');"])
        let response=await host.handle(request);XCTAssertTrue(response.succeeded);let value=try report(response);XCTAssertEqual(value.phase,.succeeded);XCTAssertEqual(value.id,request.id);XCTAssertEqual(value.result?.logs,["cli"])
        let queried=try report(await host.handle(.init(action:"capture.status",arguments:["id":request.id.uuidString])));XCTAssertEqual(queried.phase,.succeeded)
        let replay=await host.handle(request);XCTAssertFalse(replay.succeeded)
    }
    func testDryRunAndUnsupportedActionsDoNotStartWorkerOrChangePins() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),workspace=CaptureWorkspace(pinSession:CapturePinSession(store:.init(root:root))),host=CaptureCLIHost(workspace:workspace)
        defer{workspace.shutdown();try? FileManager.default.removeItem(at:root)}
        let preview=try report(await host.handle(.init(action:"capture.run",arguments:["source":"throw new Error('never')"],dryRun:true)));XCTAssertEqual(preview.phase,.validated)
        XCTAssertFalse(workspace.scriptRunning);XCTAssertEqual(workspace.pinSession.count,0)
        let catalog=try report(await host.handle(.init(action:"capture.actions")))
        if case .array(let values)?=catalog.result?.value {XCTAssertTrue(values.contains{if case .object(let item)=$0{return item["id"] == .string("status")};return false})} else{XCTFail("missing action catalog")}
        let unsupported=await host.handle(.init(action:"capture.action",arguments:["action":"recording"],dryRun:true));XCTAssertFalse(unsupported.succeeded)
        let bad=await host.handle(.init(action:"capture.run",arguments:["source":"return 1;","extra":"rejected"]));XCTAssertFalse(bad.succeeded)
    }
    func testPublishedHostRoutesCaptureAndRetainsItsReplayGuard() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),workspace=CaptureWorkspace(pinSession:CapturePinSession(store:.init(root:root))),capture=CaptureCLIHost(workspace:workspace),host=AppControlHost(capture:capture)
        defer{workspace.shutdown();try? FileManager.default.removeItem(at:root)}
        let request=AppControlRequest(action:"capture.run",arguments:["source":"return 1;"],dryRun:true)
        let first=await host.handle(request);XCTAssertEqual(try report(first).phase,.validated)
        let duplicate=await host.handle(request);XCTAssertFalse(duplicate.succeeded)
    }
    func testEvictedResultRemainsNonReplayable() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),workspace=CaptureWorkspace(pinSession:CapturePinSession(store:.init(root:root))),host=CaptureCLIHost(workspace:workspace)
        defer{workspace.shutdown();try? FileManager.default.removeItem(at:root)};workspace.scriptWorker=try worker()
        let first=AppControlRequest(action:"capture.run",arguments:["source":"return 1;"])
        let original=await host.handle(first);XCTAssertTrue(original.succeeded)
        for _ in 0..<32{let result=await host.handle(.init(action:"capture.run",arguments:["source":"return 1;"]));XCTAssertTrue(result.succeeded)}
        let old=try report(await host.handle(.init(action:"capture.status",arguments:["id":first.id.uuidString])));XCTAssertEqual(old.phase,.unknown)
        let replay=await host.handle(first);XCTAssertFalse(replay.succeeded)
    }
    func testCancellationRunsWhileOriginalRequestWaitsAndDoesNotReplay() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),workspace=CaptureWorkspace(pinSession:CapturePinSession(store:.init(root:root))),host=CaptureCLIHost(workspace:workspace)
        defer{workspace.shutdown();try? FileManager.default.removeItem(at:root)};workspace.scriptWorker=try worker()
        let request=AppControlRequest(action:"capture.run",arguments:["source":"while(true){}"])
        let task=Task{await host.handle(request)}
        while !workspace.scriptRunning{await Task.yield()}
        let status=try report(await host.handle(.init(action:"capture.status",arguments:["id":request.id.uuidString])));XCTAssertEqual(status.phase,.running)
        let second=await host.handle(.init(action:"capture.run",arguments:["source":"return 2;"]));XCTAssertFalse(second.succeeded)
        _=await host.handle(.init(action:"capture.cancel",arguments:["id":request.id.uuidString]))
        let ended=try report(await task.value);XCTAssertEqual(ended.phase,.cancelled);XCTAssertFalse(workspace.scriptRunning)
        let unknown=try report(await host.handle(.init(action:"capture.status",arguments:["id":UUID().uuidString])));XCTAssertEqual(unknown.phase,.unknown)
    }
}
