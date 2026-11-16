import AppKit
import ModuleKit
import WasmHost
import XCTest
@testable import ModuleDevKit
@testable import ModuleDevTesting

final class ModuleDevTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-dev-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// Stands in for thermo-wat2wasm: keeps the expanded text, returns a minimal module header.
    final class Compiler: @unchecked Sendable { var last = "" }
    func builder(_ compiler: Compiler) -> ModuleBuilder {
        ModuleBuilder { wat in compiler.last = wat; return Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]) }
    }
    static var examples: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("examples") }

    func testNewModuleIsValidAndBuildsIntoTheLayoutTheAppLoads() throws {
        let folder = try ModuleTemplate.create(id: "com.example.hello", in: root)
        let source = ModuleSource(folder)
        XCTAssertEqual(try source.manifest().id, "com.example.hello")
        XCTAssertEqual(try source.strings().map(\.name), ["view_main", "view_menu", "str_scene_menu"])
        let compiler = Compiler()
        let output = try builder(compiler).build(source)
        XCTAssertEqual(output.folder, source.outputRoot.appendingPathComponent("com.example.hello"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.folder.appendingPathComponent("module.wasm").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.folder.appendingPathComponent("module.json").path))
        for name in ["$view_main", "$view_main_len", "$str_scene_menu", "$heap_base", "(memory (export \"memory\")"] {
            XCTAssertTrue(compiler.last.contains(name), name)
        }
        XCTAssertFalse(compiler.last.contains(WatExpansion.marker))
        // The template's fixtures name only what its views show.
        let fixtures = try FixtureRunner.fixtures(source)
        XCTAssertEqual(fixtures.map(\.name), ["main", "menu", "refresh"])
        XCTAssertThrowsError(try ModuleTemplate.create(id: "com.example.hello", in: root), "an existing folder is never overwritten")
        XCTAssertThrowsError(try ModuleTemplate.create(id: "not an id", in: root))
    }

    func testRebuildAfterRenamingLeavesOnlyTheNewModule() throws {
        let source = ModuleSource(try ModuleTemplate.create(id: "com.example.first", in: root))
        _ = try builder(Compiler()).build(source)
        var manifest = try source.manifest(); manifest.id = "com.example.second"
        try JSONEncoder().encode(manifest).write(to: source.manifestURL)
        _ = try builder(Compiler()).build(source)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.outputRoot.path), ["com.example.second"])
    }

    func testExpansionEscapesBytesAndPlacesTheHeapAfterTheStrings() throws {
        let strings: [(name: String, bytes: Data)] = [("str_a", Data("a\"b\\c\n".utf8)), ("str_b", Data("探".utf8))]
        let wat = try WatExpansion.expand("(module\n  \(WatExpansion.marker)\n)", strings: strings, heapPages: 1)
        XCTAssertTrue(wat.contains(#"(data (i32.const 1024) "a\22b\5cc\0a")"#))
        XCTAssertTrue(wat.contains(#"(data (i32.const 1030) "\e6\8e\a2")"#))
        XCTAssertTrue(wat.contains("(global $str_b_len i32 (i32.const 3))"))
        XCTAssertTrue(wat.contains("(global $heap_base i32 (i32.const 1040))"))
        XCTAssertTrue(wat.contains("(memory (export \"memory\") 2)"))
        XCTAssertThrowsError(try WatExpansion.expand("(module)", strings: []))
        XCTAssertThrowsError(try WatExpansion.expand("\(WatExpansion.marker)\n\(WatExpansion.marker)", strings: []))
    }

    func testViewsAreCheckedAtBuildTime() throws {
        let source = ModuleSource(try ModuleTemplate.create(id: "com.example.views", in: root))
        let main = source.viewsURL.appendingPathComponent("main.json")
        try Data("{not json".utf8).write(to: main)
        XCTAssertThrowsError(try builder(Compiler()).build(source)) { XCTAssertTrue("\($0)".contains("main.json is not JSON")) }
        try Data(#"{"version":1,"sections":[{"type":"html","id":"x"}]}"#.utf8).write(to: main)
        XCTAssertThrowsError(try builder(Compiler()).build(source)) { XCTAssertTrue("\($0)".contains("not a valid module view")) }
        // A {{n}} hole the module fills in at run time is fine.
        try Data(#"{"version":1,"sections":[{"type":"card","title":"N","value":"{{n}}"}]}"#.utf8).write(to: main)
        XCTAssertNoThrow(try builder(Compiler()).build(source))
        try Data("x".utf8).write(to: source.stringsURL.appendingPathComponent("bad name.txt"))
        XCTAssertThrowsError(try builder(Compiler()).build(source))
    }

    func testRunPointsTheAppAtTheBuildAndReloadsOnlyAfterASuccessfulBuild() throws {
        let source = ModuleSource(try ModuleTemplate.create(id: "com.example.reload", in: root))
        final class Seen: @unchecked Sendable { var pointed: [(URL, String)] = []; var posts = 0 }
        let seen = Seen()
        let session = DevSession(source: source, builder: builder(Compiler()),
                                 target: .init(point: { seen.pointed.append(($0, $1)) }, post: { seen.posts += 1 }))
        guard case .success = session.rebuild() else { return XCTFail("template must build") }
        XCTAssertEqual(seen.pointed.first?.0, source.outputRoot); XCTAssertEqual(seen.pointed.first?.1, "com.example.reload"); XCTAssertEqual(seen.posts, 1)
        let watcher = FolderWatcher(source)
        XCTAssertFalse(watcher.changed())
        let view = source.viewsURL.appendingPathComponent("main.json")
        try Data("{broken".utf8).write(to: view)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: view.path)
        XCTAssertTrue(watcher.changed()); XCTAssertFalse(watcher.changed())
        guard case .failure = session.rebuild() else { return XCTFail("a broken view must not build") }
        XCTAssertEqual(seen.posts, 1, "a failed build keeps the last good module loaded")
    }

    func testExampleModuleIsValid() throws {
        let source = ModuleSource(Self.examples.appendingPathComponent("process-count"))
        let manifest = try source.manifest()
        XCTAssertEqual(manifest.capabilities, [Capability(.processesRead)])
        XCTAssertEqual(try source.strings().count, 8)
        let compiler = Compiler()
        _ = try builder(compiler).build(source)
        try? FileManager.default.removeItem(at: source.outputRoot)
        XCTAssertEqual(try FixtureRunner.fixtures(source).map(\.name), ["main", "menu", "refresh", "refused"])
    }

    func testFixtureAnswersStandInForTheMacAndExpectationsAreChecked() async throws {
        let manifest = ModuleManifest(id: "com.example.fixture", name: "F", summary: "", symbol: "cube", version: "1.0.0",
                                      capabilities: [Capability(.processesRead)], entries: [.init(id: "main", kind: .page, title: "F", scene: "main")])
        let handlers = try FixtureRunner.handlers(["processes.read": .object(["processes": .array([])]), "files.read": .string("denied")])
        let broker = CapabilityBroker(manifest: manifest, home: root.path, log: ModuleAccessLog(home: root.path), handlers: handlers)
        if case .success(let data) = await broker.request("processes.read", payload: Data(#"{"op":"list"}"#.utf8)) {
            XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"processes":[]}"#)
        } else { XCTFail("declared capability gets the fixture's answer") }
        if case .success = await broker.request("files.read:/tmp", payload: Data()) { XCTFail("undeclared capability stays refused") }
        XCTAssertThrowsError(try FixtureRunner.handlers(["no.such": .null]))

        let view = Data(#"{"version":1,"title":"F","sections":[{"type":"card","title":"Count","value":"3"}]}"#.utf8)
        let module = DeclarativeModule(manifest: manifest) { _, _ in WasmHost.Result(status: 0, output: view) }
        let fixture = ModuleFixture(scene: "main", expect: ["Count", "\"value\":\"3\""])
        let ok = await FixtureRunner.run("main", fixture, module: module)
        XCTAssertTrue(ok.passed, "\(ok.problems)")
        var missing = fixture; missing.expect = ["Absent"]
        let failed = await FixtureRunner.run("main", missing, module: module)
        XCTAssertEqual(failed.problems, ["expected text not shown: Absent"])
        let broken = DeclarativeModule(manifest: manifest) { _, _ in WasmHost.Result(status: 0, output: Data(#"{"version":1,"sections":[{"type":"html"}]}"#.utf8)) }
        let refused = await FixtureRunner.run("main", fixture, module: broken)
        XCTAssertFalse(refused.passed); XCTAssertNil(refused.view)
    }

    func testSnapshotsAreWrittenComparedWithToleranceAndReportedWhenTheyDiffer() throws {
        func png(_ value: CGFloat, size: Int = 20) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for x in 0..<size { for y in 0..<size { rep.setColor(NSColor(deviceRed: value, green: value, blue: value, alpha: 1), atX: x, y: y) } }
            return rep.representation(using: .png, properties: [:])!
        }
        let reference = root.appendingPathComponent("main.png")
        XCTAssertEqual(SnapshotCheck.compare(png(0.2), reference: reference, update: false), .written)
        XCTAssertEqual(SnapshotCheck.compare(png(0.21), reference: reference, update: false), .matches, "a slight antialiasing shift passes")
        guard case .differs = SnapshotCheck.compare(png(0.8), reference: reference, update: false) else { return XCTFail("a real change fails") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("main.actual.png").path))
        guard case .differs = SnapshotCheck.compare(png(0.2, size: 30), reference: reference, update: false) else { return XCTFail("size change fails") }
        XCTAssertEqual(SnapshotCheck.compare(png(0.8), reference: reference, update: true), .written)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("main.actual.png").path))
    }

    func testToolsAreFoundInTheAppBundleLayout() throws {
        let app = root.appendingPathComponent("Thermo.app/Contents")
        for path in ["MacOS/Thermo", "Helpers/thermo", "Helpers/thermo-wat2wasm"] {
            let url = app.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let cli = app.appendingPathComponent("Helpers/thermo"), main = app.appendingPathComponent("MacOS/Thermo")
        XCTAssertEqual(DevTools.locate("thermo-wat2wasm", environment: "X", env: [:], executable: cli)?.standardizedFileURL, app.appendingPathComponent("Helpers/thermo-wat2wasm").standardizedFileURL)
        XCTAssertEqual(DevTools.locate("thermo-wat2wasm", environment: "X", env: [:], executable: main)?.standardizedFileURL, app.appendingPathComponent("Helpers/thermo-wat2wasm").standardizedFileURL)
        XCTAssertEqual(DevTools.appExecutable(env: [:], executable: cli)?.standardizedFileURL, main.standardizedFileURL)
    }
}
