import XCTest
@testable import WebAppsFeature

final class WebAppSchemeHandlerTests: XCTestCase {
    let root = URL(fileURLWithPath: "/tmp/webapp-root")
    func testPathsStayInsideTheAppFolder() {
        XCTAssertEqual(WebAppSchemeHandler.file(for: URL(string: "thermo-webapp://pdf/")!, in: root)?.path, "/tmp/webapp-root/index.html")
        XCTAssertEqual(WebAppSchemeHandler.file(for: URL(string: "thermo-webapp://pdf/assets/a.js")!, in: root)?.path, "/tmp/webapp-root/assets/a.js")
        XCTAssertNil(WebAppSchemeHandler.file(for: URL(string: "thermo-webapp://pdf/../secret")!, in: root))
        XCTAssertNil(WebAppSchemeHandler.file(for: URL(string: "thermo-webapp://pdf/%2E%2E/%2E%2E/etc/passwd")!, in: root))
    }
}

@MainActor final class WebAppLocalStoreTests: XCTestCase {
    func testFilesAndKeysRoundTripInsideTheDataFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WebAppLocalStore(directory: dir)
        _ = try store.handle(["op": "write", "path": "~/AppData/x/month.json", "text": "{\"a\":1}"])
        let read = try XCTUnwrap(store.handle(["op": "read", "path": "~/AppData/x/month.json"]) as? String)
        XCTAssertEqual(Data(base64Encoded: read), Data("{\"a\":1}".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("files/AppData/x/month.json").path))

        XCTAssertThrowsError(try store.handle(["op": "read", "path": "/nope.json"])) { error in
            XCTAssertTrue((error as? WebAppLocalStore.StoreError)?.message.contains("does_not_exist") == true)
        }
        XCTAssertThrowsError(try store.handle(["op": "write", "path": "../../escape", "text": "x"]))

        _ = try store.handle(["op": "kvSet", "key": "k", "value": ["n": 2]])
        XCTAssertEqual((try store.handle(["op": "kvGet", "key": "k"]) as? [String: Any])?["n"] as? Int, 2)
        _ = try store.handle(["op": "kvDel", "key": "k"])
        XCTAssertTrue(try store.handle(["op": "kvGet", "key": "k"]) is NSNull)
    }
}

import JavaScriptCore

final class WebAppInjectedScriptTests: XCTestCase {
    /// Parses (without running) every script injected into the pages.
    func testInjectedScriptsParse() throws {
        let context = try XCTUnwrap(JSContext())
        context.setObject([WebApp.pdf.offlineScript, WebApp.photoStudio.offlineScript, WebApp.timeTracking.offlineScript, WebAppLocalStore.shim], forKeyedSubscript: "sources" as NSString)
        let result = context.evaluateScript("sources.map((s) => { try { new Function(s); return 'ok'; } catch (e) { return String(e); } })")
        XCTAssertEqual(result?.toArray() as? [String], ["ok", "ok", "ok", "ok"])
    }
}
