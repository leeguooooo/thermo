import SwiftUI

/// Owns native session generations, never the concrete models inside them.
/// ModuleCenter remains the one authority for persisted preferences and external CLI admission.
@MainActor package final class NativeFeatureStore {
    @MainActor private final class Live {
        let availability:FeatureAvailability
        let session:any NativeFeatureSession
        var started=false, didShutdown=false
        init(availability:FeatureAvailability,session:any NativeFeatureSession) {self.availability=availability;self.session=session}
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
    package let catalog:NativeFeatureCatalog
    private let enabled:(String)->Bool
    private let navigation:NativeNavigation
    private var states:[String:State]=[:]
    package init(catalog:NativeFeatureCatalog,enabled:@escaping (String)->Bool,navigation:NativeNavigation) {
        self.catalog=catalog;self.enabled=enabled;self.navigation=navigation
    }
    package convenience init(definitions:[NativeFeatureDefinition],enabled:@escaping (String)->Bool,navigation:NativeNavigation = .unavailable) {
        self.init(catalog:try! NativeFeatureCatalog(definitions:definitions),enabled:enabled,navigation:navigation)
    }
    package func canPresent(_ route:NativeFeatureRoute)->Bool {
        guard (try? catalog.normalize(route)) != nil,enabled(route.module) else{return false}
        switch states[route.module] {
        case .draining:return false
        case let .live(live):return live.availability.acceptsWork
        case nil:return true
        }
    }
    private func admittedSession(_ id:String)->(any NativeFeatureSession)? {
        guard enabled(id),let definition=catalog.definitions[id] else{return nil}
        switch states[id] {
        case .draining:return nil
        case let .live(live):return live.availability.acceptsWork ? live.session:nil
        case nil:
            let availability=FeatureAvailability { [weak self] in self?.enabled(id) ?? false }
            let session=definition.makeSession(availability)
            states[id] = .live(.init(availability:availability,session:session))
            return session
        }
    }
    /// Explicit background contribution; metadata/status/quit queries remain cold.
    package func start(_ id:String) {
        guard let session=admittedSession(id),case let .live(live)=states[id],!live.started else{return}
        live.started=true;session.start()
    }
    /// Final exit cleanup only. Normal feature disable still requires prepareStop + drain.
    package func shutdown(_ feature:String? = nil) {
        for id in feature.map({[$0]}) ?? catalog.order {
            let live:Live
            switch states[id] {
            case let .live(value):live=value
            case let .draining(value):live=value.live
            case nil:continue
            }
            guard !live.didShutdown else{continue}
            live.didShutdown=true;live.availability.revoke();live.session.shutdown()
        }
    }
    private func scopedNavigation(_ id:String)->NativeNavigation {
        guard case let .live(live)=states[id] else{return .unavailable}
        let availability=live.availability,navigation=navigation
        return NativeNavigation {request in
            guard availability.acceptsWork else{return false}
            return navigation.show(request)
        }
    }
    @discardableResult package func preparePresentation(_ request:NativePresentationRequest)->Bool {
        guard let canonical=try? catalog.normalizePresentation(request),canPresent(canonical.route) else{return false}
        guard !canonical.options.isEmpty else{return true}
        guard let session=admittedSession(canonical.route.module) else{return false}
        session.preparePresentation(canonical.route,options:canonical.options)
        return true
    }
    package func page(_ request:NativeFeatureRoute)->AnyView? {
        guard let route=try? catalog.normalize(request) else{return nil}
        return admittedSession(route.module)?.page(route,navigation:scopedNavigation(route.module))
    }
    package func prepareReview(_ request:NativeFeatureRoute,arguments:[String]) {
        guard let route=try? catalog.normalize(request) else{return}
        admittedSession(route.module)?.prepareReview(route,arguments:arguments)
    }
    package func snapshotReady(_ request:NativeFeatureRoute,arguments:[String],started:Date)->Bool {
        guard let route=try? catalog.normalize(request) else{return false}
        guard canPresent(route) else{return true}
        guard case let .live(live)=states[route.module] else{return false}
        return live.session.snapshotReady(route,arguments:arguments,started:started)
    }
    @discardableResult package func activate(_ ref:NativeUIEntryRef)->Bool {
        guard catalog.accepts(ref) else{return false}
        return admittedSession(ref.module)?.activate(ref,navigation:scopedNavigation(ref.module)) ?? false
    }
    package func status(_ id:String)->NativeFeatureStatus {
        switch states[id] {
        case let .live(live):return live.session.status
        case let .draining(pending):return pending.live.session.status
        case nil:return .init()
        }
    }
    /// Restoration only invalidates already-owned state; it never admits a feature.
    package func invalidateAfterRestore(_ paths:[String]) {
        guard !paths.isEmpty else{return}
        for id in catalog.order {
            if case let .live(live)=states[id] {live.session.invalidateAfterRestore(paths)}
            else {catalog.definitions[id]?.invalidateColdState(paths)}
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
    package func quitBlocker(_ feature:String? = nil)->NativeFeatureBlocker? {
        for id in feature.map({[$0]}) ?? catalog.order {
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
