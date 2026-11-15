import AppKit
import CaptureCore
import CaptureScriptCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureScriptLifetimeTests:XCTestCase {
    private actor PhysicalAction {
        var released=false
        var continuation:CheckedContinuation<Void,Never>?
        func wait() async{if released{return};await withCheckedContinuation{continuation=$0}}
        func finish(){released=true;continuation?.resume();continuation=nil}
    }
    private func worker()throws->URL {
        var folder=Bundle(for:Self.self).bundleURL
        for _ in 0..<8{let file=folder.appendingPathComponent("thermo-capture-script");if FileManager.default.isExecutableFile(atPath:file.path){return file};folder.deleteLastPathComponent()}
        throw CaptureScriptFailure.unavailable
    }
    func testPromptTimeoutDoesNotPermitRetirementBeforeNativeActionReturns() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-script-lifetime-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let entered=expectation(description:"physical native action entered"),returned=expectation(description:"prompt logical timeout"),finished=expectation(description:"physical action returned")
        let action=PhysicalAction(),keys=CaptureModuleTests.Backend()
        let shortcuts=CaptureShortcutModel(backend:keys,read:{nil},write:{_ in},pinFocused:{false},execute:{_ in})
        let workspace=CaptureWorkspace(pinSession:.init(store:.init(root:root)),screenCaptureAccess:{XCTFail("no screen permission");return false},shortcuts:shortcuts,nativeScriptAction:{_ in
            entered.fulfill();await action.wait();finished.fulfill();return .null
        })
        workspace.saving=CaptureSaveModel(read:{nil},write:{_ in});workspace.scriptWorker=try worker()
        defer{workspace.shutdown()}
        let logical=Task{do{_ = try await workspace.executeScript("return thermo.perform('status');",timeout:0.1);XCTFail("expected timeout")}catch{XCTAssertEqual(error as? CaptureScriptFailure,.timedOut)};returned.fulfill()}
        await fulfillment(of:[entered],timeout:3)
        await fulfillment(of:[returned],timeout:2)
        XCTAssertFalse(workspace.scriptRunning)
        XCTAssertThrowsError(try workspace.stopFeature(),"a prompt report is not physical completion")
        await action.finish();await fulfillment(of:[finished],timeout:2);await logical.value
        XCTAssertNoThrow(try workspace.stopFeature());XCTAssertTrue(keys.leases.isEmpty)
    }
}
