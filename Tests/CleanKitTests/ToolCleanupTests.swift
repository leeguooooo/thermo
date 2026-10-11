import XCTest
@testable import CleanKit

final class ToolCleanupTests: XCTestCase {
    func testParsesHomebrewDryRun() {
        let out = """
        Warning: Skipping ttyd: most recent version 1.7.7_14 not installed
        Would remove: /opt/homebrew/Cellar/dnsmasq/2.92 (9 files, 572.4KB)
        Would remove: /opt/homebrew/Cellar/node/22.1.0 (2,345 files, 81.2MB)
        Would remove: /Users/me/Library/Caches/Homebrew/downloads/abc--x.tar.gz (1.5GB)
        Would remove (broken link): /opt/homebrew/bin/openapi-lark
        ==> This operation would free approximately 1.6GB of disk space.
        """
        let found = ToolCleanup.parseBrewDryRun(out)
        XCTAssertEqual(found.map(\.path), ["/opt/homebrew/Cellar/dnsmasq/2.92", "/opt/homebrew/Cellar/node/22.1.0",
                                           "/Users/me/Library/Caches/Homebrew/downloads/abc--x.tar.gz"])
        XCTAssertEqual(found.map(\.bytes), [572_400, 81_200_000, 1_500_000_000])
        XCTAssertEqual(ToolCleanup.parseSize("12B"), 12)
        XCTAssertEqual(ToolCleanup.parseSize("junk"), 0)
    }

    func testBrowserOldVersionOnlyThePreviousFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)").path
        let real = realpath(FileManager.default.temporaryDirectory.path, nil).map { p in defer { free(p) }; return String(cString: p) }!
        let apps = real + "/" + (root as NSString).lastPathComponent
        defer { try? FileManager.default.removeItem(atPath: apps) }
        let versions = apps + "/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions"
        for v in ["1.0", "2.0"] {
            try FileManager.default.createDirectory(atPath: versions + "/" + v, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: versions + "/" + v + "/lib", contents: Data(repeating: 1, count: 8192))
        }
        try FileManager.default.createSymbolicLink(atPath: versions + "/Current", withDestinationPath: "2.0")
        XCTAssertEqual(ToolCleanup.oldVersions(versions), [versions + "/1.0"])
        XCTAssertNil(ToolCleanup.oldVersionRefusal(versions + "/1.0", appsRoot: apps))
        XCTAssertNotNil(ToolCleanup.oldVersionRefusal(versions + "/2.0", appsRoot: apps), "the version in use")
        XCTAssertNotNil(ToolCleanup.oldVersionRefusal(versions + "/Current", appsRoot: apps))
        XCTAssertNotNil(ToolCleanup.oldVersionRefusal(apps + "/Google Chrome.app", appsRoot: apps))
        XCTAssertNotNil(ToolCleanup.oldVersionRefusal(versions + "/1.0", appsRoot: "/Applications"), "only the browsers' own place")
    }
}

final class CodeSignCloneTests: XCTestCase {
    func testLeftoverClonesAreFoundAndOnlyThatShapeMayGo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        for c in ["a", "b"] {
            try FileManager.default.createDirectory(atPath: root + "/com.example.App.code_sign_clone/code_sign_clone.\(c)/App.app", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: root + "/com.example.App.code_sign_clone/code_sign_clone.\(c)/App.app/bin", contents: Data(repeating: 1, count: 8192))
        }
        let ctx = ScanContext(options: ScanOptions(), now: Date(), processes: ProcessTable(entries: []), agentDirs: [], liveClaudeSessions: [])
        let item = try XCTUnwrap(ToolCleanup.codeSignClones(ctx, root: root))
        XCTAssertEqual(item.paths.count, 2, "the app is not running, so no clone is in use")
        XCTAssertEqual(item.id, "code-sign-clones")

        let x = (NSTemporaryDirectory() as NSString).deletingLastPathComponent + "/X"
        let g = Guard()
        XCTAssertNil(g.refusal(x + "/com.google.Chrome.code_sign_clone/code_sign_clone.abc"))
        XCTAssertNotNil(g.refusal(x + "/com.google.Chrome.code_sign_clone"))
        XCTAssertNotNil(g.refusal(x + "/something/else"))
        XCTAssertNotNil(g.refusal(x + "/com.google.Chrome.code_sign_clone/code_sign_clone.abc/Google Chrome.app"))
    }
}
