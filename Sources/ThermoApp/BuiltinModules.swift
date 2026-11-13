import ModuleKit
import SwiftUI
import ThermoL10n

struct BuiltinSidebarItem: Identifiable {
    let entry: ModuleManifest.Entry
    let target: MainPage
    let tint: Color
    var trailing: String?
    var selected: Bool
    var id: String { entry.id }
}

/// Metadata and argument resolution never instantiate a feature. UI and lifetime callbacks run on main.
protocol BuiltinModule: Sendable {
    static var manifest: ModuleManifest { get }
    static var legacyMenuEntries: [String: String] { get }
    static func owns(_ page: MainPage) -> Bool
    static func canonicalArgument(_ argument: String) -> String
    static func target(_ scene: String) -> MainPage?
    static func supports(_ entry: ModuleManifest.Entry) -> Bool
    @MainActor static func sidebar(page: Binding<MainPage>, models: AppModels,
                                   row: @escaping @MainActor (BuiltinSidebarItem) -> AnyView) -> AnyView
    @MainActor static func page(_ entry: ModuleManifest.Entry, selection: Binding<MainPage>, models: AppModels) -> AnyView
    @MainActor static func settings(_ entry: ModuleManifest.Entry, models: AppModels) -> AnyView
    @MainActor static func prepareStop(models: AppModels) throws -> BuiltinModules.FinishStop?
    @MainActor static func appearance(_ page: MainPage) -> (glow: Bool, tint: Color?)
    @MainActor static func prepareReview(_ arguments: [String], page: inout MainPage, models: AppModels)
    @MainActor static func snapshotReady(_ arguments: [String], models: AppModels) -> Bool
}

enum BuiltinModules {
    static let implementations: [any BuiltinModule.Type] = [DiskModule.self]
    static var all: [ModuleManifest] { implementations.map { $0.manifest } }
    static var disk: ModuleManifest { DiskModule.manifest }
    static func manifest(_ id: String) -> ModuleManifest? { all.first { $0.id == id } }
    static func implementation(_ id: String) -> (any BuiltinModule.Type)? { implementations.first { $0.manifest.id == id } }
    static func owner(_ page: MainPage) -> (any BuiltinModule.Type)? { implementations.first { $0.owns(page) } }

    struct Page {
        let implementation: any BuiltinModule.Type
        let entry: ModuleManifest.Entry
        var module: ModuleManifest { implementation.manifest }
        var target: MainPage? { entry.scene.flatMap { implementation.target($0) } }
    }
    static func page(_ page: MainPage) -> Page? {
        guard let owner = owner(page) else { return nil }
        let entry: ModuleManifest.Entry?
        if case let .module(_, id) = page {
            entry = owner.manifest.entries.first { $0.kind == .page && (id.isEmpty ? $0.parent == nil : $0.id == id) }
        } else { entry = owner.manifest.entries.first { $0.kind == .page && $0.scene.flatMap { owner.target($0) } == page } }
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

    @MainActor static func snapshotReady(_ page: MainPage, arguments: [String], models: AppModels, center: ModuleCenter) -> Bool? {
        guard owner(page) != nil else { return nil }
        guard center.shows(page), let feature = self.page(page) else { return true }
        return feature.implementation.snapshotReady(arguments, models: models)
    }

    typealias FinishStop = @MainActor () async -> Void
    struct StopRefused: Error, CustomStringConvertible { let description: String }
    @MainActor static func prepareStop(_ id: String) throws -> FinishStop? {
        try implementation(id)?.prepareStop(models: .shared)
    }
}

extension MainPage {
    var module: String? {
        if case let .module(id, _) = self { return id }
        return BuiltinModules.owner(self)?.manifest.id
    }
}

struct BuiltinSidebarGroup: View {
    let implementation: any BuiltinModule.Type
    @Binding var selection: MainPage
    let row: @MainActor (BuiltinSidebarItem) -> AnyView
    var body: some View { implementation.sidebar(page: $selection, models: .shared, row: row) }
}
