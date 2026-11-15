import AppKit
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import XCTest
@testable import ThermoApp

@MainActor final class NativeTerminationHostRoutingTests:XCTestCase {
    private final class Session:NativeFeatureSession {
        var probes=0
        var decision=NativeTerminationDecision.allow
        func prepareTermination()->NativeTerminationDecision{probes+=1;return decision}
        func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?{nil}
        var status:NativeFeatureStatus{.init()}
        func retireVisibility(){}
        func quitBlocker()->NativeFeatureBlocker?{nil}
        func prepareStop()throws->NativeFeatureDrain{.init{}}
    }
    private func setup()->(NativeFeatureStore,Session,()->Int) {
        let session=Session();var made=0
        let manifest=ModuleManifest(id:"com.example.exit",name:"Exit fixture",summary:"",symbol:"doc",version:"1.0.0",entries:[.init(id:"settings",kind:.settingsItem,title:"Settings")])
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{_ in made+=1;return session})
        return (NativeFeatureStore(definitions:[definition],enabled:{_ in true}),session,{made})
    }
    func testPriorVetoAndColdTerminationNeverConstructOrProbeAFeature() {
        let (store,session,made)=setup();let coordinator=NativeTerminationCoordinator(complete:{_ in XCTFail("no deferred exit")})
        XCTAssertEqual(coordinator.reply(after:.terminateCancel,features:store),.terminateCancel)
        XCTAssertEqual(coordinator.reply(after:.terminateLater,features:store),.terminateLater)
        XCTAssertEqual(coordinator.reply(after:.terminateNow,features:store),.terminateNow)
        XCTAssertEqual(made(),0);XCTAssertEqual(session.probes,0)
        XCTAssertTrue(store.admitUIEntryOwner(.init("com.example.exit","settings")))
        XCTAssertEqual(coordinator.reply(after:.terminateCancel,features:store),.terminateCancel);XCTAssertEqual(session.probes,0)
        session.decision = .cancel
        XCTAssertEqual(coordinator.reply(after:.terminateNow,features:store),.terminateCancel);XCTAssertEqual(session.probes,1)
    }
    func testRepeatedDeferredExitStartsAndRepliesOnceForTheActualResult() async throws {
        for allowed in [false,true] {
            let (store,session,_)=setup();XCTAssertTrue(store.admitUIEntryOwner(.init("com.example.exit","settings")))
            let entered=expectation(description:"physical finalization started"),completed=expectation(description:"single AppKit reply")
            var continuation:CheckedContinuation<Bool,Never>?,starts=0,replies:[Bool]=[]
            let ticket=NativeTerminationTicket{starts+=1;entered.fulfill();return await withCheckedContinuation{continuation=$0}}
            session.decision = .deferred(ticket)
            let coordinator=NativeTerminationCoordinator(complete:{value in replies.append(value);completed.fulfill()})
            XCTAssertEqual(coordinator.reply(after:.terminateNow,features:store),.terminateLater)
            XCTAssertEqual(coordinator.reply(after:.terminateNow,features:store),.terminateLater)
            await fulfillment(of:[entered],timeout:2)
            XCTAssertEqual(starts,1);XCTAssertEqual(session.probes,1);XCTAssertFalse(ticket.resolved)
            let join=Task{await ticket.finish()}
            continuation?.resume(returning:allowed)
            await fulfillment(of:[completed],timeout:2)
            let same=await join.value
            XCTAssertEqual(same,allowed);XCTAssertEqual(replies,[allowed]);XCTAssertTrue(ticket.resolved);XCTAssertEqual(starts,1)
        }
    }
}
