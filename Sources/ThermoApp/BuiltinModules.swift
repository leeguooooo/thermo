import NativeFeatureAPI
import ModuleKit
import SwiftUI
import ThermoL10n

struct BuiltinSidebarItem: Identifiable {
    let entry: ModuleManifest.Entry
    let target: MainPage
    let tint: Color
    var trailing: String?
    var trailingColor: Color?
    var badge:Int = 0
    var selected: Bool
    var id: String { entry.id }
}

typealias BuiltinSidebarSection=NativeSidebarLocation

/// Metadata and argument resolution never instantiate a feature. UI and lifetime callbacks run on main.
protocol BuiltinModule: Sendable {
    static var manifest: ModuleManifest { get }
    @MainActor static func start()
    @MainActor static func overlay(models:AppModels)->AnyView
    static var legacyMenuEntries: [String: String] { get }
    static var sidebarSections: Set<BuiltinSidebarSection> { get }
    static func owns(_ page: MainPage) -> Bool
    static func entry(for page:MainPage)->ModuleManifest.Entry?
    static func canonicalArgument(_ argument: String) -> String
    static func target(_ scene: String) -> MainPage?
    static func supports(_ entry: ModuleManifest.Entry) -> Bool
    @MainActor static func sidebar(section: BuiltinSidebarSection, page: Binding<MainPage>, models: AppModels,
                                   row: @escaping @MainActor (BuiltinSidebarItem) -> AnyView) -> AnyView
    @MainActor static func page(_ entry: ModuleManifest.Entry, selection: Binding<MainPage>, models: AppModels) -> AnyView
    @MainActor static func settings(_ entry: ModuleManifest.Entry, models: AppModels) -> AnyView
    @MainActor static func prepareStop(models: AppModels) throws -> BuiltinModules.FinishStop?
    @MainActor static func appearance(_ page: MainPage) -> (glow: Bool, tint: Color?)
    @MainActor static func prepareReview(_ arguments: [String], page: inout MainPage, models: AppModels)
    @MainActor static func snapshotReady(_ arguments: [String], models: AppModels, started: Date) -> Bool
}

extension BuiltinModule {
    static func entry(for page:MainPage)->ModuleManifest.Entry? {
        manifest.entries.first{$0.kind == .page && $0.scene.flatMap(target)==page}
    }
    static var sidebarSections: Set<BuiltinSidebarSection> { [.storage] }
    @MainActor static func start() {}
    @MainActor static func overlay(models:AppModels)->AnyView {AnyView(EmptyView())}
}

enum BuiltinModules {
    static let implementations: [any BuiltinModule.Type] = [DiskModule.self, SearchModule.self, CaptureModule.self, MenuBarModule.self, PerformanceModule.self, AppsModule.self, SpaceModule.self, BrowserModule.self, ConnectionsModule.self, HistoryModule.self, AgentDiagnosticsModule.self, CheckupModule.self, PluginsModule.self, ClaudeToolsModule.self, DownloadModule.self]
    static var all: [ModuleManifest] { implementations.map { $0.manifest } }
    static var disk: ModuleManifest { DiskModule.manifest }
    static func manifest(_ id: String) -> ModuleManifest? { all.first { $0.id == id } }
    static func implementation(_ id: String) -> (any BuiltinModule.Type)? { implementations.first { $0.manifest.id == id } }
    static func owner(_ page: MainPage) -> (any BuiltinModule.Type)? {
        if case let .native(route)=page{return implementation(route.module)}
        return implementations.first { $0.owns(page) }
    }
    static func workerOwner(_ id:String)->ModuleManifest? {BuiltinNativeFeatures.catalog.workerOwner(id)}

    struct Page {
        let implementation: any BuiltinModule.Type
        let entry: ModuleManifest.Entry
        var module: ModuleManifest { implementation.manifest }
        var target: MainPage? { entry.scene.flatMap { implementation.target($0) } }
    }
    static func page(_ page: MainPage) -> Page? {
        guard let owner = owner(page) else { return nil }
        let entry: ModuleManifest.Entry?
        if case let .native(route)=page {
            entry=owner.manifest.entries.first{$0.id==route.entry && $0.kind == .page}
        } else if case let .module(_, id) = page {
            entry = owner.manifest.entries.first { $0.kind == .page && (id.isEmpty ? $0.parent == nil : $0.id == id) }
        } else { entry = owner.entry(for:page) }
        return entry.map { .init(implementation: owner, entry: $0) }
    }
    static func argument(_ argument: String) -> MainPage? {
        for owner in implementations {
            let canonical = owner.canonicalArgument(argument)
            if let entry = owner.manifest.entries.first(where: { $0.kind == .page && $0.scene == canonical }),
               let scene = entry.scene { return owner.target(scene) }
        }
        return nil
    }
    static func legacyMenuEntry(_ key: String) -> Page? {
        for owner in implementations {
            if let id = owner.legacyMenuEntries[key],
               let entry = owner.manifest.entries.first(where: { $0.kind == .page && $0.id == id }) {
                return .init(implementation: owner, entry: entry)
            }
        }
        return nil
    }
    static var problems: [String] {
        all.flatMap { $0.problems() } + implementations.flatMap { owner in
            owner.manifest.entries.filter { !owner.supports($0) }.map { "\(owner.manifest.id) has no implementation for entry \($0.id)" }
        }
    }

    @MainActor static func snapshotReady(_ page: MainPage, arguments: [String], models: AppModels, center: ModuleCenter, started: Date = .distantPast) -> Bool? {
        if case let .native(route)=page{return models.nativeFeatures.snapshotReady(route,arguments:arguments,started:started)}
        guard owner(page) != nil else { return nil }
        guard center.shows(page), let feature = self.page(page) else { return true }
        return feature.implementation.snapshotReady(arguments, models: models, started: started)
    }

    typealias FinishStop = @MainActor () async -> Void
    struct StopRefused: Error, CustomStringConvertible { let description: String }
    @MainActor static func prepareStop(_ id: String) throws -> FinishStop? {
        try implementation(id)?.prepareStop(models: .shared)
    }
    @MainActor static func start(_ id:String) {AppModels.shared.nativeFeatures.startBackground(id)}
}

extension MainPage {
    var module: String? {
        if case let .native(route)=self{return route.module}
        if case let .module(id, _) = self { return id }
        return BuiltinModules.owner(self)?.manifest.id
    }
}

struct BuiltinSidebarGroup: View {
    let implementation: any BuiltinModule.Type
    var section: BuiltinSidebarSection = .storage
    @Binding var selection: MainPage
    let row: @MainActor (BuiltinSidebarItem) -> AnyView
    var body: some View { implementation.sidebar(section: section, page: $selection, models: .shared, row: row) }
}

/// Feature-owned notices stay attached to the window when another page is selected.
struct BuiltinModuleOverlays:View {
    let models:AppModels
    @ObservedObject private var center=ModuleCenter.shared
    var body:some View {
        ForEach(BuiltinModules.implementations.indices,id:\.self) {index in
            let feature=BuiltinModules.implementations[index]
            if center.isOn(feature.manifest.id) {feature.overlay(models:models)}
        }
    }
}
