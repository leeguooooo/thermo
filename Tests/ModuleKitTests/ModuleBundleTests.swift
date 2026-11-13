import XCTest
@testable import ModuleKit

final class ModuleBundleTests: XCTestCase {
    var app: URL!
    override func setUpWithError() throws {
        app = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-modules-" + UUID().uuidString + "/Thermo.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Extensions"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

    func add(_ name: String, id: String, bundleID: String? = nil, point: String = ModuleBundles.extensionPoint, manifest: Bool = true, interface: Int = 1) throws {
        let contents = app.appendingPathComponent("Contents/Extensions/\(name).appex/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID ?? id, "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": point]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        guard manifest else { return }
        let module = ModuleManifest(interface: interface, id: id, name: "Disk", summary: "Cleans.", symbol: "internaldrive", version: "1.0.0")
        try JSONEncoder().encode(module).write(to: contents.appendingPathComponent("Resources/module.json"))
    }

    func testOnlyWellFormedModulesInsideTheAppAreListed() throws {
        try add("Disk", id: "dev.thermo.disk")
        try add("Search", id: "dev.thermo.search")
        try add("Renamed", id: "dev.thermo.capture", bundleID: "dev.thermo.other")
        try add("Elsewhere", id: "dev.thermo.fans", point: "com.example.point")
        try add("Empty", id: "dev.thermo.empty", manifest: false)
        try add("Future", id: "dev.thermo.future", interface: ModuleManifest.currentInterface + 1)
        try add("Twin", id: "dev.thermo.disk")
        // Not a module bundle: ignored without a word.
        try Data().write(to: app.appendingPathComponent("Contents/Extensions/dev.thermo.module.appextensionpoint"))

        let found = ModuleBundles.installed(in: app)
        XCTAssertEqual(found.modules.map(\.manifest.id), ["dev.thermo.disk", "dev.thermo.search"])
        XCTAssertEqual(found.problems.count, 5, "\(found.problems)")
        let text = found.problems.joined(separator: "\n")
        XCTAssertTrue(text.contains("Renamed.appex: bundle id dev.thermo.other differs from manifest id dev.thermo.capture"), text)
        XCTAssertTrue(text.contains("Elsewhere.appex: extension point com.example.point is not dev.thermo.module"), text)
        XCTAssertTrue(text.contains("Empty.appex: no Contents/Resources/module.json"), text)
        XCTAssertTrue(text.contains("Future.appex: interface 2 is not supported"), text)
        XCTAssertTrue(text.contains("Twin.appex: id dev.thermo.disk is used by another module"), text)
    }

    func testAnAppWithoutModulesHasNoneAndNoProblems() {
        let found = ModuleBundles.installed(in: app.deletingLastPathComponent().appendingPathComponent("Missing.app"))
        XCTAssertTrue(found.modules.isEmpty && found.problems.isEmpty)
    }
}
