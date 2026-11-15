import AppKit
import CleanKit
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n
import ThermoUI

package enum DiskFeature {
    package static func registration(services:@escaping @MainActor @Sendable ()->any DiskServices)->NativeFeatureDefinition {
        let cache=DiskCacheEpoch()
        return .init(manifest:BuiltinModuleManifests.disk,ui:.init(sidebarLocations:[.storage],hasBackdrop:true),legacyMenuEntries:["smartScan":"scan"],resolveLegacyPage:legacyPage,resolveLegacyLaunch:{arguments in
            guard arguments.contains("--disk") else{return nil}
            let raw=arguments.firstIndex(of:"--page").flatMap{$0+1<arguments.count ? arguments[$0+1]:nil}
            return .init(route:raw.flatMap{legacyPage("disk:"+$0)} ?? route(.home))
        },invalidateColdState:{paths in if !paths.isEmpty{cache.invalidate()}},makeSession:{DiskSession(availability:$0,services:services(),cache:cache)})
    }
    private static func legacyPage(_ argument:String)->NativeFeatureRoute? {
        let argument=argument=="disk:home" ? "disk":argument
        return BuiltinModuleManifests.disk.entries.first{$0.kind == .page && $0.scene==argument}.map{.init(BuiltinModuleManifests.disk.id,$0.id)}
    }
    static func route(_ page:DiskPage)->NativeFeatureRoute {
        switch page {
        case .home:return .init(BuiltinModuleManifests.disk.id,"scan")
        case .overview:return .init(BuiltinModuleManifests.disk.id,"overview")
        case let .category(category):return .init(BuiltinModuleManifests.disk.id,category.rawValue)
        }
    }
    static func page(_ route:NativeFeatureRoute)->DiskPage? {
        guard route.module==BuiltinModuleManifests.disk.id,let entry=BuiltinModuleManifests.disk.entries.first(where:{$0.id==route.entry && $0.kind == .page}),let scene=entry.scene else{return nil}
        return scene=="disk" ? .home:DiskPage(argument:String(scene.dropFirst(5)))
    }
}

@MainActor final class DiskSession:NativeFeatureSession {
    typealias CleanupFactory = @MainActor (DiskCacheEpoch,FeatureTasks)->DiskModel
    typealias OverviewFactory = @MainActor (DiskCacheEpoch)->SpaceOverviewModel
    private let availability:FeatureAvailability
    private let services:any DiskServices
    private let cache:DiskCacheEpoch
    private let makeDisk:CleanupFactory
    private let makeOverview:OverviewFactory
    let explanationWork=FeatureTasks()
    private var storedDisk:DiskModel?
    private var storedOverview:SpaceOverviewModel?
    private var visibilityGeneration:UInt64=0
    init(availability:FeatureAvailability,services:any DiskServices,cache:DiskCacheEpoch,
         makeDisk:CleanupFactory? = nil,makeOverview:OverviewFactory? = nil) {
        self.availability=availability;self.services=services;self.cache=cache
        self.makeDisk=makeDisk ?? {cache,work in DiskModel(requestNotifications:{services.requestScanNotifications()},retentionPreferences:.stored(in:.standard),enabled:{availability.acceptsWork},cache:cache,explanationWork:work)}
        self.makeOverview=makeOverview ?? {cache in SpaceOverviewModel(cached:cache.permitsCache ? SpaceOverview.cached(localize:true):nil,enabled:{availability.acceptsWork},cache:cache)}
        explanationWork.enabled={availability.acceptsWork}
    }
    var disk:DiskModel {
        if let storedDisk{return storedDisk}
        let made=makeDisk(cache,explanationWork)
        made.cleanupDidChange={ [weak self] in self?.storedOverview?.invalidateAfterCleanup() }
        storedDisk=made;return made
    }
    var overview:SpaceOverviewModel {
        if let storedOverview{return storedOverview}
        let made=makeOverview(cache);storedOverview=made;return made
    }
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork,let sub=DiskFeature.page(route) else{return nil}
        let acceptsPresentation=presentationGate()
        return AnyView(DiskPages(navigate:{_ = navigation.show(DiskFeature.route($0))},revealInSpace:{[services] path in
            guard acceptsPresentation() else{return};services.revealInSpace(path)
        },overview:sub == .overview ? overview:nil,availability:acceptsPresentation,sub:sub,disk:disk))
    }
    func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork else{return nil}
        switch surface {
        case let .sidebar(location,selection,rows):
            guard location == .storage else{return nil}
            return AnyView(DiskSidebar(disk:disk,selection:selection,rows:rows))
        case let .inlineSettings(ref):
            guard ref.module==BuiltinModuleManifests.disk.id,let entry=BuiltinModuleManifests.disk.entries.first(where:{$0.id==ref.entry && $0.kind == .settingsItem}) else{return nil}
            return AnyView(CleanupProtectionsButton(disk:disk,asRow:true,title:tr(entry.title),symbol:entry.symbol ?? BuiltinModuleManifests.disk.symbol))
        case let .backdrop(route):return AnyView(WindowBackdrop(glow:route.entry=="scan",tint:Color(red:0.36,green:0.42,blue:1)))
        case .windowOverlay,.renderPreview,.compactPanel:return nil
        }
    }
    var status:NativeFeatureStatus {.init(modelLoaded:storedDisk != nil || storedOverview != nil,sampling:storedDisk.map{$0.scanning || $0.loadingSaved} == true || storedOverview?.measuring == true,snapshotReady:storedDisk.map{!$0.loadingSaved && !$0.scanning && $0.report != nil} ?? false)}
    func quitBlocker()->NativeFeatureBlocker? {
        guard storedDisk.map({$0.cleaning || $0.aiPicking != nil}) == true || explanationWork.hasOperations else{return nil}
        return .init(reason:tr("Wait for cleanup or AI selection to finish before switching this feature off."),route:DiskFeature.route(.home))
    }
    func presentationGate()->@MainActor ()->Bool {
        let generation=visibilityGeneration
        return {[weak self,availability] in availability.acceptsWork && self?.visibilityGeneration==generation}
    }
    func retireVisibility(){visibilityGeneration &+= 1;storedOverview?.stop()}
    func shutdown(){storedDisk?.stop();storedOverview?.retire();explanationWork.stop()}
    func prepareStop()throws->NativeFeatureDrain {
        if let blocker=quitBlocker(){throw NativeFeatureBusy(blocker.reason)}
        guard storedDisk?.prepareToDisable() != false else{throw NativeFeatureBusy(tr("Wait for cleanup or AI selection to finish before switching this feature off."))}
        let revision=cache.current,disk=storedDisk,overview=storedOverview,work=explanationWork,cache=cache
        overview?.retire();work.stop()
        return .init{[weak self] in
            await disk?.finishDisabling();await overview?.finishRetiring();await work.finish()
            if cache.current != revision {await Task.detached(priority:.utility){cache.clearFiles()}.value}
            self?.storedDisk=nil;self?.storedOverview=nil
        }
    }
    func invalidateAfterRestore(_ paths:[String]) {
        guard !paths.isEmpty else{return}
        cache.invalidate();storedDisk?.invalidateAfterRestore();storedOverview?.invalidateAfterRestore()
    }
    func prepareReview(_ route:NativeFeatureRoute,arguments:[String]) {
        guard availability.acceptsWork,arguments.contains("--disk") else{return}
        if arguments.contains("--all"){disk.scope = .all}
        if !arguments.contains("--no-scan") {
            let category:CleanCategory?
            if case let .category(value)?=DiskFeature.page(route){category=value}else{category=nil}
            disk.loadSaved(category:category,scanIfMissing:true)
        }
    }
    func snapshotReady(_ route:NativeFeatureRoute,arguments:[String],started:Date)->Bool {
        guard let disk=storedDisk else{return false}
        return !disk.loadingSaved && !disk.scanning && (arguments.contains("--no-scan") || !arguments.contains("--disk") || disk.report != nil)
    }
}

struct DiskSidebar:View {
    @ObservedObject var disk:DiskModel
    let selection:NativeFeatureRoute?
    let rows:NativeSidebarRenderer
    var body:some View {
        ForEach(BuiltinModuleManifests.disk.entries.filter{$0.kind == .page},id:\.id){entry in
            if let item=Self.contribution(entry,disk:disk,selection:selection){rows(item)}
        }
    }
    static func contribution(_ entry:ModuleManifest.Entry,disk:DiskModel,selection:NativeFeatureRoute?)->NativeSidebarContribution? {
        guard entry.parent == nil || selection?.module==BuiltinModuleManifests.disk.id else{return nil}
        let route=NativeFeatureRoute(BuiltinModuleManifests.disk.id,entry.id)
        guard let sub=DiskFeature.page(route) else{return nil}
        var tint=Color.pink,trailing:String?
        switch sub {
        case .home:trailing=disk.report.map{ByteFormat.string($0.totalBytes)}
        case .overview:tint = .teal
        case let .category(category):
            let bytes=disk.report?.bytes(in:category) ?? 0
            guard category == .aiSessions || bytes>0 || disk.report?.items.contains(where:{$0.category==category}) == true else{return nil}
            tint=DiskStyle.tint(category);trailing=category == .aiSessions && disk.sessionRetentionDays == nil ? nil:ByteFormat.string(bytes)
        }
        return .init(route:route,tint:tint,trailing:trailing)
    }
}
