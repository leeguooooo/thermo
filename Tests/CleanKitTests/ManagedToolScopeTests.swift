@testable import CleanKit
import AgentCore
import Foundation
import XCTest

final class ManagedToolScopeTests: XCTestCase {
    var home = ""
    var cache: String { home + "/cache" }
    var marker: String { home + "/ran" }
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func whitelist(_ entry: String?) throws {
        let path = Whitelist.url(home: home)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((entry.map { $0 + "\n" } ?? "").utf8).write(to: path)
    }
    func goItem(scope: Bool = true) throws -> CleanItem {
        let tool = home + "/go"
        let script = "#!/bin/sh\nif [ \"$1\" = env ]; then printf '%s\\n' \"$GOMODCACHE\"; exit 0; fi\n/usr/bin/touch " + Shell.quote(marker) + "\n"
        try Data(script.utf8).write(to: URL(fileURLWithPath: tool))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        return .init(id: "go-mod-cache", category: .devCaches, title: "fixture", safety: .review, bytes: 1,
                     commands: [["GOTOOLCHAIN=local", "GOMODCACHE=" + cache, tool, "clean", "-modcache"]], commandScope: scope ? [cache] : nil)
    }
    func testProtectedGoCacheNeverInvokesCleanupCommand() throws {
        let item = try goItem(); try whitelist(cache + "/keep")
        let result = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home), processTable: .init(entries: []))
        XCTAssertFalse(FS.exists(marker)); XCTAssertTrue(result.removed.isEmpty); XCTAssertNotNil(result.failed[item.id])
        XCTAssertFalse(try Whitelist.loadForRemoval(home: home).apply(item).cleanable)
    }
    func testUnrelatedProtectionDoesNotDisableVerifiedGoCleanup() throws {
        let item = try goItem(); try whitelist(home + "/unrelated")
        let result = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home), processTable: .init(entries: []))
        XCTAssertTrue(FS.exists(marker)); XCTAssertTrue(result.failed.isEmpty)
    }
    func testLegacyMissingScopeRequiresRescanWithoutRunningTool() throws {
        let item = try goItem(scope: false); try whitelist(nil)
        let result = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home), processTable: .init(entries: []))
        XCTAssertFalse(FS.exists(marker)); XCTAssertNotNil(result.failed[item.id])
    }
    func testUnknownProcessInventoryAndNodeWrappedPnpmCannotBypassLiveGuard() throws {
        let item = try goItem()
        let result = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home), processTable: .init(entries: [], available: false))
        XCTAssertFalse(FS.exists(marker)); XCTAssertNotNil(result.failed[item.id])
        let pnpm = CleanItem(id: "pnpm-store-prune", category: .devCaches, title: "fixture", safety: .safe)
        XCTAssertNotNil(ManagedToolScope.runningRefusal(pnpm, processes: .init(entries: [.init(pid: 123, name: "node", executable: "/fixture/node", argv: ["node", "/fixture/pnpm.cjs", "install"])])))
        XCTAssertNil(ManagedToolScope.runningRefusal(pnpm, processes: .init(entries: [.init(pid: 123, name: "node", argv: ["node", "/fixture/main.js", "pnpm"])])))
    }
    func testReportedGoCacheCannotDriftFromTheBoundCache() throws {
        let item = try goItem(), list = Whitelist(file: "/fixture")
        XCTAssertNotNil(ManagedToolScope.refusal(item, whitelist: list, home: home, run: { _ in (0, self.home + "/different") }))
    }
    func brewCommand() -> [String] {
        ["HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_AUTOREMOVE=1", "HOMEBREW_CACHE=" + cache,
         "HOMEBREW_LOGS=" + home + "/logs", "/fixture/brew", "cleanup", "--prune=30"]
    }
    func brewRun(_ command: [String]) -> (Int32, String) {
        switch command.last {
        case "--prefix": return (0, home + "/brew")
        case "--cellar": return (0, home + "/brew/Cellar")
        case "--repository": return (0, home + "/brew-repository")
        case "--cache": return (0, cache)
        default: return (1, "unavailable")
        }
    }
    func testBrewRequiresAutoremoveDisabledAndIncludesAuxiliaryLocations() throws {
        let command = brewCommand(), scope = try XCTUnwrap(ManagedToolScope.scope(command, id: "homebrew-old-versions", home: home, run: brewRun))
        XCTAssertTrue(scope.contains(home + "/logs")); XCTAssertTrue(scope.contains(home + "/brew-repository"))
        XCTAssertNil(ManagedToolScope.scope(command.filter { $0 != "HOMEBREW_NO_AUTOREMOVE=1" }, id: "homebrew-old-versions", home: home, run: brewRun))
        let item = CleanItem(id: "homebrew-old-versions", category: .devCaches, title: "fixture", safety: .safe, bytes: 1, commands: [command], commandScope: scope)
        XCTAssertNotNil(ManagedToolScope.refusal(item, whitelist: Whitelist(file: "/fixture", entries: [home + "/logs/keep"]), home: home, run: brewRun))
    }
    func pnpmCommand() -> [String] {
        ["PNPM_HOME=" + home + "/pnpm-home", "/fixture/pnpm", "--config.store-dir=" + cache,
         "--config.cache-dir=" + home + "/pnpm-cache", "--config.global-dir=" + home + "/global", "--config.state-dir=" + home + "/pnpm-state", "store", "prune"]
    }
    func pnpmRun(_ command: [String]) -> (Int32, String) {
        if command.last == "--version" { return (0, "12.11.2") }
        if Array(command.suffix(2)) == ["store", "path"] { return (0, cache + "/v10") }
        switch command.last {
        case "pnpm-home-dir": return (0, "undefined")
        case "store-dir": return (0, cache)
        case "state-dir": return (0, home + "/pnpm-state")
        case "cache-dir": return (0, home + "/pnpm-cache")
        case "global-dir": return (0, home + "/global")
        default: return (1, "unavailable")
        }
    }
    func testPnpmProtectsAuxiliaryCacheAndRejectsUnknownMachineRoots() throws {
        let command = pnpmCommand(), scope = try XCTUnwrap(ManagedToolScope.scope(command, id: "pnpm-store-prune", home: home, run: pnpmRun))
        let item = CleanItem(id: "pnpm-store-prune", category: .devCaches, title: "fixture", safety: .safe, bytes: 1, commands: [command], commandScope: scope)
        XCTAssertNotNil(ManagedToolScope.refusal(item, whitelist: Whitelist(file: "/fixture", entries: [home + "/pnpm-cache/dlx/keep"]), home: home, run: pnpmRun))
        XCTAssertNil(ManagedToolScope.refusal(item, whitelist: Whitelist(file: "/fixture", entries: [home + "/unrelated"]), home: home, run: pnpmRun))
        XCTAssertNil(ManagedToolScope.scope(command, id: item.id, home: home, run: { cmd in cmd.last == "state-dir" ? (0, "undefined") : self.pnpmRun(cmd) }))
    }
    func testPnpm10GetterOmissionUsesPinnedOptionsAndVerifiedStore() {
        let scope = ManagedToolScope.scope(pnpmCommand(), id: "pnpm-store-prune", home: home, run: { cmd in
            if cmd.last == "--version" { return (0, "10.28.1") }
            if Array(cmd.suffix(2)) == ["store", "path"] { return (0, self.cache + "/v10") }
            return (0, "undefined")
        })
        XCTAssertNotNil(scope)
    }
    func testMissingStoreVersionUsesTheSameSystemAliasSpellingAsItsParent() {
        let equivalent = cache.hasPrefix("/var/") ? "/private" + cache : cache
        let scope = ManagedToolScope.scope(pnpmCommand(), id: "pnpm-store-prune", home: home, run: { cmd in
            if Array(cmd.suffix(2)) == ["store", "path"] { return (0, equivalent + "/missing/v11") }
            return self.pnpmRun(cmd)
        })
        XCTAssertNotNil(scope)
    }
    func testWhitelistSystemAliasStillProtectsMissingChildrenOfAnExistingScope() {
        let equivalent = cache.hasPrefix("/var/") ? "/private" + cache : cache
        let whitelist = Whitelist(file: "/fixture", entries: [equivalent + "/not-created/keep"])
        XCTAssertTrue(whitelist.protects(cache))
        XCTAssertTrue(Whitelist(file: "/fixture", entries: [cache + "/not-created/keep"]).protects(equivalent))
    }
    func testLegacyJSONAndScopePreviewDoNotTreatBoundariesAsDeletionPaths() throws {
        let item = try goItem()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]); json.removeValue(forKey: "commandScope")
        let legacy = try JSONDecoder().decode(CleanItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.commandScope); XCTAssertTrue(item.paths.isEmpty)
        XCTAssertFalse(Whitelist(file: "/fixture").apply(legacy).cleanable)
    }
    func testAbsentAuxiliaryCacheIsZeroWhileStructuralReadFailureIsUnknown() throws {
        let missing = FS.commandSize([home + "/not-created"])
        XCTAssertEqual(missing.bytes, 0); XCTAssertFalse(missing.incomplete)
        let parent = home + "/file"; try Data("own".utf8).write(to: URL(fileURLWithPath: parent))
        XCTAssertTrue(FS.commandSize([parent + "/child"]).incomplete)
    }
    func testReadOnlyPathProbePreservesSignificantTrailingSpace() throws {
        let spaced = home + "/cache "
        try FileManager.default.createDirectory(atPath: spaced, withIntermediateDirectories: true)
        let result = ManagedToolScope.read(["/usr/bin/printf", "%s\n", spaced])
        XCTAssertEqual(result.0, 0)
        XCTAssertEqual(ManagedToolScope.path(result.1, home: home), spaced)
        XCTAssertNil(ManagedToolScope.path(spaced + "\n/another\n", home: home))
    }
    func testUnsafeRootsAndNonfiniteVendorSizesAreRejected() {
        XCTAssertNil(ManagedToolScope.root(home, home: home)); XCTAssertNil(ManagedToolScope.root("/", home: home))
        XCTAssertNil(ManagedToolScope.root(home + "/.ssh", home: home))
        for value in ["nanMB", "infGB", "-3GB", "1e99TB"] { XCTAssertEqual(ToolCleanup.parseSize(value), 0) }
    }
}
