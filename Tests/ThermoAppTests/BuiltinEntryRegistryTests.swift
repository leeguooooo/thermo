import AppKit
import CleanKit
import ModuleHost
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n
import XCTest
@testable import ThermoApp

@MainActor final class BuiltinEntryRegistryTests: XCTestCase {
    private final class Session:NativeFeatureSession {
        func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?{AnyView(EmptyView())}
        var status:NativeFeatureStatus{.init()}
        func retireVisibility(){}
        func quitBlocker()->NativeFeatureBlocker?{nil}
        func prepareStop()throws->NativeFeatureDrain{.init{}}
    }
    func settings() -> (UserDefaults, String) {
        let name = "thermo-entry-tests-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    func testEveryDeclaredEntryHasAnImplementationAndCorePagesStayCore() {
        XCTAssertTrue(NativeModules.problems.isEmpty, NativeModules.problems.joined(separator: "\n"))
        XCTAssertEqual(Set(NativeModules.all.map(\.id)), Set(BuiltinModuleManifests.all.map(\.id)))
        XCTAssertTrue(ModuleNavigation.conflicts(NativeModules.all).isEmpty)
        for entry in HostPageSpecification.pages {
            let page = MainPage(argument: entry.argument)
            XCTAssertNotNil(page, entry.argument)
            XCTAssertNil(page?.module, "A migrated page must leave the core navigation list")
        }
    }
    func testDiskRoutesCoverEveryCategoryAndKeepLegacyAndGenericArguments() {
        let expected = Set([MainPage.native(.init(BuiltinModuleManifests.disk.id, "scan")), .native(.init(BuiltinModuleManifests.disk.id, "overview"))] + CleanCategory.allCases.map { .native(.init(BuiltinModuleManifests.disk.id, $0.rawValue)) })
        let entries = BuiltinModuleManifests.disk.entries.filter { $0.kind == .page }
        XCTAssertEqual(Set(entries.compactMap { $0.scene.flatMap(MainPage.init(argument:)) }), expected)
        for entry in entries {
            XCTAssertEqual(MainPage(argument:entry.scene!),.native(.init(BuiltinModuleManifests.disk.id,entry.id)))
            let generic = MainPage.module(BuiltinModuleManifests.disk.id, entry.id)
            XCTAssertEqual(NativeModules.page(generic)?.target, MainPage(argument:entry.scene!))
        }
        XCTAssertEqual(MainPage(argument: "disk:home"), .native(.init(BuiltinModuleManifests.disk.id, "scan")))
        XCTAssertEqual(NativeModules.page(.module(BuiltinModuleManifests.disk.id, ""))?.target, .native(.init(BuiltinModuleManifests.disk.id, "scan")))
        XCTAssertNil(MainPage(argument: "disk:not-declared"))
        XCTAssertEqual(BuiltinModuleManifests.disk.entries.filter { $0.kind == .settingsItem }.count, 1)
    }

    func testDisabledSnapshotAndNavigationDoNotCreateAModel() {
        let (defaults, name) = settings(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: ModuleCenter.key(BuiltinModuleManifests.disk.id))
        let center = ModuleCenter(defaults: defaults)
        var made = 0
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.disk,makeSession:{_ in made+=1;return Session()})
        let models=AppModels(defaults:defaults,nativeDefinitions:[definition])
        XCTAssertEqual(NativeModules.snapshotReady(.module(BuiltinModuleManifests.disk.id, "scan"), arguments: ["--disk"], models: models, center: center), true)
        XCTAssertFalse(center.rootPages.contains { $0.module.id == BuiltinModuleManifests.disk.id })
        XCTAssertTrue(center.rootPages.contains { $0.module.id == BuiltinModuleManifests.performance.id })
        XCTAssertNil(center.legacyMenuPage("smartScan"))
        XCTAssertNil(center.navigationKey(.module(BuiltinModuleManifests.disk.id, "scan")))
        XCTAssertFalse(models.nativeFeatures.status(BuiltinModuleManifests.disk.id).modelLoaded)
        XCTAssertEqual(made, 0)
    }
    func testViewMenuAndLegacySlotUseDeclaredDestinationAndReleaseCommandFive() throws {
        _ = NSApplication.shared
        let oldMenu = NSApp.mainMenu; NSApp.mainMenu = NSMenu(); defer { NSApp.mainMenu = oldMenu }
        let language = L10n.override; L10n.override = .english; defer { L10n.override = language }
        let (defaults, name) = settings(); defer { defaults.removePersistentDomain(forName: name) }
        let center = ModuleCenter(defaults: defaults, prepareBuiltinStop: { _ in nil }, updatesAppMenu: true)
        installStandardMenus(center: center)
        func menu() throws -> NSMenu { try XCTUnwrap(NSApp.mainMenu?.items.first { $0.identifier?.rawValue == "thermo.view" }?.submenu) }
        let five = try XCTUnwrap(menu().items.first { $0.keyEquivalent == "5" })
        XCTAssertEqual(five.title, BuiltinModuleManifests.disk.name)
        XCTAssertEqual(five.representedObject as? MainPage, .native(.init(BuiltinModuleManifests.disk.id, "scan")))
        XCTAssertEqual(center.legacyMenuPage("smartScan")?.title, "Smart Scan")
        center.setEnabled(BuiltinModuleManifests.disk.id, false)
        XCTAssertNil(try menu().items.first { $0.keyEquivalent == "5" })
        XCTAssertNil(center.legacyMenuPage("smartScan"))
    }
    func testShortcutConflictDoesNotHideThePageAndDisablingOwnerReleasesKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-entry-module-" + UUID().uuidString)
        let contents = root.appendingPathComponent("Thermo.app/Contents/Extensions/Fixture.appex/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = ModuleManifest(id: "com.example.navigation", name: "Navigation fixture", summary: "Never launched", symbol: "folder", version: "1.0.0", enabledByDefault: true,
            entries: [.init(id: "home", kind: .page, title: "Home", scene: "main", navigationKey: "5"),
                      .init(id: "child", kind: .page, title: "Child", scene: "child", parent: "home"),
                      .init(id: "settings", kind: .settingsItem, title: "Settings", scene: "preferences")])
        try JSONEncoder().encode(manifest).write(to: contents.appendingPathComponent("Resources/module.json"))
        let plist: [String: Any] = ["CFBundleIdentifier": manifest.id, "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": ModuleBundles.extensionPoint]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let (defaults, name) = settings(); defer { defaults.removePersistentDomain(forName: name) }
        let center = ModuleCenter(manager: ModuleManager(app: root.appendingPathComponent("Thermo.app")), defaults: defaults, prepareBuiltinStop: { _ in nil })
        center.start()
        for _ in 0..<400 where !center.loaded { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(center.loaded)
        let page = MainPage.module(manifest.id, "home")
        XCTAssertTrue(center.isOn(manifest.id))
        XCTAssertNotNil(center.page(module: manifest.id, entry: "home"))
        XCTAssertNil(center.navigationKey(page))
        XCTAssertNotNil(center.navigationIssue(manifest.id))
        XCTAssertNil(center.statuses.first?.pid)
        center.setEnabled(BuiltinModuleManifests.disk.id, false)
        XCTAssertEqual(center.navigationKey(page), "5")
        XCTAssertNil(center.navigationIssue(manifest.id))
        center.setEnabled(manifest.id, false)
        XCTAssertTrue(center.pageGroups.isEmpty)
        XCTAssertNil(center.navigationKey(page))
    }
}
