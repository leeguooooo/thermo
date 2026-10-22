import XCTest
import ToolExtensionCore
@testable import ThermoApp

@MainActor final class ToolExtensionHostTests: XCTestCase {
    final class FakeModule: NativeToolExtension {
        let descriptor = ToolExtensionDescriptor(id: "test.module", title: "Test", symbol: "star", summary: "Test")
        var activations = 0, deactivations = 0, openings = 0
        func activate() { activations += 1 }
        func deactivate() { deactivations += 1 }
        func open() { openings += 1 }
    }

    func testEnablementControlsLifecycleWhileMenuPreferenceOnlyControlsEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolExtensionConfigurationStore(url: root.appendingPathComponent("settings.json"))
        let module = FakeModule()
        let host = ToolExtensionHost(store: store, modules: [module])
        XCTAssertEqual(module.activations, 0)
        host.start(); host.start()
        XCTAssertEqual(module.activations, 1)
        host.update(module.descriptor, preference: .init(enabled: true, showInMenu: false))
        XCTAssertTrue(host.menuExtensions.isEmpty)
        XCTAssertEqual(module.deactivations, 0)
        host.open(module.descriptor.id)
        XCTAssertEqual(module.openings, 1)
        host.update(module.descriptor, preference: .init(enabled: false))
        XCTAssertEqual(module.deactivations, 1)
        host.open(module.descriptor.id); host.open("unregistered.module")
        XCTAssertEqual(module.openings, 1)
        host.update(module.descriptor, preference: .init(enabled: true))
        XCTAssertEqual(module.activations, 2)
        host.shutdown(); host.shutdown()
        XCTAssertEqual(module.deactivations, 2)
        XCTAssertTrue(try store.read().preference(for: module.descriptor).enabled)
    }

    func testCorruptReloadStopsActiveModuleAndDoesNotOverwriteOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolExtensionConfigurationStore(url: root.appendingPathComponent("settings.json"))
        try store.write(.init())
        let module = FakeModule()
        let host = ToolExtensionHost(store: store, modules: [module])
        host.start()
        let corrupt = Data("{\"schemaVersion\":99,\"extensions\":{}}".utf8)
        try corrupt.write(to: store.url)
        host.reload()
        XCTAssertFalse(host.readable)
        XCTAssertFalse(host.isEnabled(module.descriptor.id))
        XCTAssertEqual(module.deactivations, 1)
        host.update(module.descriptor, preference: .init(enabled: false))
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
        try store.write(.init())
        host.reload()
        XCTAssertEqual(module.activations, 2)
        host.shutdown()
    }
}
