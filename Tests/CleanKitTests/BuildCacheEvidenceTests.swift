import Darwin
import Foundation
import XCTest
@testable import CleanKit

final class BuildCacheEvidenceTests: XCTestCase {
    private var home = ""
    private let signature = "Signature: 8a477f597d28d172789f06886806bc55"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-cache-evidence-\(UUID().uuidString)").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        FS.countsStatusChanges = false
        L10n.override = .english
    }
    override func tearDownWithError() throws {
        FS.countsStatusChanges = true
        L10n.override = nil
        try FileManager.default.removeItem(atPath: home)
    }
    @discardableResult private func write(_ path: String, _ text: String) throws -> String {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86400)], ofItemAtPath: path)
        return path
    }
    private func output(_ name: String, tag: String) throws -> String {
        let project = home + "/src/" + name
        try write(project + "/package.json", "{}")
        try write(project + "/dist/release.bin", String(repeating: "x", count: 1_100_000))
        try write(project + "/dist/CACHEDIR.TAG", tag)
        return project + "/dist"
    }
    private func item(_ path: String) throws -> CleanItem {
        var options = ScanOptions(projectRoots: [home + "/src"])
        options.home = home; options.categories = [.projects]; options.discoverProjectRoots = false
        let context = ScanContext(options: options, now: Date(), processes: ProcessTable(entries: []), agentDirs: [], liveClaudeSessions: [])
        return try XCTUnwrap(Projects.scan(context).first { $0.paths == [path] })
    }

    func testInvalidSignatureCannotTurnReviewedOutputIntoPermanentCleanup() throws {
        for (index, tag) in ["", "cache", "\n" + signature, String(signature.dropLast()), signature.lowercased()].enumerated() {
            let path = try output("invalid-\(index)", tag: tag)
            let candidate = try item(path)
            XCTAssertEqual(candidate.safety, .review)
            XCTAssertNotEqual(candidate.regenerable, true)
            XCTAssertTrue(RemovalMode.auto.trashes(candidate))
        }
    }

    func testSpecialNodesAndSymlinksAreNotCacheDeclarations() throws {
        let target = try write(home + "/valid-tag", signature)
        for kind in ["directory", "symlink", "fifo"] {
            let cache = home + "/" + kind
            try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
            let tag = cache + "/CACHEDIR.TAG"
            switch kind {
            case "directory": try FileManager.default.createDirectory(atPath: tag, withIntermediateDirectories: true)
            case "symlink": try FileManager.default.createSymbolicLink(atPath: tag, withDestinationPath: target)
            default: XCTAssertEqual(mkfifo(tag, 0o600), 0)
            }
            XCTAssertFalse(Projects.isEvidentCache(cache), kind)
        }
    }

    func testValidSignatureWithOrWithoutCommentsAllowsOwnedCacheCleanup() throws {
        for (index, suffix) in ["", "\n# cache declaration\n"].enumerated() {
            let path = try output("valid-\(index)", tag: signature + suffix)
            let candidate = try item(path)
            XCTAssertEqual(candidate.regenerable, true)
            XCTAssertFalse(RemovalMode.auto.trashes(candidate))
            let result = Cleaner.clean(candidate, mode: .auto, guard: Guard(home: home), processTable: ProcessTable(entries: []))
            XCTAssertEqual(result.removed, [path])
            XCTAssertFalse(FS.exists(path))
            XCTAssertNil(result.trashBatchID)
        }
    }

    func testRevokingDeclarationAfterReviewRetainsOutput() throws {
        let path = try output("revoked", tag: signature)
        let candidate = try item(path)
        XCTAssertFalse(RemovalMode.auto.trashes(candidate))
        // Preserve old timestamps too: eligibility cannot depend only on an mtime window.
        try write(path + "/CACHEDIR.TAG", String(repeating: "x", count: signature.utf8.count))
        let result = Cleaner.clean(candidate, mode: .auto, guard: Guard(home: home), scannedAt: Date(), processTable: ProcessTable(entries: []))
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.failed[candidate.id], "Build cache evidence changed; scan and review again.")
        XCTAssertTrue(FS.exists(path + "/release.bin"))
        XCTAssertTrue(RemovalMode.trash.trashes(candidate), "An explicit recoverable action stays recoverable")
    }

    func testLegacyGenericOutputWithoutEvidenceStaysRecoverable() throws {
        var legacy = CleanItem(id: "project/legacy", category: .projects, title: "legacy · dist", safety: .safe, bytes: 1,
                               paths: [home + "/src/legacy/dist"])
        legacy.regenerable = true
        let decoded = try JSONDecoder().decode(CleanItem.self, from: JSONEncoder().encode(legacy))
        XCTAssertTrue(RemovalMode.auto.trashes(decoded))
        legacy.paths = [home + "/src/legacy/.build"]
        XCTAssertFalse(RemovalMode.auto.trashes(legacy), "Known named build output retains its existing behavior")
    }

    func testXcodeLayoutDoesNotFollowAnIntermediateDirectoryAlias() throws {
        let outside = home + "/other-build"
        try FileManager.default.createDirectory(atPath: outside + "/Intermediates.noindex", withIntermediateDirectories: true)
        let cache = home + "/aliased"
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: cache + "/Build", withDestinationPath: outside)
        XCTAssertFalse(Projects.isEvidentCache(cache))
        XCTAssertFalse(Projects.isEvidentCache(cache + "/Build/Intermediates.noindex"))
        try FileManager.default.removeItem(atPath: cache + "/Build")
        try FileManager.default.createDirectory(atPath: cache + "/Build/Intermediates.noindex", withIntermediateDirectories: true)
        XCTAssertTrue(Projects.isEvidentCache(cache))
        XCTAssertTrue(Projects.isEvidentCache(cache + "/Build/Intermediates.noindex"))
    }

    func testEveryXcodeEvidenceRejectsLinkedLeavesAndLinkedRoots() throws {
        for (index, suffix) in ["Build/Intermediates.noindex", "ModuleCache.noindex", "CompilationCache.noindex"].enumerated() {
            let real = home + "/real-\(index)"
            try FileManager.default.createDirectory(atPath: real + "/" + suffix, withIntermediateDirectories: true)
            XCTAssertTrue(Projects.isEvidentCache(real), suffix)
            let rootAlias = home + "/root-alias-\(index)"
            try FileManager.default.createSymbolicLink(atPath: rootAlias, withDestinationPath: real)
            XCTAssertFalse(Projects.isEvidentCache(rootAlias), suffix)
            XCTAssertFalse(Projects.isEvidentCache(rootAlias + "/" + suffix), suffix)

            let claimed = home + "/claimed-\(index)"
            let leaf = claimed + "/" + suffix
            try FileManager.default.createDirectory(atPath: (leaf as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: leaf, withDestinationPath: real + "/" + suffix)
            XCTAssertFalse(Projects.isEvidentCache(claimed), suffix)
            XCTAssertFalse(Projects.isEvidentCache(leaf), suffix)
            try FileManager.default.removeItem(atPath: leaf)
            try write(leaf, "not a directory")
            XCTAssertFalse(Projects.isEvidentCache(claimed), suffix)
            XCTAssertFalse(Projects.isEvidentCache(leaf), suffix)
        }
    }

    func testMixedGenericOutputOffersOnlyItsXcodeCacheChildren() throws {
        let path = try output("mixed", tag: "")
        try write(path + "/ModuleCache.noindex/module.pcm", String(repeating: "m", count: 1_100_000))
        try write(path + "/Build/Intermediates.noindex/object.o", String(repeating: "o", count: 1_100_000))
        var options = ScanOptions(projectRoots: [home + "/src"])
        options.home = home; options.categories = [.projects]; options.discoverProjectRoots = false
        let context = ScanContext(options: options, now: Date(), processes: ProcessTable(entries: []), agentDirs: [], liveClaudeSessions: [])
        let items = Projects.scan(context)
        XCTAssertFalse(items.contains { $0.paths.contains(path) })
        for child in ["ModuleCache.noindex", "Build/Intermediates.noindex"] {
            let candidate = try XCTUnwrap(items.first { $0.paths == [path + "/" + child] })
            let result = Cleaner.clean(candidate, mode: .auto, guard: Guard(home: home), processTable: ProcessTable(entries: []))
            XCTAssertEqual(result.removed, [path + "/" + child])
        }
        XCTAssertTrue(FS.exists(path + "/release.bin"))
    }
}
