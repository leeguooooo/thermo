import CaptureControlAPI
import CaptureControlAdapter
import AppKit
import AgentCore
import CaptureFeature
import CaptureScriptCore
import ModuleKit
import NativeFeatureAPI
import XCTest
@testable import ThermoApp

@MainActor final class CaptureHostRoutingTests:XCTestCase {
    func testManifestUsesPrewarmAndHasRegisteredMenuAndSettings() {
        XCTAssertEqual(BuiltinModuleManifests.capture.launch, .prewarm)
        XCTAssertTrue(BuiltinModuleManifests.capture.enabledByDefault)
        XCTAssertTrue(BuiltinModuleManifests.capture.problems().isEmpty)

        XCTAssertEqual(BuiltinModuleManifests.capture.entries.filter { $0.kind == .settingsItem }.count, 2)
        XCTAssertTrue(NativeModules.problems.isEmpty)
    }
    func testModuleCenterStartsOnlyEnabledBuiltinsAndStartsOnReenable() {
        let name = "thermo-capture-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: ModuleCenter.key(BuiltinModuleManifests.capture.id))
        var starts: [String] = []
        let center = ModuleCenter(defaults: defaults, prepareBuiltinStop: { _ in nil }, startBuiltin: { starts.append($0) })
        center.start(); center.start()
        XCTAssertFalse(starts.contains(BuiltinModuleManifests.capture.id))
        center.setEnabled(BuiltinModuleManifests.capture.id, true)
        XCTAssertEqual(starts.filter { $0 == BuiltinModuleManifests.capture.id }.count, 1)
        center.setEnabled(BuiltinModuleManifests.capture.id, false)
        XCTAssertFalse(center.isOn(BuiltinModuleManifests.capture.id))
    }
    func testOffscreenStartupDoesNotWarmNativeFeatures() {
        let name = "thermo-capture-offscreen-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var starts: [String] = []
        let center = ModuleCenter(defaults: defaults, startBuiltin: { starts.append($0) })
        center.start(prewarmBuiltins: false)
        XCTAssertTrue(starts.isEmpty)
        XCTAssertTrue(center.isOn(BuiltinModuleManifests.capture.id))
    }
    private final class Control:CaptureApplicationControl {
        var calls:[CaptureControlRequest]=[]
        var result=CaptureControlResult(report:.init(phase:.failed,issue:"previous operation failed"),succeeded:true)
        func handle(_ request:CaptureControlRequest) async->CaptureControlResult{calls.append(request);return result}
        func cancelActive(){}
    }
    func testSignedHostPrefixUsesInjectedHandlerAndKeepsProcessReplayGuard() async throws {
        var calls=0
        let host=AppControlHost(capture:{request in
            calls+=1;let report=CaptureCLIReport(id:request.id,phase:.validated)
            return .init(request:request,succeeded:true,values:["capture":String(decoding:try! JSONEncoder().encode(report),as:UTF8.self)])
        })
        let request=AppControlRequest(action:"capture.run",arguments:["source":"return 1;"],dryRun:true)
        let first=await host.handle(request);XCTAssertTrue(first.succeeded)
        let duplicate=await host.handle(request);XCTAssertFalse(duplicate.succeeded);XCTAssertEqual(calls,1)
    }
    func testEnvelopeValidationAndQueriedFailureKeepWireSemantics() async throws {
        let control=Control()
        let malformed=await CaptureControlEnvelope.handle(.init(action:"capture.run",arguments:["source":"return 1;","extra":"rejected"]),control:control)
        XCTAssertFalse(malformed.succeeded);XCTAssertTrue(control.calls.isEmpty)
        let invalidID=await CaptureControlEnvelope.handle(.init(action:"capture.status",arguments:["id":"invalid"]),control:control)
        XCTAssertFalse(invalidID.succeeded);XCTAssertTrue(control.calls.isEmpty)
        let id=UUID(),response=await CaptureControlEnvelope.handle(.init(action:"capture.status",arguments:["id":id.uuidString]),control:control)
        XCTAssertTrue(response.succeeded);XCTAssertNil(response.issue)
        let report=try JSONDecoder().decode(CaptureCLIReport.self,from:XCTUnwrap(response.values["capture"]?.data(using:.utf8)))
        XCTAssertEqual(report.phase,.failed);XCTAssertEqual(report.issue,"previous operation failed")
        if case let .status(received)?=control.calls.last?.operation{XCTAssertEqual(received,id)}else{XCTFail("typed status request")}
    }

}
