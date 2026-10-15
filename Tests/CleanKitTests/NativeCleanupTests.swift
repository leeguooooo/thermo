import AgentCore
import Darwin
import XCTest
@testable import CleanKit

/// Tools' own clean commands. Every program here is a fake script in a temp folder; real npm, pip,
/// uv, go or brew never run.
final class NativeCleanupTests: XCTestCase {
    var home = ""
    var bin = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-native-" + UUID().uuidString).resolvingSymlinksInPath().path
        bin = home + "/fake-bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        NativeCleanup.searchOverride = nil
        try? FileManager.default.removeItem(atPath: home)
    }

    func file(_ path: String, bytes: Int = 64 * 1024) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 37, count: bytes).write(to: URL(fileURLWithPath: path))
    }
    @discardableResult
    func script(_ name: String, _ body: String, in dir: String? = nil, executable: Bool = true) throws -> String {
        let p = (dir ?? bin) + "/" + name
        try FileManager.default.createDirectory(atPath: dir ?? bin, withIntermediateDirectories: true)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: URL(fileURLWithPath: p))
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: p)
        return p
    }
    var npmCache: String { home + "/.npm/_cacache" }
    var npmLogs: String { home + "/.npm/_logs" }

    /// The npm rule's item as a scan makes it: the cache and the logs, with the command attached.
    func npmItem(dirs: [String]? = nil) throws -> CleanItem {
        try file(npmCache + "/content-v2/sha512/aa/blob")
        try file(npmCache + "/index-v5/00/entry", bytes: 8 * 1024)
        try file(npmLogs + "/debug.log", bytes: 16 * 1024)
        let paths = [npmCache, npmLogs]
        let item = CleanItem(id: "npm-cache", category: .devCaches, title: "npm cache", safety: .safe,
                             bytes: FS.size(paths).bytes, paths: paths)
        return NativeCleanup.attach(item, home: home, dirs: dirs ?? [bin])
    }

    func clean(_ item: CleanItem, mode: RemovalMode = .auto, ops: RemovalOperations? = nil) -> CleanResult {
        var o = ops ?? .live
        if ops == nil { o.trash = { _ in throw NSError(domain: "test", code: 1) } }
        return Cleaner.clean(item, mode: mode, guard: Guard(home: home), scannedAt: nil,
                             processTable: ProcessTable(entries: []), batchID: nil, operations: o)
    }

    /// Fails the test if any command would run.
    var noCommands: RemovalOperations {
        var o = RemovalOperations.live
        o.run = { argv, _ in XCTFail("ran \(argv)"); return (0, "") }
        return o
    }

    // MARK: Finding the tool

    func testResolverTakesFirstExecutableInTheFixedListOnly() throws {
        let first = home + "/first", second = home + "/second"
        try script("npm", "exit 0", in: first, executable: false)
        let real = try script("npm", "exit 0", in: second)
        XCTAssertEqual(NativeCleanup.resolve(["npm"], in: [first, second]), real)
        XCTAssertNil(NativeCleanup.resolve(["npm"], in: [first]))
        XCTAssertNil(NativeCleanup.resolve(["pnpm"], in: [first, second]))
        // pip3 before pip.
        let pip = try script("pip", "exit 0", in: first)
        XCTAssertEqual(NativeCleanup.resolve(["pip3", "pip"], in: [first]), pip)
    }

    func testNvmDefaultIsReadFromDiskWithoutAShell() throws {
        for v in ["v18.20.1", "v20.11.0", "v22.3.0"] {
            try FileManager.default.createDirectory(atPath: home + "/.nvm/versions/node/\(v)/bin", withIntermediateDirectories: true)
        }
        try file(home + "/.nvm/alias/default", bytes: 0)
        try Data("20\n".utf8).write(to: URL(fileURLWithPath: home + "/.nvm/alias/default"))
        XCTAssertEqual(NativeCleanup.nvmDefault(home: home), home + "/.nvm/versions/node/v20.11.0/bin")
        try Data("lts/*".utf8).write(to: URL(fileURLWithPath: home + "/.nvm/alias/default"))
        XCTAssertEqual(NativeCleanup.nvmDefault(home: home), home + "/.nvm/versions/node/v22.3.0/bin")
    }

    func testOnlyYarnOneCleansTheGlobalCache() throws {
        let classic = home + "/Cellar/yarn/1.22.22"
        let program = try script("yarn", "exit 0", in: classic + "/bin")
        try Data(#"{"name":"yarn","version":"1.22.22"}"#.utf8).write(to: URL(fileURLWithPath: classic + "/package.json"))
        XCTAssertTrue(NativeCleanup.isYarnClassic(program))
        let shim = home + "/lib/node_modules/corepack"
        let corepack = try script("yarn", "exit 0", in: shim + "/shims")
        try Data(#"{"name":"corepack","version":"0.29.0"}"#.utf8).write(to: URL(fileURLWithPath: shim + "/package.json"))
        XCTAssertFalse(NativeCleanup.isYarnClassic(corepack))
    }

    func testCommandCoversOnlyTheFolderTheToolOwns() throws {
        let npm = try script("npm", "exit 0")
        let item = try npmItem()
        let native = try XCTUnwrap(item.native)
        XCTAssertEqual(native.display, "npm cache clean --force")
        XCTAssertEqual(native.runs.map(\.folder), [npmCache])
        let argv = native.runs[0].argv
        XCTAssertTrue(argv[0].hasPrefix("PATH=" + bin + ":"), "the tool's own folder comes first for #!/usr/bin/env node")
        XCTAssertEqual(Array(argv.dropFirst()), [npm, "cache", "clean", "--force", "--cache", home + "/.npm"])
        XCTAssertEqual(native.runs[0].executable, npm)
        XCTAssertTrue(native.owns(npmCache + "/index-v5"))
        XCTAssertFalse(native.owns(npmLogs))
        XCTAssertTrue(item.runsNativeClean(.auto))
        XCTAssertFalse(item.runsNativeClean(.trash))
    }

    func testScanAttachesTheCommandFromTheFixedLocations() throws {
        try script("npm", "exit 0")
        _ = try npmItem(dirs: [])
        NativeCleanup.searchOverride = [bin]
        var options = ScanOptions()
        options.home = home
        options.categories = [.devCaches]
        options.onlyIDs = ["npm-cache"]
        let scanner = DiskScanner(options: options)
        scanner.saveReport = false
        let item = try XCTUnwrap(scanner.scan().items.first { $0.id == "npm-cache" })
        XCTAssertEqual(item.native?.runs.map(\.folder), [npmCache])
    }

    // MARK: Cleaning

    func testCommandRunsInsteadOfDeletingAndSizesAreMeasured() throws {
        // A fake npm that empties `<--cache>/_cacache` the way the real one does and records its PATH.
        try script("npm", #"for a; do last="$a"; done; rm -rf "$last/_cacache"; echo "$PATH" > "$last/../path.txt""#)
        let item = try npmItem()
        let cacheBytes = FS.size(npmCache).bytes, logBytes = FS.size(npmLogs).bytes
        let r = clean(item)
        XCTAssertEqual(r.failed, [:])
        XCTAssertEqual(r.outcome, "success")
        XCTAssertFalse(FS.exists(npmCache))
        XCTAssertFalse(FS.exists(npmLogs), "logs are not part of npm's command and are deleted as before")
        XCTAssertTrue(r.removed.contains("ran: " + item.native!.runs[0].commandLine))
        XCTAssertTrue(r.removed.contains(npmLogs))
        XCTAssertEqual(r.bytes, cacheBytes + logBytes)
        let o = try XCTUnwrap(r.toolCommands?.first)
        XCTAssertEqual(o.status, "ran")
        XCTAssertEqual(o.exitCode, 0)
        XCTAssertEqual(o.bytesBefore, cacheBytes)
        XCTAssertEqual(o.bytesAfter, 0)
        let path = try String(contentsOfFile: home + "/path.txt", encoding: .utf8)
        XCTAssertTrue(path.hasPrefix(bin + ":"))
        // The history names the command; nothing went to the real home.
        let journal = try String(contentsOf: OperationJournal.url(home: home), encoding: .utf8)
        XCTAssertTrue(journal.contains("ran: "), journal)
        XCTAssertTrue(try String(contentsOf: Cleaner.logURL(home: home), encoding: .utf8).contains("tool npm-cache ran"))
    }

    func testCommandThatFreesLittleReportsWhatItFreed() throws {
        try file(home + "/Library/Caches/pip/http/a")
        try file(home + "/Library/Caches/pip/selfcheck/b", bytes: 4096)
        try script("pip3", #"for a; do last="$a"; done; rm -rf "$last/http""#)
        let paths = [home + "/Library/Caches/pip/http", home + "/Library/Caches/pip/selfcheck"]
        let item = NativeCleanup.attach(CleanItem(id: "pip-cache", category: .devCaches, title: "pip cache", safety: .safe,
                                                  bytes: FS.size(paths).bytes, paths: paths), home: home, dirs: [bin])
        XCTAssertEqual(item.native?.runs.map(\.argv.last), [home + "/Library/Caches/pip"])
        let before = FS.size(home + "/Library/Caches/pip").bytes, kept = FS.size(paths[1]).bytes
        let r = clean(item)
        XCTAssertEqual(r.bytes, before - kept, "measured, not the scan's estimate")
        XCTAssertTrue(FS.exists(paths[1]), "what the tool keeps is not deleted behind it")
    }

    func testMissingToolFallsBackToDeletionAndSaysSo() throws {
        let item = try npmItem(dirs: [])
        XCTAssertEqual(item.native?.runs, [])
        XCTAssertNotNil(item.native?.fallback)
        XCTAssertTrue(item.note?.contains("npm") == true)
        let r = clean(item, ops: noCommands)
        XCTAssertFalse(FS.exists(npmCache))
        XCTAssertEqual(r.toolCommands?.first?.status, "notFound")
        XCTAssertEqual(r.toolCommands?.first?.fellBack, true)
        let journal = try String(contentsOf: OperationJournal.url(home: home), encoding: .utf8)
        XCTAssertTrue(journal.contains("npm cache clean --force") && journal.contains("skipped"), journal)
    }

    func testToolRemovedSinceTheReviewFallsBack() throws {
        let npm = try script("npm", "exit 0")
        let item = try npmItem()
        try FileManager.default.removeItem(atPath: npm)
        let r = clean(item, ops: noCommands)
        XCTAssertFalse(FS.exists(npmCache))
        XCTAssertEqual(r.toolCommands?.first?.status, "notFound")
        XCTAssertEqual(r.toolCommands?.first?.fellBack, true)
    }

    func testWhitelistStopsTheCommandAndKeepsTheWhitelistedPart() throws {
        try script("npm", "exit 0")
        let item = try npmItem()
        let kept = npmCache + "/index-v5"
        _ = try Whitelist.add([kept], home: home)
        // In the review: no command, the folder is deleted path by path.
        let reviewed = try Whitelist.load(home: home).apply(item)
        XCTAssertEqual(reviewed.native?.runs, [])
        XCTAssertFalse(reviewed.runsNativeClean(.auto))
        let fromReview = clean(reviewed, ops: noCommands)
        XCTAssertEqual(fromReview.toolCommands?.first?.status, "whitelisted")
        XCTAssertTrue(FS.exists(kept))
        // A whitelist edited after the review stops it at cleanup too.
        let r = clean(item, ops: noCommands)
        XCTAssertTrue(FS.exists(kept))
        XCTAssertEqual(r.toolCommands?.first?.status, "whitelisted")
        XCTAssertFalse(FS.exists(npmLogs))
    }

    func testWhitelistBlocksToolOnlyRemoval() throws {
        let store = home + "/Library/pnpm/store"
        try file(store + "/v3/files/aa")
        _ = try Whitelist.add([store], home: home)
        let item = CleanItem(id: "pnpm-store-prune", category: .devCaches, title: "pnpm", safety: .safe, bytes: 100,
                             commands: [["/usr/bin/true"]], measure: [store])
        XCTAssertNotNil(try Whitelist.load(home: home).apply(item).blocked)
        let r = clean(item, ops: noCommands)
        XCTAssertNotNil(r.failed[item.id])
        XCTAssertTrue(FS.exists(store + "/v3/files/aa"))
    }

    func testFailedCommandIsReportedAndTheFolderIsNotDeletedBehindIt() throws {
        try script("npm", "exit 0")
        let item = try npmItem()
        var ops = RemovalOperations.live
        ops.run = { _, _ in (1, "npm ERR! EACCES") }
        let r = clean(item, ops: ops)
        let line = item.native!.runs[0].commandLine
        XCTAssertEqual(r.failed[line], "npm ERR! EACCES")
        XCTAssertTrue(FS.exists(npmCache + "/index-v5/00/entry"))
        XCTAssertEqual(r.toolCommands?.first?.status, "failed")
        XCTAssertNil(r.toolCommands?.first?.fellBack)
        XCTAssertEqual(r.outcome, "partial", "the logs were still deleted")
    }

    func testTimeoutIsReportedThroughTheRealRunner() throws {
        try script("npm", "sleep 10")
        let item = try npmItem()
        var ops = RemovalOperations.live
        ops.commandTimeout = 1
        let started = Date()
        let r = clean(item, ops: ops)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertEqual(r.toolCommands?.first?.status, "timedOut")
        XCTAssertEqual(r.failed[item.native!.runs[0].commandLine], "timed out")
        XCTAssertTrue(FS.exists(npmCache + "/content-v2/sha512/aa/blob"))
    }

    func testUnmeasurableFolderIsUnknownNotZero() throws {
        try script("npm", "exit 0")
        let item = try npmItem()
        let locked = npmCache + "/locked"
        try file(locked + "/x")
        chmod(locked, 0)
        defer { chmod(locked, 0o755) }
        guard FS.size(npmCache).denied else { throw XCTSkip("running as a user that can read mode 000 folders") }
        var ops = RemovalOperations.live
        ops.run = { _, _ in (0, "") }
        let r = clean(item, ops: ops)
        XCTAssertEqual(r.bytesIncomplete, true)
        XCTAssertNil(r.toolCommands?.first?.bytesBefore)
        XCTAssertEqual(r.toolCommands?.first?.status, "ran")
    }

    func testTrashModeMovesTheFolderInsteadOfRunningTheTool() throws {
        try script("npm", "exit 0")
        let item = try npmItem()
        var ops = noCommands
        var trashed: [String] = []
        ops.trash = { path in
            trashed.append(path)
            let destination = URL(fileURLWithPath: self.home + "/.Trash/" + UUID().uuidString)
            try FileManager.default.createDirectory(atPath: self.home + "/.Trash", withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: path, toPath: destination.path)
            return destination
        }
        let r = clean(item, mode: .trash, ops: ops)
        XCTAssertEqual(Set(trashed), [npmCache, npmLogs])
        XCTAssertEqual(r.toolCommands?.first?.status, "trash")
    }

    func testRunningToolStillBlocksTheCommand() throws {
        try script("npm", "exit 0")
        let item = try npmItem()
        let busy = ProcessTable(entries: [AgentProcess(pid: 42, name: "npm", executable: "/opt/homebrew/bin/npm")])
        let r = Cleaner.clean(item, mode: .auto, guard: Guard(home: home), scannedAt: nil, processTable: busy, batchID: nil, operations: noCommands)
        XCTAssertNotNil(r.failed["npm-cache"])
        XCTAssertTrue(FS.exists(npmCache))
    }

    // MARK: Saved JSON

    func testOlderJSONStillDecodes() throws {
        let item = try npmItem(dirs: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json["native"] = nil
        let old = try JSONDecoder().decode(CleanItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.native)
        let result = try JSONDecoder().decode(CleanResult.self, from: Data(#"{"id":"npm-cache","removed":[],"failed":{},"bytes":0,"trashed":false}"#.utf8))
        XCTAssertNil(result.toolCommands)
    }
}
