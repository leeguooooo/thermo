import CaptureControlAPI
import AppKit
import CaptureCore
import CaptureScriptCore
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n
import XCTest
@testable import CaptureFeature

@MainActor final class CaptureRegistrationTests:XCTestCase {
    private let id=BuiltinModuleManifests.capture.id
    private func workspace(_ root:URL,_ available:@escaping ()->Bool)->CaptureWorkspace {
        let keys=CaptureModuleTests.Backend(),shortcuts=CaptureShortcutModel(backend:keys,read:{nil},write:{_ in},pinFocused:{false},execute:{_ in})
        let value=CaptureWorkspace(pinSession:.init(store:.init(root:root)),screenCaptureAccess:{XCTFail("no permissions");return false},featureEnabled:available,shortcuts:shortcuts)
        let saving=CaptureSaveModel(read:{nil},write:{_ in});saving.featureEnabled=available;value.saving=saving;return value
    }
    private func worker()throws->URL {
        var folder=Bundle(for:Self.self).bundleURL
        for _ in 0..<8{let file=folder.appendingPathComponent("thermo-capture-script");if FileManager.default.isExecutableFile(atPath:file.path){return file};folder.deleteLastPathComponent()};throw CaptureScriptFailure.unavailable
    }
    func testColdStatusExitSettingsAndControlValidationNeverLoadPinLibrary() async throws {
        var made=0,on=false
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-capture-cold-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let registration=CaptureFeature.makeRegistration(makeWorkspace:{availability in made+=1;return self.workspace(root,{availability.acceptsWork})})
        let store=NativeFeatureStore(definitions:[registration.definition],enabled:{_ in on}),control=registration.makeControl(store)
        XCTAssertFalse(store.status(id).modelLoaded);if case .allow=store.prepareTermination(){}else{XCTFail("cold exit")}
        XCTAssertNil(store.inlineSettings(.init(id,"saving")));XCTAssertNil(store.menuContent(.init(id,"tools")))
        let catalog=await control.handle(.init(id:UUID(),operation:.actions));XCTAssertTrue(catalog.succeeded)
        let status=await control.handle(.init(id:UUID(),operation:.status(nil)));XCTAssertEqual(status.report.phase,.idle)
        let off=await control.handle(.init(id:UUID(),operation:.run("return 1;"),dryRun:true));XCTAssertFalse(off.succeeded)
        XCTAssertEqual(made,0)
        on=true
        XCTAssertNotNil(store.inlineSettings(.init(id,"saving")))
        if case .allow=store.prepareTermination(){}else{XCTFail("inert session exit")}
        let validated=await control.handle(.init(id:UUID(),operation:.run("return 1;"),dryRun:true));XCTAssertEqual(validated.report.phase,.validated)
        XCTAssertEqual(made,0);XCTAssertFalse(store.status(id).modelLoaded);XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
    }
    func testLedgerSurvivesRetirementAndOldMenuDoesNotRetainWorkspace() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-capture-ledger-"+UUID().uuidString),worker=try worker()
        defer{try? FileManager.default.removeItem(at:root)}
        var made=0,on=true;weak var old:CaptureWorkspace?
        let registration=CaptureFeature.makeRegistration(makeWorkspace:{availability in
            made+=1;let value=self.workspace(root,{availability.acceptsWork});value.scriptWorker=worker;if made==1{old=value};return value
        })
        let store=NativeFeatureStore(definitions:[registration.definition],enabled:{_ in on}),control=registration.makeControl(store)
        let request=CaptureControlRequest(id:UUID(),operation:.run("return 7;"))
        let first=await control.handle(request);XCTAssertTrue(first.succeeded);XCTAssertEqual(made,1)
        let menu=try XCTUnwrap(store.menuContent(.init(id,"tools"))),stale=menu.items(.application)
        XCTAssertFalse(stale.isEmpty)
        var drain=try store.prepareStop(id);on=false;await drain?.finish();drain=nil
        for _ in 0..<4{await Task.yield()}
        XCTAssertNil(old,"the app's long-lived menu must not keep an off workspace alive")
        XCTAssertTrue(menu.items(.application).isEmpty)
        let queried=await control.handle(.init(id:UUID(),operation:.status(request.id)));XCTAssertTrue(queried.succeeded);XCTAssertEqual(queried.report.result?.value,.number(7));XCTAssertEqual(made,1)
        on=true
        let next=await control.handle(.init(id:UUID(),operation:.run("return 8;")));XCTAssertTrue(next.succeeded);XCTAssertEqual(made,2)
        let replay=await control.handle(request);XCTAssertFalse(replay.succeeded);XCTAssertTrue(replay.report.issue?.contains("already received") == true)
        store.shutdown()
    }
    func testPlacementAndFrozenConfiguredActionKeepOnePrivateDefinition() async throws {
        _=NSApplication.shared
        let previous=L10n.override;L10n.override = .english;defer{L10n.override=previous}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-capture-menu-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let workspace=workspace(root,{true});defer{workspace.shutdown()}
        let original=CaptureShortcutEntry(title:"Original",action:.script,script:"return 1;")
        XCTAssertTrue(workspace.shortcuts.apply(.init(entries:[original])))
        let nodes=CaptureMenuPresentation.nodes(workspace:workspace,placement:.status,available:{true})
        let groups=nodes.compactMap{if case let .submenu(title,_,_)=$0{return title};return nil}
        XCTAssertEqual(groups,["Capture & record","Clipboard & pins"])
        let application=actions(CaptureMenuPresentation.nodes(workspace:workspace,placement:.application,available:{true}))
        XCTAssertEqual(application.map(\.title),["Capture screen…","Pin clipboard","Open image…","Scrolling capture…","Record screen…","Recording drafts…"])
        let frozen=try XCTUnwrap(actions(nodes).first{$0.title=="Original"})
        let replacement=CaptureShortcutEntry(id:original.id,title:"Changed",action:.script,script:"return 2;")
        XCTAssertTrue(workspace.shortcuts.apply(.init(entries:[replacement])))
        let performed=expectation(description:"frozen script action");var received:[String]=[]
        workspace.shortcuts.executeScript={source in received.append(source);performed.fulfill();return .init(value:.null,logs:[])}
        frozen.perform();await fulfillment(of:[performed],timeout:2)
        XCTAssertEqual(received,["return 1;"])
    }
    private func actions(_ nodes:[NativeMenuNode])->[NativeMenuAction] {
        nodes.flatMap{node in switch node{case let .action(action):return [action];case let .submenu(_,_,children):return actions(children);case .separator:return []}}
    }
    func testPendingTerminationRetainsSessionAndRefusesDisableUntilItsActualResult() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-capture-exit-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let availability=FeatureAvailability{true},hub=CaptureControlHub()
        let entered=expectation(description:"finalization entered");var continuation:CheckedContinuation<Bool,Never>?,starts=0
        let ticket=NativeTerminationTicket{starts+=1;entered.fulfill();return await withCheckedContinuation{continuation=$0}}
        let session=CaptureSession(availability:availability,hub:hub,makeWorkspace:{_ in self.workspace(root,{true})},makeTermination:{_ in .deferred(ticket)})
        _=session.workspace
        if case .deferred=session.prepareTermination(){}else{XCTFail("deferred")}
        let finish=Task{await ticket.finish()};await fulfillment(of:[entered],timeout:2)
        if case let .deferred(same)=session.prepareTermination(){XCTAssertTrue(same === ticket)}else{XCTFail("same operation")}
        XCTAssertThrowsError(try session.prepareStop());XCTAssertNotNil(session.storedWorkspace)
        continuation?.resume(returning:false);let result=await finish.value;XCTAssertFalse(result);XCTAssertEqual(starts,1)
        let drain=try session.prepareStop();await drain.finish();XCTAssertNil(session.storedWorkspace)
    }
}
