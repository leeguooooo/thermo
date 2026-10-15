import XCTest
@testable import CleanKit

final class WhitelistTests: XCTestCase {
    var home = ""
    var file: String { Whitelist.url(home: home).path }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home + "/Library/Application Support/Thermo", withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: home) }

    func writeList(_ text: String, mode: Int = 0o600) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: file))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file)
    }

    @discardableResult
    func touch(_ rel: String) throws -> String {
        let p = home + "/" + rel
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: p))
        return p
    }

    func testAbsentFileIsEmpty() throws {
        let w = try Whitelist.load(home: home)
        XCTAssertTrue(w.entries.isEmpty)
        XCTAssertTrue(w.rejected.isEmpty)
        XCTAssertFalse(w.protects(home + "/Library/Caches/x"))
    }

    func testParsesCommentsTildeAndRejectsBadLines() throws {
        try writeList("""
        # keep these
        ~/projects/keep

          /opt/data/
        relative/path
        ~/a/../b
        /
        /System
        /Users
        ~
        ~/*
        /*
        \(home)/ok\u{7}bell
        ~/Library/Caches/*.keep
        ~/projects/keep
        """)
        let w = try Whitelist.load(home: home)
        XCTAssertEqual(w.entries, [home + "/projects/keep", "/opt/data", home + "/Library/Caches/*.keep"])
        let reasons = Dictionary(w.rejected.map { ($0.text.trimmingCharacters(in: .whitespaces), $0.reason) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(reasons["relative/path"], "not an absolute path")
        XCTAssertEqual(reasons["~/a/../b"], "contains ..")
        XCTAssertEqual(reasons["/"], "a system root or your home folder")
        XCTAssertEqual(reasons["/System"], "a system root or your home folder")
        XCTAssertEqual(reasons["/Users"], "a system root or your home folder")
        XCTAssertEqual(reasons["~"], "a system root or your home folder")
        XCTAssertEqual(reasons["~/*"], "matches everything in a system root or your home folder")
        XCTAssertEqual(reasons["/*"], "matches everything in a system root or your home folder")
        XCTAssertEqual(reasons[home + "/ok\u{7}bell"], "contains control characters")
        XCTAssertEqual(w.rejected.first { $0.text == "relative/path" }?.line, 5)
    }

    func testFailsClosedOnSymlink() throws {
        let real = home + "/real-list"
        try Data("~/x\n".utf8).write(to: URL(fileURLWithPath: real))
        try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: real)
        XCTAssertThrowsError(try Whitelist.load(home: home))
        XCTAssertNotNil(Whitelist.refusal(home + "/anything", home: home))
    }

    func testFailsClosedOnLoosePermissionsSizeAndEncoding() throws {
        try writeList("~/x\n", mode: 0o666)
        XCTAssertThrowsError(try Whitelist.load(home: home))
        try writeList("~/x\n", mode: 0o620)
        XCTAssertThrowsError(try Whitelist.load(home: home))
        try writeList(String(repeating: "# padding\n", count: Whitelist.maxBytes / 10 + 10))
        XCTAssertThrowsError(try Whitelist.load(home: home))
        try FileManager.default.removeItem(atPath: file)
        try Data([0x7e, 0x2f, 0xff, 0xfe, 0x0a]).write(to: URL(fileURLWithPath: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        XCTAssertThrowsError(try Whitelist.load(home: home))
        try FileManager.default.removeItem(atPath: file)
        try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try Whitelist.load(home: home))
    }

    func testMatching() throws {
        try writeList("~/proj/keep\n~/Library/Caches/*.keep\n~/repos/*/build/important\n")
        let w = try Whitelist.load(home: home)
        // Exact, and everything under a whitelisted folder.
        XCTAssertTrue(w.protects(home + "/proj/keep"))
        XCTAssertTrue(w.protects(home + "/proj/keep/"))
        XCTAssertTrue(w.protects(home + "/proj/keep/deep/file"))
        // A folder holding a whitelisted path.
        XCTAssertTrue(w.protects(home + "/proj"))
        XCTAssertFalse(w.protects(home + "/proj/keeper"))
        XCTAssertFalse(w.protects(home + "/proj/other"))
        // Globs: the match, inside it, and folders that may hold a match.
        XCTAssertTrue(w.protects(home + "/Library/Caches/a.keep"))
        XCTAssertTrue(w.protects(home + "/Library/Caches/a.keep/inner"))
        XCTAssertFalse(w.protects(home + "/Library/Caches/a.tmp"))
        XCTAssertFalse(w.protects(home + "/Library/Caches/sub/a.keep"))
        XCTAssertTrue(w.protects(home + "/repos/app/build"))
        XCTAssertTrue(w.protects(home + "/repos/app"))
        XCTAssertFalse(w.protects(home + "/repos/app/build/other"))
        XCTAssertFalse(w.protects(home + "/repos/app/node_modules"))
    }

    func testSymlinkedParentIsMatched() throws {
        try FileManager.default.createDirectory(atPath: home + "/real/keep", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/alias", withDestinationPath: home + "/real")
        try writeList("~/real/keep\n")
        let w = try Whitelist.load(home: home)
        XCTAssertTrue(w.protects(home + "/alias/keep"))
    }

    func testAddRemoveRoundTripPreservesComments() throws {
        try writeList("# mine\n~/a\n\n# second\n")
        let added = try Whitelist.add([home + "/b", "~/a", "~/c/*.log"], home: home)
        XCTAssertEqual(added, [home + "/b", home + "/c/*.log"])
        var text = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertEqual(text, "# mine\n~/a\n\n# second\n~/b\n~/c/*.log\n")
        let info = try FileManager.default.attributesOfItem(atPath: file)
        XCTAssertEqual((info[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try Whitelist.remove(["~/a", home + "/missing"], home: home), [home + "/a"])
        text = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertEqual(text, "# mine\n\n# second\n~/b\n~/c/*.log\n")
        XCTAssertEqual(try Whitelist.load(home: home).entries, [home + "/b", home + "/c/*.log"])
        XCTAssertThrowsError(try Whitelist.add(["relative"], home: home))
        XCTAssertThrowsError(try Whitelist.add(["/"], home: home))
        let journal = OperationJournal.read(home: home)
        XCTAssertEqual(Set(journal.map(\.action)), ["whitelistAdd", "whitelistRemove"])
        XCTAssertEqual(journal.first { $0.action == "whitelistRemove" }?.items.map(\.target), [home + "/a"])
    }

    func testAddCreatesFileAndRefusesUntrustedOne() throws {
        try Whitelist.add(["~/x"], home: home)
        XCTAssertEqual(try Whitelist.load(home: home).entries, [home + "/x"])
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file)
        XCTAssertThrowsError(try Whitelist.add(["~/y"], home: home))
    }

    func testCleanSkipsWhitelistedPaths() throws {
        let keep = try touch("Library/Caches/tool/keep/data")
        let gone = try touch("Library/Caches/tool/old")
        try writeList("~/Library/Caches/tool/keep\n")
        let item = CleanItem(id: "t", category: .devCaches, title: "t", safety: .safe, bytes: 2,
                             paths: [home + "/Library/Caches/tool/keep", gone, home + "/Library/Caches/tool"])
        let r = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home), processTable: ProcessTable(entries: []))
        XCTAssertEqual(r.removed, [gone])
        XCTAssertEqual(r.whitelisted, [home + "/Library/Caches/tool/keep", home + "/Library/Caches/tool"])
        XCTAssertTrue(r.failed.isEmpty)
        XCTAssertTrue(FS.exists(keep))
        XCTAssertFalse(FS.exists(gone))
    }

    func testCleanRefusesEverythingWhenWhitelistIsUnreadable() throws {
        let gone = try touch("Library/Caches/tool/old")
        try writeList("~/x\n", mode: 0o666)
        let item = CleanItem(id: "t", category: .devCaches, title: "t", safety: .safe, bytes: 1, paths: [gone])
        let r = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home), processTable: ProcessTable(entries: []))
        XCTAssertTrue(r.removed.isEmpty)
        XCTAssertNotNil(r.failed["t"])
        XCTAssertTrue(FS.exists(gone))
    }

    func testManualRemovalSkipsWhitelistedPaths() throws {
        let keep = try touch("Downloads/keep.dmg")
        try writeList("~/Downloads/keep.dmg\n")
        XCTAssertNotNil(ManualRemoval.refusal(keep, home: home))
        let r = ManualRemoval.trash([keep], home: home)
        XCTAssertEqual(r.whitelisted, [keep])
        XCTAssertTrue(r.removed.isEmpty)
        XCTAssertTrue(FS.exists(keep))
    }

    func testApplyMarksItems() throws {
        try writeList("~/s/b\n")
        let w = try Whitelist.load(home: home)
        let parts = [CleanPart(id: "a", title: "a", bytes: 10, lastUsed: nil, paths: [home + "/s/a"]),
                     CleanPart(id: "b", title: "b", bytes: 30, lastUsed: nil, paths: [home + "/s/b"])]
        let partial = w.apply(CleanItem(id: "x", category: .aiSessions, title: "x", safety: .review, bytes: 40,
                                        paths: [home + "/s/a", home + "/s/b"], parts: parts))
        XCTAssertEqual(partial.paths, [home + "/s/a"])
        XCTAssertEqual(partial.parts?.map(\.id), ["a"])
        XCTAssertEqual(partial.bytes, 10)
        XCTAssertEqual(partial.whitelisted, [home + "/s/b"])
        XCTAssertNil(partial.blocked)
        let full = w.apply(CleanItem(id: "y", category: .system, title: "y", safety: .safe, bytes: 5, paths: [home + "/s/b/c"]))
        XCTAssertEqual(full.paths, [home + "/s/b/c"])
        XCTAssertEqual(full.blocked, tr(Whitelist.reason))
        XCTAssertFalse(full.cleanable)

        var report = ScanReport(items: [full], denied: [], started: Date(), duration: 0)
        try writeList("~/x\n", mode: 0o666)
        report.items = [CleanItem(id: "z", category: .system, title: "z", safety: .safe, bytes: 5, paths: [home + "/z"])]
        report.applyWhitelist(home: home)
        XCTAssertNotNil(report.whitelistError)
        XCTAssertFalse(report.items[0].cleanable)
        let decoded = try JSONDecoder().decode(ScanReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.whitelistError, report.whitelistError)
    }
}
