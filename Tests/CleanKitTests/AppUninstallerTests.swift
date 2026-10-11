import AgentCore
@testable import CleanKit
import ThermoL10n
import XCTest

final class AppUninstallerTests: XCTestCase {
    var home = ""

    override func setUp() {
        L10n.override = .english
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("apps-\(UUID().uuidString)")
            .resolvingSymlinksInPath().path
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: home) }

    func make(_ rel: String, dir: Bool = true, age days: Double? = nil) {
        let path = home + "/" + rel
        let fm = FileManager.default
        if dir {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            fm.createFile(atPath: path + "/data", contents: Data(repeating: 1, count: 4096))
        } else {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data(repeating: 1, count: 512))
        }
        if let days {
            let d = Date().addingTimeInterval(days * 86400)
            for p in [path, path + "/data"] where fm.fileExists(atPath: p) {
                try? fm.setAttributes([.modificationDate: d], ofItemAtPath: p)
            }
        }
    }

    func app(_ name: String, _ id: String?, dir: String? = nil) -> InstalledApp {
        InstalledApp(path: (dir ?? home + "/Applications") + "/\(name).app", name: name, bundleID: id)
    }

    // MARK: guard

    func testGuardAllowsAppBundlesAndMatchingPreferencesOnly() {
        let g = Guard(home: home)
        make("Library/Preferences/com.foo.Bar.plist", dir: false)
        make("Library/Preferences/com.other.App.plist", dir: false)
        XCTAssertNil(g.uninstallRefusal("/Applications/Foo.app", bundleIDs: []))
        XCTAssertNil(g.uninstallRefusal("/Applications/Suite/Foo.app", bundleIDs: []))
        XCTAssertNil(g.uninstallRefusal(home + "/Applications/Foo.app", bundleIDs: []))
        XCTAssertNotNil(g.uninstallRefusal("/Applications/Foo.app/Contents", bundleIDs: []))
        XCTAssertNotNil(g.uninstallRefusal("/Applications/Foo.app/Contents/Helper.app", bundleIDs: []))
        XCTAssertNotNil(g.uninstallRefusal("/System/Applications/Calculator.app", bundleIDs: []))
        XCTAssertNotNil(g.uninstallRefusal("/Applications", bundleIDs: []))
        XCTAssertNotNil(g.uninstallRefusal("Applications/Foo.app", bundleIDs: []))
        XCTAssertNotNil(g.uninstallRefusal("/Applications/../Library/Foo.app", bundleIDs: []))

        XCTAssertNil(g.uninstallRefusal(home + "/Library/Preferences/com.foo.Bar.plist", bundleIDs: ["com.foo.Bar"]))
        XCTAssertNotNil(g.uninstallRefusal(home + "/Library/Preferences/com.other.App.plist", bundleIDs: ["com.foo.Bar"]))
        XCTAssertNotNil(g.uninstallRefusal(home + "/Library/Preferences", bundleIDs: ["com.foo.Bar"]))
        XCTAssertNotNil(g.uninstallRefusal(home + "/Library/Preferences/com.foo.Bar.plist", bundleIDs: []))
        // A glob or path in a bundle ID never widens the match.
        XCTAssertNotNil(g.uninstallRefusal(home + "/Library/Preferences/com.other.App.plist", bundleIDs: ["com"]))
        // Everything else is the ordinary guard.
        XCTAssertNil(g.uninstallRefusal(home + "/Library/Caches/com.foo.Bar", bundleIDs: []))
        XCTAssertNotNil(g.uninstallRefusal(home + "/Library/Caches", bundleIDs: []))
        XCTAssertNotNil(g.uninstallRefusal(home + "/.ssh/id_ed25519", bundleIDs: []))
        XCTAssertNotNil(g.uninstallRefusal("/Library/Application Support/Foo", bundleIDs: []))
    }

    // MARK: protection

    func testProtection() {
        XCTAssertNotNil(AppUninstaller.protection(app("Safari", "com.apple.Safari", dir: "/Applications"), home: home))
        XCTAssertNil(AppUninstaller.protection(app("Xcode", "com.apple.dt.Xcode", dir: "/Applications"), home: home))
        XCTAssertNotNil(AppUninstaller.protection(app("Calculator", "com.example.calc", dir: "/System/Applications"), home: home))
        XCTAssertNotNil(AppUninstaller.protection(app("Bitwarden", "com.bitwarden.desktop"), home: home))
        XCTAssertNotNil(AppUninstaller.protection(app("ClashX Pro", "com.west2online.ClashXPro"), home: home))
        XCTAssertNotNil(AppUninstaller.protection(app("Tailscale", "io.tailscale.ipn.macsys"), home: home))
        XCTAssertNotNil(AppUninstaller.protection(app("Squirrel", "im.rime.inputmethod.Squirrel"), home: home))
        XCTAssertNotNil(AppUninstaller.protection(app("Thermo", "dev.thermo.app"), home: home))
        XCTAssertNil(AppUninstaller.protection(app("Telegram", "ru.keepcoder.Telegram"), home: home))
    }

    func testBundleIDValidationAndGlob() {
        XCTAssertTrue(AppUninstaller.isBundleID("com.foo.Bar-2_x"))
        XCTAssertFalse(AppUninstaller.isBundleID("com.foo"))
        XCTAssertFalse(AppUninstaller.isBundleID("com.foo/../x.y"))
        XCTAssertFalse(AppUninstaller.isBundleID("com.*.bar"))
        XCTAssertFalse(AppUninstaller.isBundleID("com..bar"))
        XCTAssertTrue(AppUninstaller.matches("com.agilebits.onepassword7", "com.agilebits.*"))
        XCTAssertTrue(AppUninstaller.matches("com.nordvpn.macos", "*vpn*"))
        XCTAssertTrue(AppUninstaller.matches("com.foo.ime", "*.ime"))
        XCTAssertFalse(AppUninstaller.matches("com.foo.imessage", "*.ime"))
        XCTAssertTrue(AppUninstaller.startsWith("com.foo.Bar.helper.plist", id: "com.foo.Bar"))
        XCTAssertFalse(AppUninstaller.startsWith("com.foo.Barber.plist", id: "com.foo.Bar"))
    }

    func testFind() {
        let apps = [app("Google Chrome", "com.google.Chrome"), app("Chrome Remote Desktop", "com.google.chromeremotedesktop"), app("Zed", "dev.zed.Zed")]
        XCTAssertEqual(AppUninstaller.find("google chrome", in: apps).map(\.name), ["Google Chrome"])
        XCTAssertEqual(AppUninstaller.find("Zed.app", in: apps).map(\.name), ["Zed"])
        XCTAssertEqual(AppUninstaller.find("dev.zed.Zed", in: apps).map(\.name), ["Zed"])
        XCTAssertEqual(AppUninstaller.find("chrome", in: apps).count, 2)
        XCTAssertTrue(AppUninstaller.find("nothing", in: apps).isEmpty)
    }

    // MARK: leftovers

    func testLeftoversFindNameAndBundleIDPlaces() {
        let target = app("Foo Bar", "com.foo.Bar")
        for rel in ["Library/Application Support/com.foo.Bar", "Library/Application Support/FooBar", "Library/Caches/com.foo.Bar",
                    "Library/Containers/com.foo.Bar", "Library/Containers/com.foo.Bar.ShareExtension",
                    "Library/Group Containers/ABCDE12345.com.foo.Bar", "Library/Application Support/Foo/Bar",
                    "Library/Saved Application State/com.foo.Bar.savedState", ".config/foo-bar"] { make(rel) }
        for rel in ["Library/Preferences/com.foo.Bar.plist", "Library/Preferences/ByHost/com.foo.Bar.1234-ABCD.plist",
                    "Library/LaunchAgents/com.foo.Bar.updater.plist",
                    // Not this app: another product under the same ID, and an unrelated name.
                    "Library/Preferences/com.foo.Bar.for.testing.plist", "Library/Preferences/com.foo.Barber.plist"] { make(rel, dir: false) }
        make("Library/Application Support/Foo/Other")
        let found = Set(AppUninstaller.leftovers(for: target, installed: [target], home: home).map { String($0.path.dropFirst(home.count + 1)) })
        XCTAssertEqual(found, ["Library/Application Support/com.foo.Bar", "Library/Application Support/FooBar", "Library/Caches/com.foo.Bar",
                               "Library/Containers/com.foo.Bar", "Library/Containers/com.foo.Bar.ShareExtension",
                               "Library/Group Containers/ABCDE12345.com.foo.Bar", "Library/Application Support/Foo/Bar",
                               "Library/Saved Application State/com.foo.Bar.savedState", ".config/foo-bar",
                               "Library/Preferences/com.foo.Bar.plist", "Library/Preferences/ByHost/com.foo.Bar.1234-ABCD.plist",
                               "Library/LaunchAgents/com.foo.Bar.updater.plist"])
    }

    func testLeftoversLeaveWhatOtherInstalledAppsShare() {
        let target = app("Foo Bar", "com.foo.Bar")
        let sibling = app("Foo Baz", "com.foo.Baz")
        let helperApp = app("Foo Bar Helper", "com.foo.Bar.helper")
        make("Library/Group Containers/ABCDE12345.com.foo.Bar")
        make("Library/Containers/com.foo.Bar.helper")
        make("Library/Caches/com.foo.Bar")
        let found = Set(AppUninstaller.leftovers(for: target, installed: [target, sibling, helperApp], home: home).map(\.path))
        XCTAssertEqual(found, [home + "/Library/Caches/com.foo.Bar"])

        // Two copies with one bundle ID (Xcode and an Xcode beta): the files stay with the other copy.
        let beta = app("Foo Bar Beta", "com.foo.Bar")
        XCTAssertTrue(AppUninstaller.leftovers(for: beta, installed: [target, beta], home: home).isEmpty)
    }

    func testSharedOneWordNamesAreNotTakenAsLeftovers() {
        make("Library/Application Support/Docker")
        make("Library/Application Support/Notes")
        make(".config/docker")
        let docker = app("Docker", "com.docker.docker")
        XCTAssertTrue(AppUninstaller.leftovers(for: docker, installed: [docker], home: home).isEmpty)
        // A name another installed app also has is not this app's.
        let notes = app("Notes", "com.example.notes"), other = app("Notes", "org.other.notes", dir: home + "/Other")
        XCTAssertTrue(AppUninstaller.leftovers(for: notes, installed: [notes, other], home: home).isEmpty)
    }

    // MARK: running and protected apps are refused

    func testRunningOrProtectedAppIsNotUninstalled() {
        make("Applications/Foo Bar.app/Contents/MacOS")
        make("Library/Caches/com.foo.Bar")
        let target = app("Foo Bar", "com.foo.Bar")
        let running = ProcessTable(entries: [AgentProcess(pid: 42, name: "Foo Bar", executable: target.path + "/Contents/MacOS/Foo Bar")])
        let plan = AppUninstaller.plan(target, installed: [target], home: home, processes: running)
        XCTAssertEqual(plan.blocked, "Foo Bar is running; quit it first")
        XCTAssertEqual(plan.paths, [target.path, home + "/Library/Caches/com.foo.Bar"])
        let result = AppUninstaller.uninstall(plan, home: home, processes: { running })
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        // A helper running from the app's data blocks the whole uninstall, not just that folder.
        let helper = ProcessTable(entries: [AgentProcess(pid: 43, name: "helper", executable: home + "/Library/Caches/com.foo.Bar/helper")])
        XCTAssertEqual(AppUninstaller.plan(target, installed: [target], home: home, processes: helper).blocked, "helper is running; quit it first")

        var vpn = app("Foo VPN", "com.foo.vpn")
        vpn.protected = AppUninstaller.protection(vpn, home: home)
        let blocked = AppUninstaller.uninstall(AppUninstaller.plan(vpn, installed: [vpn], home: home, processes: ProcessTable(entries: [])), home: home,
                                               processes: { ProcessTable(entries: []) })
        XCTAssertTrue(blocked.removed.isEmpty)
        XCTAssertFalse(blocked.failed.isEmpty)
    }

    // MARK: orphans

    func testOrphansNeedAllChecks() {
        // Seen from 40 days on: freshly made files count as untouched for 40 days.
        let later = Date().addingTimeInterval(40 * 86400)
        make("Library/Application Support/com.gone.App")
        make("Library/Preferences/com.gone.App.plist", dir: false)
        make("Library/Caches/com.recent.App", age: 35)          // touched 5 days before `later`
        make("Library/Caches/com.known.App")                     // installed
        make("Library/Caches/com.known.App.helper")              // the installed app's helper
        make("Library/Caches/com.spot.App")                      // Spotlight finds it elsewhere
        make("Library/Caches/com.timeout.App")                   // Spotlight cannot answer
        make("Library/Caches/com.apple.Something")
        make("Library/Caches/com.1password.old")
        make("Library/Caches/NotABundle")
        make("Library/Preferences/com.dir.NotPlist")
        let spotlight: (String) -> Bool = { ["com.spot.App", "com.timeout.App"].contains($0) }
        let found = AppUninstaller.orphans(home: home, known: ["com.known.app"], now: later, spotlight: spotlight)
        XCTAssertEqual(found.map(\.bundleID), ["com.gone.App"])
        XCTAssertEqual(Set(found[0].items.map(\.path)), [home + "/Library/Application Support/com.gone.App",
                                                         home + "/Library/Preferences/com.gone.App.plist"])
        // Nothing is old yet today.
        XCTAssertTrue(AppUninstaller.orphans(home: home, known: [], spotlight: { _ in false }).isEmpty)
    }

    func testOrphanIDs() {
        XCTAssertEqual(AppUninstaller.orphanID("com.foo.Bar.savedState", root: "Saved Application State"), "com.foo.Bar")
        XCTAssertEqual(AppUninstaller.orphanID("com.foo.Bar.binarycookies", root: "HTTPStorages"), "com.foo.Bar")
        XCTAssertNil(AppUninstaller.orphanID("com.foo.Bar", root: "Preferences"))
        XCTAssertNil(AppUninstaller.orphanID(".com.foo.Bar", root: "Caches"))
        XCTAssertNil(AppUninstaller.orphanID("com.apple.Safari", root: "Caches"))
        XCTAssertNil(AppUninstaller.orphanID("com.nordvpn.macos", root: "Caches"))
        XCTAssertNil(AppUninstaller.orphanID("Google", root: "Application Support"))
    }

    func testSpotlightRefusesInvalidIDs() {
        // An ID that could break out of the query counts as found, so its data is kept.
        XCTAssertTrue(AppUninstaller.spotlightFinds("com.foo' || true || 'x.y"))
    }
}
