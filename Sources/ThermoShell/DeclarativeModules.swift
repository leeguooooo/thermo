import Foundation
import SwiftUI
import ThermoL10n
import ThermoUI
import ModuleKernelCore
import ModuleKit
import WasmHost

/// Third-party WebAssembly modules whose pages and menu bar items are described as data (#47).
///
/// Installing them is #49's job. Until then they come only from a development folder the person sets
/// themselves (`defaults write dev.thermo.app modules.developmentDirectory <path>`), one folder per
/// module holding `module.json` and `module.wasm`. Each module starts switched off, needs macOS 15,
/// runs in its own sandboxed runner, and reaches the Mac only through the capabilities it declares.
@MainActor final class DeclarativeModules: ObservableObject {
    static let shared = DeclarativeModules()
    static let directoryKey = "modules.developmentDirectory"

    struct Installed {
        let manifest: ModuleManifest
        let host: WasmHost
        let module: DeclarativeModule
    }

    @Published private(set) var installed: [Installed] = []
    @Published private(set) var problems: [String] = []
    /// Bumped by every reload, so pages and menu bar items made from an older build are drawn anew.
    @Published private(set) var generation = 0
    private var models: [String: DeclarativeSceneModel] = [:]
    private var loaded = false
    private let make: (ModuleManifest, Data) -> WasmHost?

    init(make: @escaping (ModuleManifest, Data) -> WasmHost? = { ModuleKernel.wasmHost(for: $0, wasm: $1) }) { self.make = make }

    var manifests: [ModuleManifest] { installed.map(\.manifest) }
    func manifest(_ id: String) -> ModuleManifest? { installed.first { $0.manifest.id == id }?.manifest }

    /// Reads the development folder once. Nothing is loaded when it is not set.
    func loadIfNeeded(defaults: UserDefaults = .standard) {
        guard !loaded else { return }
        loaded = true
        guard let path = defaults.string(forKey: Self.directoryKey), !path.isEmpty else { return }
        load(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
    }

    func load(from directory: URL, builtinIDs: Set<String> = Set(BuiltinModuleManifests.all.map(\.id))) {
        var found: [Installed] = [], issues: [String] = []
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(32) {
            let name = folder.lastPathComponent
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("module.json")) else { continue }
            guard let manifest = try? JSONDecoder().decode(ModuleManifest.self, from: data) else { issues.append("\(name): module.json is not a module manifest"); continue }
            var problems = manifest.problems()
            if builtinIDs.contains(manifest.id) || found.contains(where: { $0.manifest.id == manifest.id }) { problems.append("id \(manifest.id) is already taken") }
            for entry in manifest.entries where entry.kind.showsUI {
                if entry.kind != .page && entry.kind != .menuBarItem { problems.append("entry \(entry.id): only pages and menu bar items can be described") }
                if entry.scene == nil { problems.append("entry \(entry.id) has no scene") }
            }
            guard problems.isEmpty else { issues.append("\(manifest.id): " + problems.joined(separator: "; ")); continue }
            guard let wasm = try? Data(contentsOf: folder.appendingPathComponent("module.wasm")), wasm.count <= 32 << 20 else {
                issues.append("\(manifest.id): module.wasm is missing or over 32 MB"); continue
            }
            guard let host = make(manifest, wasm) else { issues.append("\(manifest.id): WebAssembly modules need macOS 15 and the runner"); continue }
            found.append(.init(manifest: manifest, host: host, module: DeclarativeModule(host: host)))
        }
        installed = found; problems = issues
        for issue in issues { NSLog("Thermo declarative module refused: %@", issue) }
    }

    /// Drops every loaded module (their runners exit) and reads the development folder again.
    func reload(defaults: UserDefaults = .standard) {
        for item in installed { Task { await item.host.stop() } }
        models.removeAll(); installed = []; problems = []; loaded = false
        loadIfNeeded(defaults: defaults)
        generation += 1
    }

    /// One model per scene, kept while the app runs so a page reopens on its last view.
    func model(module id: String, scene: String) -> DeclarativeSceneModel? {
        guard let item = installed.first(where: { $0.manifest.id == id }) else { return nil }
        let key = id + ":" + scene
        if let model = models[key] { return model }
        let model = DeclarativeSceneModel(module: item.module, scene: scene)
        models[key] = model
        return model
    }

    /// Switched off: the runner exits and the scenes forget their views.
    func stop(_ id: String) {
        guard let item = installed.first(where: { $0.manifest.id == id }) else { return }
        models = models.filter { !$0.key.hasPrefix(id + ":") }
        Task { await item.host.stop(); await item.host.resume() }
    }
}


/// Menu bar entries of the declarative modules that are on, as rows in the menu bar panel.
struct DeclarativeMenuBarItems: View {
    @ObservedObject private var center = ModuleCenter.shared
    var body: some View {
        let items = center.declarative.manifests.filter { center.isOn($0.id) }.flatMap { manifest in
            manifest.localized(L10n.current.rawValue).entries.filter { $0.kind == .menuBarItem && $0.scene != nil }.map { (manifest, $0) }
        }
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(items, id: \.1.id) { manifest, entry in
                    if let scene = entry.scene, let model = center.declarative.model(module: manifest.id, scene: scene) {
                        DeclarativeMenuBarItemView(model: model, fallbackTitle: entry.title) {
                            if let page = center.rootPage(manifest.id) { MainWindow.show(page) }
                        }.id(manifest.id + ":" + entry.id + "#\(center.declarative.generation)")
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}
