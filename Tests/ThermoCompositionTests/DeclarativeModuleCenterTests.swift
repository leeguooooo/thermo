import ModuleDevKit
import ModuleKernelCore
import ModuleKit
@testable import ThermoL10n
import WasmHost
import XCTest
@testable import ThermoShell
@testable import ThermoComposition

@MainActor final class DeclarativeModuleCenterTests: ThermoCompositionTestCase {
    func folder(_ manifests: [String: ModuleManifest]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-declarative-" + UUID().uuidString)
        for (name, manifest) in manifests {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("module.json"))
            try Data([0, 97, 115, 109, 1, 0, 0, 0]).write(to: dir.appendingPathComponent("module.wasm"))
        }
        return root
    }
    func manifest(_ id: String, entries: [ModuleManifest.Entry]) -> ModuleManifest {
        ModuleManifest(id: id, name: "Views", summary: "", symbol: "cube", version: "1.0.0", entries: entries)
    }
    let page = ModuleManifest.Entry(id: "main", kind: .page, title: "Main", scene: "main")

    func registry() -> DeclarativeModules {
        DeclarativeModules { manifest, wasm in
            WasmHost(manifest: manifest, wasm: wasm, broker: CapabilityBroker(manifest: manifest, home: NSTemporaryDirectory(), log: ModuleAccessLog(home: NSTemporaryDirectory()), handlers: [:]),
                     launcher: .process(URL(fileURLWithPath: "/nonexistent")), supported: true)
        }
    }

    func testDeclarativeModulesAreOffUntilSwitchedOnThenShowTheirPages() throws {
        let root = try folder(["views": manifest("dev.example.views", entries: [page, .init(id: "menu", kind: .menuBarItem, title: "M", scene: "menu")])])
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "thermo-declarative-center-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let registry = registry(); registry.load(from: root)
        XCTAssertEqual(registry.manifests.map(\.id), ["dev.example.views"]); XCTAssertTrue(registry.problems.isEmpty)
        let center = ModuleCenter(defaults: defaults, declarative: registry)
        XCTAssertTrue(center.isDeclarative("dev.example.views"))
        XCTAssertEqual(center.switches.last?.manifest.id, "dev.example.views"); XCTAssertEqual(center.switches.last?.enabled, false)
        XCTAssertNil(center.page(module: "dev.example.views", entry: "main"))
        center.setEnabled("dev.example.views", true)
        XCTAssertNotNil(center.page(module: "dev.example.views", entry: "main"))
        XCTAssertTrue(center.activeManifests.contains { $0.id == "dev.example.views" })
        XCTAssertNotNil(registry.model(module: "dev.example.views", scene: "main"))
        XCTAssertTrue(registry.model(module: "dev.example.views", scene: "main") === registry.model(module: "dev.example.views", scene: "main"))
        center.setEnabled("dev.example.views", false)
        XCTAssertNil(center.page(module: "dev.example.views", entry: "main")); XCTAssertEqual(center.stopProgress["dev.example.views"], .processExited)
    }

    func testRefusesTakenIDsAndEntriesItCannotDraw() throws {
        let root = try folder([
            "a": manifest(BuiltinModuleManifests.disk.id, entries: [page]),
            "b": manifest("dev.example.card", entries: [.init(id: "c", kind: .overviewCard, title: "C", scene: "c")]),
            "c": manifest("dev.example.noscene", entries: [.init(id: "p", kind: .page, title: "P")]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = registry(); registry.load(from: root)
        XCTAssertTrue(registry.manifests.isEmpty); XCTAssertEqual(registry.problems.count, 3)
        XCTAssertTrue(registry.problems.contains { $0.contains("already taken") })
        XCTAssertTrue(registry.problems.contains { $0.contains("only pages and menu bar items") })
        XCTAssertTrue(registry.problems.contains { $0.contains("has no scene") })
    }

    func testDevRunReloadReadsTheFolderAgainAndRedrawsPages() throws {
        let root = try folder(["views": manifest("dev.example.views", entries: [page])])
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "thermo-declarative-reload-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(root.path, forKey: DeclarativeModules.directoryKey)
        let registry = registry()
        let center = ModuleCenter(defaults: defaults, declarative: registry)
        registry.loadIfNeeded(defaults: defaults)
        XCTAssertEqual(registry.manifests.map(\.id), ["dev.example.views"])
        let before = registry.generation, revision = center.revision
        // thermo dev run rebuilt the folder under a new id and posted the reload.
        try FileManager.default.removeItem(at: root.appendingPathComponent("views"))
        let next = try folder(["renamed": manifest("dev.example.renamed", entries: [page])])
        defer { try? FileManager.default.removeItem(at: next) }
        defaults.set(next.path, forKey: DeclarativeModules.directoryKey)
        center.reloadDevelopmentModules()
        XCTAssertEqual(registry.manifests.map(\.id), ["dev.example.renamed"])
        XCTAssertGreaterThan(registry.generation, before); XCTAssertGreaterThan(center.revision, revision)
        XCTAssertEqual(DevReload.directoryKey, DeclarativeModules.directoryKey, "the CLI writes the key the app reads")
    }
    func testNothingLoadsWithoutTheDevelopmentFolderSetting() {
        let name = "thermo-declarative-unset-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let registry = registry(); registry.loadIfNeeded(defaults: defaults)
        XCTAssertTrue(registry.installed.isEmpty)
    }

    func testSceneModelKeepsTheLastGoodViewAndStartsFormsFromTheModulesValues() async {
        let manifest = manifest("dev.example.views", entries: [page])
        let good = #"{"version":1,"sections":[{"type":"form","id":"f","fields":[{"id":"t","label":"T","input":"text"},{"id":"c","label":"C","input":"choice","options":[{"id":"x","title":"X"}]},{"id":"b","label":"B","input":"toggle","value":true}],"submit":{"action":"save","title":"Save"}}]}"#
        let answers = Answers([good, "{not json"])
        let model = DeclarativeSceneModel(module: DeclarativeModule(manifest: manifest) { _, _ in .init(status: 0, output: Data(await answers.next().utf8)) },
                                          scene: "main", language: { "en" })
        await model.load()
        XCTAssertNotNil(model.view); XCTAssertNil(model.problem)
        XCTAssertEqual(model.values["f"]?["t"], ModuleView.Value.text("")); XCTAssertEqual(model.values["f"]?["c"], ModuleView.Value.text("x"))
        XCTAssertEqual(model.values["f"]?["b"], ModuleView.Value.toggle(true))
        await model.perform("save", form: "f")
        XCTAssertNotNil(model.view, "a bad answer keeps the last good view"); XCTAssertNotNil(model.problem)
    }

    func testNewTextsAreTranslated() {
        for key in ["Nothing to show.", "Try again"] { XCTAssertNotNil(Language.simplifiedChinese.table?[key], key) }
    }
}

actor Answers {
    var queue: [String]
    init(_ queue: [String]) { self.queue = queue }
    func next() -> String { queue.isEmpty ? "" : queue.removeFirst() }
}
