import SwiftUI

/// Owns native session generations, never the concrete models inside them.
/// ModuleCenter remains the one authority for persisted preferences and external CLI admission.
@MainActor package final class NativeFeatureStore {
    private struct Live {
        let generation:UUID
        let availability:FeatureAvailability
        let session:any NativeFeatureSession
    }
    @MainActor private final class Draining {
        let live:Live
        let drain:NativeFeatureDrain
        var task:Task<Void,Never>?
        init(_ live:Live,_ drain:NativeFeatureDrain){self.live=live;self.drain=drain}
        func finish() async {
            if task==nil {let drain=drain;task=Task {await drain.finish()}}
            await task?.value
        }
    }
    private enum State {case live(Live),draining(Draining)}
    private let definitions:[String:NativeFeatureDefinition]
    private let order:[String]
    private let enabled:(String)->Bool
    private var states:[String:State]=[:]
    package init(definitions:[NativeFeatureDefinition],enabled:@escaping (String)->Bool) {
        precondition(Set(definitions.map{$0.manifest.id}).count==definitions.count,"duplicate native feature")
        self.definitions=Dictionary(uniqueKeysWithValues:definitions.map{($0.manifest.id,$0)})
        self.enabled=enabled;order=definitions.map{$0.manifest.id}
    }
    package func page(_ route:NativeFeatureRoute)->AnyView? {
        guard enabled(route.module),let definition=definitions[route.module],
              definition.manifest.entries.contains(where:{$0.id==route.entry && $0.kind == .page}) else{return nil}
        switch states[route.module] {
        case .draining:return nil
        case let .live(live):return live.session.page(entry:route.entry)
        case nil:
            let availability=FeatureAvailability { [weak self] in self?.enabled(route.module) ?? false }
            let session=definition.makeSession(availability)
            states[route.module] = .live(.init(generation:UUID(),availability:availability,session:session))
            return session.page(entry:route.entry)
        }
    }
    package func status(_ id:String)->NativeFeatureStatus {
        switch states[id] {
        case let .live(live):return live.session.status
        case let .draining(pending):return pending.live.session.status
        case nil:return .init()
        }
    }
    package func retireVisibility() {
        for state in states.values {
            switch state {
            case let .live(live):live.session.retireVisibility()
            case let .draining(pending):pending.live.session.retireVisibility()
            }
        }
    }
    package func quitBlocker()->NativeFeatureBlocker? {
        for id in order {
            switch states[id] {
            case let .live(live):if let blocker=live.session.quitBlocker(){return blocker}
            case let .draining(pending):if let blocker=pending.live.session.quitBlocker(){return blocker}
            case nil:break
            }
        }
        return nil
    }
    /// Refusal happens before availability is revoked. An accepted drain is idempotent and
    /// keeps the old generation fenced even when the caller has not yet persisted the switch.
    package func prepareStop(_ id:String)throws->NativeFeatureDrain? {
        let pending:Draining
        switch states[id] {
        case nil:return nil
        case let .draining(existing):pending=existing
        case let .live(live):
            let drain=try live.session.prepareStop()
            live.availability.revoke()
            pending=Draining(live,drain);states[id] = .draining(pending)
        }
        return NativeFeatureDrain { [weak self] in
            await pending.finish()
            guard let self,case let .draining(current)=self.states[id],current === pending else{return}
            self.states[id]=nil
        }
    }
}
