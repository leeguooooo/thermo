import AppKit
import CaptureCore
import CaptureScriptCore
import XCTest
@testable import CaptureFeature

@MainActor final class CaptureCLIHostTests:XCTestCase {
    private func worker()throws->URL {
        var folder=Bundle(for:Self.self).bundleURL
        for _ in 0..<8{let file=folder.appendingPathComponent("thermo-capture-script");if FileManager.default.isExecutableFile(atPath:file.path){return file};folder.deleteLastPathComponent()};throw CaptureScriptFailure.unavailable
    }
    private func access(_ workspace:CaptureWorkspace)->CaptureExecutionAccess{.init(canUse:{workspace.enabled},workspace:{workspace})}
    func testActualScriptCompletionStatusAndReplayRejection() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),workspace=CaptureWorkspace(pinSession:.init(store:.init(root:root))),host=CaptureCLIHost()
        defer{workspace.shutdown();try? FileManager.default.removeItem(at:root)};workspace.scriptWorker=try worker()
        let request=CaptureControlRequest(id:UUID(),operation:.run("console.log('cli');return thermo.perform('status');"))
        let response=await host.handle(request,access:access(workspace));XCTAssertTrue(response.succeeded)
        XCTAssertEqual(response.report.phase,.succeeded);XCTAssertEqual(response.report.id,request.id);XCTAssertEqual(response.report.result?.logs,["cli"])
        let queried=await host.handle(.init(id:UUID(),operation:.status(request.id)),access:access(workspace));XCTAssertTrue(queried.succeeded);XCTAssertEqual(queried.report.phase,.succeeded)
        let replay=await host.handle(request,access:access(workspace));XCTAssertFalse(replay.succeeded)
    }
    func testColdCatalogDryRunAndOffOperationsNeverBorrowWorkspace() async {
        let host=CaptureCLIHost();var borrowed=0
        let access=CaptureExecutionAccess(canUse:{true},workspace:{borrowed+=1;return nil})
        let preview=await host.handle(.init(id:UUID(),operation:.run("throw new Error('never')"),dryRun:true),access:access)
        XCTAssertEqual(preview.report.phase,.validated)
        let catalog=await host.handle(.init(id:UUID(),operation:.actions),access:access)
        if case .array(let values)?=catalog.report.result?.value{XCTAssertTrue(values.contains{if case .object(let item)=$0{return item["id"] == .string("status")};return false})}else{XCTFail("missing catalog")}
        let unsupported=await host.handle(.init(id:UUID(),operation:.action("recording"),dryRun:true),access:access);XCTAssertFalse(unsupported.succeeded)
        let off=await host.handle(.init(id:UUID(),operation:.run("return 1;")),access:.init(canUse:{false},workspace:{borrowed+=1;return nil}))
        XCTAssertFalse(off.succeeded);XCTAssertEqual(borrowed,0)
    }
    func testEvictedResultRemainsNonReplayable() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),workspace=CaptureWorkspace(pinSession:.init(store:.init(root:root))),host=CaptureCLIHost()
        defer{workspace.shutdown();try? FileManager.default.removeItem(at:root)};workspace.scriptWorker=try worker()
        let first=CaptureControlRequest(id:UUID(),operation:.run("return 1;"))
        let original=await host.handle(first,access:access(workspace));XCTAssertTrue(original.succeeded)
        for _ in 0..<32{let result=await host.handle(.init(id:UUID(),operation:.run("return 1;")),access:access(workspace));XCTAssertTrue(result.succeeded)}
        let old=await host.handle(.init(id:UUID(),operation:.status(first.id)),access:access(workspace));XCTAssertEqual(old.report.phase,.unknown);XCTAssertFalse(old.succeeded)
        let replay=await host.handle(first,access:access(workspace));XCTAssertFalse(replay.succeeded)
    }
    func testQueryOfFailedReportIsSuccessfulAndDoesNotRerunIt() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),workspace=CaptureWorkspace(pinSession:.init(store:.init(root:root))),host=CaptureCLIHost()
        defer{workspace.shutdown();try? FileManager.default.removeItem(at:root)};workspace.scriptWorker=try worker()
        let request=CaptureControlRequest(id:UUID(),operation:.run("throw new Error('owned failure');"))
        let failed=await host.handle(request,access:access(workspace));XCTAssertFalse(failed.succeeded);XCTAssertEqual(failed.report.phase,.failed)
        let queried=await host.handle(.init(id:UUID(),operation:.status(request.id)),access:access(workspace));XCTAssertTrue(queried.succeeded);XCTAssertEqual(queried.report.phase,.failed)
        let cancelled=await host.handle(.init(id:UUID(),operation:.cancel(request.id)),access:access(workspace));XCTAssertTrue(cancelled.succeeded);XCTAssertEqual(cancelled.report.phase,.failed)
    }
    func testCancellationRunsWhileOriginalRequestWaitsAndDoesNotReplay() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),workspace=CaptureWorkspace(pinSession:.init(store:.init(root:root))),host=CaptureCLIHost()
        defer{workspace.shutdown();try? FileManager.default.removeItem(at:root)};workspace.scriptWorker=try worker()
        let request=CaptureControlRequest(id:UUID(),operation:.run("while(true){}")),access=access(workspace)
        let task=Task{await host.handle(request,access:access)}
        for _ in 0..<400 where !workspace.scriptRunning{try await Task.sleep(nanoseconds:5_000_000)}
        XCTAssertTrue(workspace.scriptRunning)
        let status=await host.handle(.init(id:UUID(),operation:.status(request.id)),access:access);XCTAssertEqual(status.report.phase,.running)
        let second=await host.handle(.init(id:UUID(),operation:.run("return 2;")),access:access);XCTAssertFalse(second.succeeded)
        _=await host.handle(.init(id:UUID(),operation:.cancel(request.id)),access:access)
        let ended=await task.value;XCTAssertEqual(ended.report.phase,.cancelled);XCTAssertFalse(workspace.scriptRunning)
        let unknown=await host.handle(.init(id:UUID(),operation:.status(UUID())),access:access);XCTAssertEqual(unknown.report.phase,.unknown)
    }
}
