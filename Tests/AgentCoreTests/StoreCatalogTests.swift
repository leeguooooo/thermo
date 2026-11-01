import XCTest
@testable import AgentCore

final class StoreCatalogTests: XCTestCase {
    func data(_ text: String) -> Data { Data(text.utf8) }

    let market = """
    {"name":"leeguooooo-plugins","plugins":[
      {"name":"mail-use","description":"Mail\\nCLI","version":"4.0.0","category":"productivity","homepage":"https://github.com/x/mail"},
      {"name":"--evil","version":"1.0.0"},
      {"name":"plain","version":"1.0.0","homepage":"http://example.com"}]}
    """

    func plugin(_ name: String, _ version: String? = "2.0.0") -> MarketplacePlugin {
        MarketplacePlugin(name: name, version: version)
    }

    func installed(_ name: String, _ version: String?, scope: String = "user", project: String? = nil) -> InstalledPlugin {
        InstalledPlugin(id: name + "@leeguooooo-plugins", installPath: "/x", scope: scope, projectPath: project, version: version)
    }

    // MARK: decoding

    func testMarketplaceDropsUnsafeNamesAndLinks() throws {
        let m = try XCTUnwrap(Marketplace.decode(data(market)))
        XCTAssertEqual(m.plugins.map(\.name), ["mail-use", "plain"])
        XCTAssertEqual(m.plugins[0].description, "Mail CLI")
        XCTAssertEqual(m.plugins[0].installID, "mail-use@leeguooooo-plugins")
        XCTAssertNil(m.plugins[1].homepage)
    }

    func testMarketplaceRejectsOtherMarketplaceAndHTML() {
        XCTAssertNil(Marketplace.decode(data(#"{"name":"evil","plugins":[{"name":"a"}]}"#)))
        XCTAssertNil(Marketplace.decode(data("<!doctype html><html></html>")))
    }

    func testAppCatalogKeepsOnlyHTTPSRows() throws {
        let apps = try XCTUnwrap(AppStoreCatalog.decode(data("""
        {"version":1,"apps":[
          {"id":"a","title":"A","description":{"zh":"中","en":"E"},"category":"Tools","icon":"🌡️","url":"https://app.leeguoo.com/a","bundle_id":"dev.thermo.app"},
          {"id":"b","title":"B","url":"http://app.leeguoo.com/b"},
          {"id":"c","title":"C","url":"javascript:alert(1)"},
          {"id":"d","title":"D","url":"https://x.test/d","icon":"https://x.test/i.png","bundle_id":"-bad"}]}
        """)))
        XCTAssertEqual(apps.map(\.id), ["a", "d"])
        XCTAssertEqual(apps[0].bundleID, "dev.thermo.app")
        XCTAssertEqual(apps[0].icon, "🌡️")
        XCTAssertEqual(apps[0].descriptionZH, "中")
        XCTAssertNil(apps[1].icon)
        XCTAssertNil(apps[1].bundleID)
    }

    func testAppCatalogHTMLResponseIsEmpty() {
        XCTAssertNil(AppStoreCatalog.decode(data("<html>not json</html>")))
        XCTAssertNil(AppStoreCatalog.decode(data(#"{"apps":[]}"#)))
    }

    func testHTTPSFilter() {
        XCTAssertNotNil(StoreText.httpsURL("https://app.leeguoo.com/thermo?x=1"))
        for bad in ["http://a.test", "file:///etc/passwd", "ftp://a.test", "https://", "https://u:p@a.test",
                    "https://u@a.test", "https://a.test/ b", "https://a.test\\@b.test", "x-apple.systempreferences:", " https://a.test"] {
            XCTAssertNil(StoreText.httpsURL(bad), bad)
        }
        XCTAssertNil(StoreText.httpsURL(42))
    }

    func testCleanRemovesInvisibleCharacters() {
        XCTAssertEqual(StoreText.clean("a\u{202E}b\u{0007}\nc", limit: 10), "ab c")
        XCTAssertEqual(StoreText.clean("abcdef", limit: 3), "abc")
        XCTAssertNil(StoreText.clean("  \n", limit: 3))
    }

    func testVersionsCompareNumericallyAndNeverGuess() {
        XCTAssertTrue(StoreVersion.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(StoreVersion.isNewer("1.0.1", than: "v1.0"))
        XCTAssertFalse(StoreVersion.isNewer("1.5.273", than: "1.5.276"))
        XCTAssertFalse(StoreVersion.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(StoreVersion.isNewer("abc", than: "1.0"))
        XCTAssertFalse(StoreVersion.isNewer("1.0", than: nil))
    }

    // MARK: use output, in the shape use.py 0.17 prints

    func testUseStatusAndCheck() {
        var use = UseManagerState()
        use.read(status: data(#"{"version":"0.17.0","clis":[{"name":"mail-use","path":"/b","version":"4.0.0"},{"name":"bad name","version":"1"}],"plugins":[]}"#))
        use.read(check: data("""
        {"ok":false,"items":[{"name":"mail-use","channel":"cli","status":"available","before":"4.0.0","target":"4.1.0"},
          {"name":"chrome-use","channel":"cli","status":"current","target":"1.0.0"},
          {"name":"x@leeguooooo-plugins","channel":"plugin","status":"installed"}]}
        """))
        XCTAssertEqual(use.cliVersions, ["mail-use": "4.0.0"])
        XCTAssertEqual(use.updates, ["mail-use": "4.1.0"])
        XCTAssertEqual(use.managed, ["use-family", "mail-use", "chrome-use"])
    }

    func testBrokenUseOutputLeavesStateAlone() {
        var use = UseManagerState()
        use.read(status: data("Error: nope"))
        use.read(check: data(""))
        XCTAssertEqual(use, UseManagerState())
    }

    // MARK: state

    func testStates() {
        let market = Marketplace(plugins: [plugin("a"), plugin("b"), plugin("c"), plugin("d"), plugin("e", nil)])
        var use = UseManagerState()
        use.cliVersions = ["d": "1.0.0"]
        use.updates = ["d": "1.2.0", "ghost": "9.0.0"]
        let rows = PluginRecords.build(market, installed: [installed("a", "1.0.0"), installed("b", "2.0.0"), installed("e", "1.0.0")], use: use)
        XCTAssertEqual(rows.map(\.state), [.updateAvailable("2.0.0"), .installed, .notInstalled, .updateAvailable("1.2.0"), .installed])
        XCTAssertNil(rows[3].install)
        XCTAssertEqual(rows[3].installedVersion, "1.0.0")
    }

    func testCLINewerThanMarketplaceIsNotAnUpdate() {
        var use = UseManagerState()
        use.cliVersions = ["a": "3.0.0"]
        XCTAssertEqual(PluginRecords.build(Marketplace(plugins: [plugin("a")]), installed: [], use: use)[0].state, .installed)
    }

    func testUserScopeWinsAndOtherMarketplacesDoNotCount() {
        let foreign = InstalledPlugin(id: "a@other", installPath: "/x", scope: "user", version: "9.0.0")
        let rows = PluginRecords.build(Marketplace(plugins: [plugin("a")]),
                                       installed: [foreign, installed("a", "1.0.0", scope: "project", project: "/p"), installed("a", "2.0.0")],
                                       use: UseManagerState())
        XCTAssertEqual(rows[0].install?.scope, "user")
        XCTAssertEqual(rows[0].state, .installed)
    }

    func testInstalledReadsPluginFileAndKnownMarketplace() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let agent = AgentHome(home: home.path)
        XCTAssertFalse(ClaudePlugins.marketplaceKnown(agent))
        try data(#"{"leeguooooo-plugins":{}}"#).write(to: dir.appendingPathComponent("known_marketplaces.json"))
        try data(#"{"version":2,"plugins":{"a@leeguooooo-plugins":[{"scope":"user","installPath":"/c/a/1.0.0","version":"1.0.0"}]}}"#)
            .write(to: dir.appendingPathComponent("installed_plugins.json"))
        XCTAssertTrue(ClaudePlugins.marketplaceKnown(agent))
        let rows = PluginRecords.build(Marketplace(plugins: [plugin("a")]), installed: ClaudePlugins.installed(agent), use: UseManagerState())
        XCTAssertEqual(rows[0].state, .updateAvailable("2.0.0"))
    }

    // MARK: argv

    func record(_ name: String, install: InstalledPlugin?) -> PluginRecord {
        PluginRecord(plugin: plugin(name), install: install, cliVersion: nil, state: .installed)
    }

    func testInstallAddsMarketplaceOnlyWhenMissing() {
        XCTAssertEqual(PluginCommands.install(plugin("a"), marketplaceKnown: true),
                       [StoreCommand(.claude, ["plugin", "install", "a@leeguooooo-plugins", "--scope", "user"])])
        XCTAssertEqual(PluginCommands.install(plugin("a"), marketplaceKnown: false).first,
                       StoreCommand(.claude, ["plugin", "marketplace", "add", "leeguooooo/plugins"]))
    }

    func testUpdateRoutesToManagerOnlyForItsNames() {
        var use = UseManagerState()
        use.managed.insert("mail-use")
        XCTAssertEqual(PluginCommands.update(record("mail-use", install: installed("mail-use", "1")), use: use),
                       [StoreCommand(.use, ["update", "mail-use", "--json"])])
        XCTAssertEqual(PluginCommands.update(record("other", install: installed("other", "1")), use: use), [
            StoreCommand(.claude, ["plugin", "marketplace", "update", "leeguooooo-plugins"]),
            StoreCommand(.claude, ["plugin", "update", "other@leeguooooo-plugins", "--scope", "user"])])
        XCTAssertNil(PluginCommands.update(record("cli-only", install: nil), use: nil))
    }

    func testProjectInstallsRunInTheirProject() {
        let dir = NSTemporaryDirectory()
        XCTAssertEqual(PluginCommands.uninstall(record("a", install: installed("a", "1", scope: "project", project: dir))),
                       [StoreCommand(.claude, ["plugin", "uninstall", "a@leeguooooo-plugins", "--scope", "project"], directory: dir)])
        XCTAssertNil(PluginCommands.uninstall(record("a", install: installed("a", "1", scope: "local", project: "/nonexistent/x"))))
        XCTAssertNil(PluginCommands.uninstall(record("a", install: nil)))
    }

    func testUseInstallerIsTwoProgramsAndNoShellString() {
        XCTAssertEqual(PluginCommands.downloadUseInstaller(to: "/t/i.sh"),
                       StoreCommand(.path("/usr/bin/curl"), ["-fsSL", PluginCommands.useInstallerURL, "-o", "/t/i.sh"]))
        XCTAssertEqual(PluginCommands.runUseInstaller(at: "/t/i.sh"), StoreCommand(.path("/bin/sh"), ["/t/i.sh"]))
    }

    // MARK: cache

    func testCacheRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = StoreCache(directory: dir)
        XCTAssertNil(cache.read("m.json"))
        cache.write(data("x"), as: "m.json")
        XCTAssertEqual(cache.read("m.json"), data("x"))
    }
}
