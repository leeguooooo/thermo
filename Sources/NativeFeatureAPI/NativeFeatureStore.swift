import SwiftUI

/// Owns native session generations, never the concrete models inside them.
/// ModuleCenter remains the one authority for persisted preferences and external CLI admission.
@MainActor package final class NativeFeatureStore {
    @MainActor private final class Live {
        let generation=UUID()
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
    private struct PageIdentity:Hashable {
        let generation:UUID
        let route:NativeFeatureRoute
    }
    package let catalog:NativeFeatureCatalog
    private let enabled:(String)->Bool
    private let navigation:NativeNavigation
    private var states:[String:State]=[:]
    private var retainedShutdown:Set<String>=[]
    package private(set) var hostPresentation = NativeHostPresentation()
    package func setWindowPresentation(visible: Bool, selection: NativeFeatureRoute?) {
        let checked = selection.flatMap { try? catalog.normalize($0) }
        updateHostPresentation(.init(windowVisible: visible, menuPanelVisible: hostPresentation.menuPanelVisible, selection: checked))
    }
    package func setMenuPanelVisible(_ visible: Bool) {
        updateHostPresentation(.init(windowVisible: hostPresentation.windowVisible, menuPanelVisible: visible, selection: hostPresentation.selection))
    }
    private func updateHostPresentation(_ next: NativeHostPresentation) {
        guard next != hostPresentation else { return }
        hostPresentation = next
        for id in catalog.order {
            guard case let .live(live) = states[id], live.availability.acceptsWork else { continue }
            live.session.hostPresentationChanged(next)
        }
    }
    package init(catalog:NativeFeatureCatalog,enabled:@escaping (String)->Bool,navigation:NativeNavigation) {
        self.catalog=catalog;self.enabled=enabled;self.navigation=navigation
    }
    package convenience init(definitions:[NativeFeatureDefinition],enabled:@escaping (String)->Bool,navigation:NativeNavigation = .unavailable) {
        self.init(catalog:try! NativeFeatureCatalog(definitions:definitions),enabled:enabled,navigation:navigation)
    }
    private func acceptsWork(_ id:String)->Bool {
        guard enabled(id),catalog.definitions[id] != nil else{return false}
        switch states[id] {
        case .draining:return false
        case let .live(live):return live.availability.acceptsWork
        case nil:return true
        }
    }
    package func canPresent(_ route:NativeFeatureRoute)->Bool {
        (try? catalog.normalize(route)) != nil && acceptsWork(route.module)
    }
    /// Policy-only probe: validation/dry-run may inspect admission without constructing a session.
    package func canAdmitUIEntryOwner(_ ref:NativeUIEntryRef)->Bool {
        catalog.accepts(ref) && acceptsWork(ref.module)
    }
    private func admittedSession(_ id:String)->(any NativeFeatureSession)? {
        guard acceptsWork(id),let definition=catalog.definitions[id] else{return nil}
        switch states[id] {
        case .draining:return nil
        case let .live(live):return live.availability.acceptsWork ? live.session:nil
        case nil:
            let availability=FeatureAvailability { [weak self] in self?.enabled(id) ?? false }
            let session=definition.makeSession(availability)
            states[id] = .live(.init(availability:availability,session:session))
            // Replay once to this generation, including a panel opened while the feature was off.
            session.hostPresentationChanged(hostPresentation)
            return session
        }
    }
    /// Called for a real window. Returned views observe private feature state, never this store.
    package func windowUI(selection:NativeFeatureRoute?,locations:Set<NativeSidebarLocation>)->NativeWindowUI {
        let catalog=self.catalog
        let selected=selection.flatMap{try? catalog.normalize($0)}
        var groups:[NativeSidebarGroup]=[],overlays:[NativeOverlayPart]=[]
        for id in catalog.order {
            guard let definition=catalog.definitions[id] else{continue}
            let mounted=definition.ui.sidebarLocations.intersection(locations)
            guard !mounted.isEmpty || definition.ui.hasOverlay else{continue}
            guard let session=admittedSession(id),case let .live(live)=states[id] else{continue}
            let availability=live.availability,navigation=scopedNavigation(id),generation=live.generation
            for location in NativeSidebarLocation.allCases where mounted.contains(location) {
                groups.append(.init(id:id+":"+location.rawValue,location:location,manifest:definition.manifest,mount:{host in
                    guard availability.acceptsWork else{return AnyView(EmptyView())}
                    let rows=NativeSidebarRenderer {item in
                        guard availability.acceptsWork,item.badge>=0,item.route.module==id,
                              item.trailing?.unicodeScalars.contains(where:{$0.value == 0 || $0.value == 10 || $0.value == 13}) != true,
                              let route=try? catalog.normalize(item.route),
                              let entry=definition.manifest.entries.first(where:{$0.id==route.entry && $0.kind == .page}) else{return AnyView(EmptyView())}
                        return host.render(.init(route:route,manifest:definition.manifest,entry:entry,tint:item.tint,badge:item.badge,trailing:item.trailing,trailingColor:item.trailingColor,selected:selected==route,open:{_ = navigation.show(route)}))
                    }
                    return AnyView((session.ui(.sidebar(location:location,selection:selected,rows:rows),navigation:navigation) ?? AnyView(EmptyView())).id(generation))
                }))
            }
            if definition.ui.hasOverlay,let view=session.ui(.windowOverlay,navigation:navigation) {
                overlays.append(.init(id:id,generation:generation,view:view))
            }
        }
        var backdrop:AnyView?
        if let selected,catalog.definitions[selected.module]?.ui.hasBackdrop == true,
           let session=admittedSession(selected.module),case let .live(live)=states[selected.module],
           let view=session.ui(.backdrop(selected),navigation:scopedNavigation(selected.module)) {
            backdrop=AnyView(view.id(live.generation))
        }
        return .init(sidebar:groups,overlay:AnyView(NativeOverlays(parts:overlays)),backdrop:backdrop)
    }
    /// Compact content is attached only to the exact declared page owner, with normal admission.
    package func compactPanel(_ request:NativeFeatureRoute)->AnyView? {
        guard let route=try? catalog.normalize(request),
              catalog.definitions[route.module]?.ui.compactPanelEntry==route.entry,
              let session=admittedSession(route.module),case let .live(live)=states[route.module],
              let view=session.ui(.compactPanel(route),navigation:scopedNavigation(route.module)) else{return nil}
        return AnyView(view.id(live.generation))
    }
    /// Hierarchical menu content is declared separately so leaf menu metadata stays model-cold.
    package func menuContent(_ ref:NativeUIEntryRef)->NativeMenuContent? {
        guard let definition=catalog.definitions[ref.module],definition.ui.hasMenuContent,
              definition.manifest.entries.contains(where:{$0.id==ref.entry && $0.kind == .menuBarItem}),
              let session=admittedSession(ref.module),case let .live(live)=states[ref.module],
              let content=session.menuContent(ref) else{return nil}
        return content.scoped(to:live.availability,generation:live.generation)
    }
    /// Only already-owned recovery state, independent of normal admission. Never constructs a session.
    package func retainedMenuContent()->[NativeRetainedMenu] {
        catalog.order.compactMap{id in
            guard !retainedShutdown.contains(id),let definition=catalog.definitions[id],
                  let value=definition.retained.menu(),value.owner.module==id,
                  definition.manifest.entries.contains(where:{$0.id==value.owner.entry && $0.kind == .menuBarItem}) else{return nil}
            let content=value.content.checkedContent(available:{[weak self] in self.map{!$0.retainedShutdown.contains(id)} ?? false},generation:UUID())
            return .init(owner:value.owner,content:content)
        }
    }
    /// Inline UI is admitted only for an exact declared settings entry.
    package func inlineSettings(_ ref:NativeUIEntryRef)->AnyView? {
        guard catalog.definitions[ref.module]?.manifest.entries.contains(where:{$0.id==ref.entry && $0.kind == .settingsItem}) == true,
              let session=admittedSession(ref.module),case let .live(live)=states[ref.module],
              let view=session.ui(.inlineSettings(ref),navigation:scopedNavigation(ref.module)) else{return nil}
        return AnyView(view.id(live.generation))
    }
    /// Explicit developer rendering of a declared settings contribution, without background start.
    package func renderPreview(_ ref:NativeUIEntryRef)->AnyView? {
        guard catalog.definitions[ref.module]?.manifest.entries.contains(where:{$0.id==ref.entry && $0.kind == .settingsItem}) == true,
              let session=admittedSession(ref.module),case let .live(live)=states[ref.module],
              let view=session.ui(.renderPreview(ref),navigation:scopedNavigation(ref.module)) else{return nil}
        return AnyView(view.id(live.generation))
    }
    /// Inert checked owner admission for an existing UI-related system operation. Returns no model.
    package func admitUIEntryOwner(_ ref:NativeUIEntryRef)->Bool {
        guard canAdmitUIEntryOwner(ref) else{return false}
        return admittedSession(ref.module) != nil
    }
    /// Explicit background contribution; metadata/status/quit queries remain cold.
    package func startBackground(_ id:String) {
        guard catalog.backgroundFeatures.contains(id) else{return}
        start(id)
    }
    package func start(_ id:String) {
        guard let session=admittedSession(id),case let .live(live)=states[id],!live.started else{return}
        live.started=true;session.start()
    }
    /// Final exit cleanup only. Normal feature disable still requires prepareStop + drain.
    package func shutdown(_ feature:String? = nil) {
        for id in feature.map({[$0]}) ?? catalog.order {
            // Mark before invoking user code so reentrant shutdown cannot repeat retained cleanup.
            let cleanup=retainedShutdown.insert(id).inserted
            defer {if cleanup{catalog.definitions[id]?.retained.shutdown()}}
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
        return NativeNavigation(canAdmit:{[weak self] route in
            availability.acceptsWork && self?.canPresent(route) == true
        },show:{request in
            guard availability.acceptsWork else{return false}
            return navigation.show(request)
        })
    }
    @discardableResult package func preparePresentation(_ request:NativePresentationRequest)->Bool {
        guard let canonical=try? catalog.normalizePresentation(request),canPresent(canonical.route) else{return false}
        guard !canonical.options.isEmpty else{return true}
        guard let session=admittedSession(canonical.route.module) else{return false}
        session.preparePresentation(canonical.route,options:canonical.options)
        return true
    }
    package func page(_ request:NativeFeatureRoute)->AnyView? {
        guard let route=try? catalog.normalize(request),
              let session=admittedSession(route.module),case let .live(live)=states[route.module],
              let view=session.page(route,navigation:scopedNavigation(route.module)) else{return nil}
        return AnyView(view.id(PageIdentity(generation:live.generation,route:route)))
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
    /// Host wake only reaches existing, admitted owners; metadata never starts work.
    package func didWake() {
        for id in catalog.order {
            guard case let .live(live)=states[id],live.availability.acceptsWork else{continue}
            live.session.didWake()
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
    /// Exit probes never admit a cold feature. A deferred decision retains its exact origin.
    package func prepareTermination()->NativeTerminationDecision {
        for id in catalog.order {
            let session:any NativeFeatureSession
            switch states[id] {
            case let .live(live):session=live.session
            case let .draining(pending):session=pending.live.session
            case nil:continue
            }
            switch session.prepareTermination() {
            case .allow:continue
            case let decision:return decision
            }
        }
        return .allow
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
