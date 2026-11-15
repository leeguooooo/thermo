import SwiftUI
import XCTest
import ModuleKit
import NativeFeatureAPI
@testable import AgentDoctor
@testable import AgentDiagnosticsFeature

@MainActor final class AgentDiagnosticsSessionTests:XCTestCase {
    private final class Count:@unchecked Sendable {
        private let lock=NSLock();private var count=0
        func hit(){lock.lock();count+=1;lock.unlock()}
        var value:Int{lock.lock();defer{lock.unlock()};return count}
    }
    private nonisolated static func report()->DoctorReport {.init(generated:Date(),inventory:Inventory(),findings:[],items:[],processes:[],sessions:0)}
    func testRenderedUIConstructsOnlyInertScannerAndKeepsMetadataCold()throws {
        let calls=Count();var made=0,sessions:[AgentDiagnosticsSession]=[]
        let original=AgentDiagnosticsFeature.registration
        let definition=NativeFeatureDefinition(manifest:original.manifest,ui:original.ui,makeSession:{gate in
            made+=1
            let session=AgentDiagnosticsSession(availability:gate,makeScanner:{AgentScanner(enabled:$0,performAction:{_,_ in calls.hit();return .init(ok:false,log:[],backups:[])},diagnose:{calls.hit();return Self.report()},inspectMCP:{_ in calls.hit();return .init(generated:Date(),name:"fixture",agent:"fixture",state:.ready)})})
            sessions.append(session);return session
        })
        let catalog=try NativeFeatureCatalog(definitions:[definition]),store=NativeFeatureStore(catalog:catalog,enabled:{_ in true},navigation:.unavailable)
        XCTAssertEqual(catalog.manifest(original.manifest.id)?.entries.count,original.manifest.entries.count)
        XCTAssertNil(store.quitBlocker());XCTAssertFalse(store.status(original.manifest.id).modelLoaded);XCTAssertEqual(made,0)
        let ui=store.windowUI(selection:AgentDiagnosticsFeature.route(nil),locations:[.agents])
        XCTAssertEqual(ui.sidebar.count,1);XCTAssertNotNil(ui.backdrop)
        _=store.windowUI(selection:nil,locations:[])
        XCTAssertEqual(made,1);XCTAssertEqual(calls.value,0)
        XCTAssertFalse(sessions[0].scanner.scanning);XCTAssertNil(sessions[0].scanner.report)
        XCTAssertEqual(sessions[0].scanner.work.count,0)
    }
    func testOffSurfacesStayColdAndReenableCreatesFreshScanner()async throws {
        var enabled=false,sessions:[AgentDiagnosticsSession]=[]
        let original=AgentDiagnosticsFeature.registration
        let definition=NativeFeatureDefinition(manifest:original.manifest,ui:original.ui,makeSession:{gate in
            let session=AgentDiagnosticsSession(availability:gate,makeScanner:{AgentScanner(enabled:$0,diagnose:{Self.report()})})
            sessions.append(session);return session
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled})
        XCTAssertTrue(store.windowUI(selection:nil,locations:[.agents]).sidebar.isEmpty);XCTAssertTrue(sessions.isEmpty)
        enabled=true;_=store.windowUI(selection:nil,locations:[.agents]);let old=sessions[0].scanner
        let drain=try XCTUnwrap(store.prepareStop(original.manifest.id))
        XCTAssertTrue(store.windowUI(selection:nil,locations:[.agents]).sidebar.isEmpty)
        await drain.finish();_=store.windowUI(selection:nil,locations:[.agents])
        XCTAssertEqual(sessions.count,2);XCTAssertFalse(old === sessions[1].scanner)
        old.scan();XCTAssertEqual(old.work.count,0)
        if let drain=try store.prepareStop(original.manifest.id){await drain.finish()}
    }
    func testRetiringWindowCancelsReadWithoutRevokingTheFeatureOrPublishingLateReport()async {
        let entered=expectation(description:"diagnosis"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let session=AgentDiagnosticsSession(availability:FeatureAvailability(enabled:{true}),makeScanner:{AgentScanner(enabled:$0,diagnose:{entered.fulfill();_ = release.wait(timeout:.now()+5);return Self.report()})})
        session.scanner.scan();await fulfillment(of:[entered],timeout:2)
        session.retireVisibility();XCTAssertTrue(session.scanner.stopRequested)
        release.signal();await session.scanner.work.finish()
        XCTAssertNil(session.scanner.report);XCTAssertFalse(session.scanner.scanning)
        XCTAssertTrue(session.scanner.work.acceptsWork)
    }
}
