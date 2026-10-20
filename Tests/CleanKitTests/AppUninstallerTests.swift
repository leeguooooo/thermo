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

    func writeInfo(_ target: InstalledApp, version: String? = nil, executable: String? = nil) throws {
        try FileManager.default.createDirectory(atPath: target.path + "/Contents", withIntermediateDirectories: true)
        var info: [String: String] = [:]
        info["CFBundleIdentifier"] = target.bundleID
        info["CFBundleShortVersionString"] = version
        info["CFBundleExecutable"] = executable
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: target.path + "/Contents/Info.plist"), options: .atomic)
    }

    func fixturePlan(_ app: InstalledApp, installed: [InstalledApp], home: String, processes: ProcessTable? = nil, includePersonal: Bool = false) -> UninstallPlan {
        AppUninstaller.plan(app, installed: installed, home: home, processes: processes, includePersonal: includePersonal, ownershipDirectories: [home + "/Applications"])
    }

    // MARK: guard

    func testDeepResourceChangeAfterReviewRefusesBundleMove() throws {
        let target = app("DeepReview", "com.example.deep-review")
        try writeInfo(target, version: "1.0")
        let directory = target.path + "/Contents/Resources/Nested"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let resource = URL(fileURLWithPath: directory + "/resource.dat")
        try Data("before".utf8).write(to: resource)
        let inventory = try XCTUnwrap(AppUninstaller.read(target.path))
        let reviewed = fixturePlan(inventory, installed: [inventory], home: home, processes: ProcessTable(entries: []))
        XCTAssertNil(reviewed.blocked)
        let changed = Data("changed by an updater after confirmation".utf8)
        try changed.write(to: resource)
        var moves = 0
        let result = AppUninstaller.uninstall(reviewed, home: home, processes: { .init(entries: []) },
                                              ownershipDirectories: [home + "/Applications"], move: { _ in
            moves += 1
            throw NSError(domain: "owned-uninstall-probe", code: 1)
        })
        XCTAssertEqual(moves, 0, "A deep resource change must invalidate the reviewed bundle")
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: resource), changed)
    }

    func testDeepResourceChangeDuringLastProcessCheckRefusesBundleMove() throws {
        let target = app("DeepReview", "com.example.deep-review")
        try writeInfo(target, version: "1.0")
        let directory = target.path + "/Contents/Resources/Nested"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let resource = URL(fileURLWithPath: directory + "/resource.dat")
        try Data("before".utf8).write(to: resource)
        make("Library/Caches/com.example.deep-review")
        let inventory = try XCTUnwrap(AppUninstaller.read(target.path))
        let reviewed = fixturePlan(inventory, installed: [inventory], home: home, processes: ProcessTable(entries: []))
        XCTAssertNil(reviewed.blocked)
        XCTAssertEqual(Set(reviewed.paths), Set([target.path, home + "/Library/Caches/com.example.deep-review"]))
        let changed = Data("changed during the final process inventory".utf8)
        var inventories = 0
        var moves = 0
        let result = AppUninstaller.uninstall(reviewed, home: home, processes: {
            inventories += 1
            if inventories == 2 { try! changed.write(to: resource) }
            return .init(entries: [])
        }, ownershipDirectories: [home + "/Applications"], move: { _ in
            moves += 1
            throw NSError(domain: "owned-uninstall-probe", code: 1)
        })
        XCTAssertGreaterThanOrEqual(inventories, 2)
        XCTAssertEqual(moves, 0, "The last process inventory must not open a stale-review gap")
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: resource), changed)
        XCTAssertTrue(FS.exists(home + "/Library/Caches/com.example.deep-review/data"))
    }

    func testLegacyUninstallReviewWithoutBundleTreeMustBeReviewedAgain() throws {
        let target = app("DeepReview", "com.example.deep-review")
        try writeInfo(target, version: "1.0")
        let inventory = try XCTUnwrap(AppUninstaller.read(target.path))
        let reviewed = fixturePlan(inventory, installed: [inventory], home: home, processes: .init(entries: []))
        XCTAssertNotNil(reviewed.appTreeIdentity)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reviewed)) as? [String:Any])
        value.removeValue(forKey: "appTreeIdentity")
        let legacy = try JSONDecoder().decode(UninstallPlan.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertNil(legacy.appTreeIdentity)
        var moves = 0
        let result = AppUninstaller.uninstall(legacy, home: home, processes: { .init(entries: []) },
                                              ownershipDirectories: [home + "/Applications"], move: { _ in
            moves += 1
            throw NSError(domain: "owned-uninstall-probe", code: 1)
        })
        XCTAssertEqual(moves, 0)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertNotNil(result.failed[target.path])
    }

    func testReviewedAppReplacementRefusesBeforeMovingLeftovers() throws {
        let target = app("Review", "com.example.review")
        make("Applications/Review.app/Contents")
        try writeInfo(target)
        make("Library/Caches/com.example.review")
        let plan = fixturePlan(target, installed: [target], home: home, processes: ProcessTable(entries: []))
        XCTAssertNil(plan.blocked)
        try FileManager.default.moveItem(atPath: target.path, toPath: target.path + ".old")
        make("Applications/Review.app/Contents")
        let result = AppUninstaller.uninstall(plan, home: home, processes: { ProcessTable(entries: []) })
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.failed[target.path], "The app changed after review; review the uninstall again")
        XCTAssertTrue(FS.exists(home + "/Library/Caches/com.example.review"))
    }

    func testInventoryToReviewRejectsDifferentBundleAndVersion() throws {
        let target = app("Review", "com.example.review")
        for changeID in [false, true] {
            try writeInfo(target, version: "1.0")
            let inventory = try XCTUnwrap(AppUninstaller.read(target.path))
            let replacement = app("Review", changeID ? "com.example.other" : target.bundleID)
            try writeInfo(replacement, version: changeID ? "1.0" : "2.0")
            let plan = fixturePlan(inventory, installed: [inventory], home: home, processes: ProcessTable(entries: []))
            XCTAssertEqual(plan.blocked, "The app changed since the inventory; refresh the app list and review again")
            XCTAssertNil(plan.appIdentity)
            XCTAssertTrue(AppUninstaller.uninstall(plan, home: home, processes: { ProcessTable(entries: []) }).removed.isEmpty)
            XCTAssertTrue(FS.exists(target.path))
            let refreshed = try XCTUnwrap(AppUninstaller.read(target.path))
            XCTAssertNil(fixturePlan(refreshed, installed: [refreshed], home: home, processes: ProcessTable(entries: [])).blocked)
        }
    }

    func testInventoryToReviewDetectsChangedExecutableWithUnchangedVersion() throws {
        let target = app("Review", "com.example.review")
        try writeInfo(target, version: "1.0", executable: "Review")
        try FileManager.default.createDirectory(atPath: target.path + "/Contents/MacOS", withIntermediateDirectories: true)
        let executable = URL(fileURLWithPath: target.path + "/Contents/MacOS/Review")
        try Data("old".utf8).write(to: executable)
        let inventory = try XCTUnwrap(AppUninstaller.read(target.path))
        try Data("new executable contents".utf8).write(to: executable)
        let plan = fixturePlan(inventory, installed: [inventory], home: home, processes: ProcessTable(entries: []))
        XCTAssertNotNil(plan.blocked)
        XCTAssertNil(plan.appIdentity)
        XCTAssertTrue(AppUninstaller.uninstall(plan, home: home, processes: { ProcessTable(entries: []) }).removed.isEmpty)
    }

    func testUnverifiableMetadataRemainsVisibleButCannotBeUninstalled() throws {
        let target = app("Review", "com.example.review")
        try writeInfo(target, version: "1.0")
        let info = target.path + "/Contents/Info.plist"
        let stored = home + "/external-info.plist"
        try FileManager.default.moveItem(atPath: info, toPath: stored)
        try FileManager.default.createSymbolicLink(atPath: info, withDestinationPath: stored)
        let found = AppUninstaller.installed(home: home, dirs: [home + "/Applications"])
        let entry = try XCTUnwrap(found.first)
        XCTAssertEqual(entry.bundleID, target.bundleID)
        XCTAssertNil(entry.inventoryIdentity)
        XCTAssertNotNil(entry.protected)
        let plan = fixturePlan(entry, installed: found, home: home, processes: ProcessTable(entries: []))
        XCTAssertNotNil(plan.blocked)
        XCTAssertNil(plan.appIdentity)
        XCTAssertTrue(AppUninstaller.uninstall(plan, home: home, processes: { ProcessTable(entries: []) }).removed.isEmpty)
        XCTAssertTrue(FS.exists(target.path))
    }

    func testInPlaceExecutableUpdateInvalidatesReview() throws {
        make("Applications/Review.app/Contents/MacOS")
        let path = home + "/Applications/Review.app"
        let plist: [String: Any] = ["CFBundleExecutable": "Review", "CFBundleIdentifier": "com.example.review"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        let executable = URL(fileURLWithPath: path + "/Contents/MacOS/Review")
        try Data("old".utf8).write(to: executable)
        let before = try XCTUnwrap(AppReviewIdentity.capture(path))
        XCTAssertEqual(before, AppReviewIdentity.capture(path))
        try Data("updated executable".utf8).write(to: executable)
        XCTAssertNotEqual(before, AppReviewIdentity.capture(path))
    }

    func testOldSerializedPlanRequiresNewReview() throws {
        make("Applications/Review.app/Contents")
        let target = app("Review", "com.example.review")
        let plan = UninstallPlan(app: target, paths: [target.path], bytes: 0)
        let decoded = try JSONDecoder().decode(UninstallPlan.self, from: JSONEncoder().encode(plan))
        let result = AppUninstaller.uninstall(decoded, home: home, processes: { ProcessTable(entries: []) })
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.failed[target.path], "The app changed after review; review the uninstall again")
    }

    func testReplacedLeftoverIsSkippedWhileUnchangedItemCanMove() throws {
        let path = home + "/Library/Caches/com.example.review"
        make("Library/Caches/com.example.review")
        let identity = try XCTUnwrap(FileIdentity.of(path))
        var result = CleanResult(id: "test", trashed: true)
        var moves = 0
        AppUninstaller.trash([path], bundleIDs: [], sizes: [:], home: home, processes: { ProcessTable(entries: []) },
                             into: &result, identities: [path: identity], move: { source in
            moves += 1
            throw NSError(domain: "test", code: 1)
        })
        XCTAssertEqual(moves, 1)
        try FileManager.default.moveItem(atPath: path, toPath: path + ".old")
        make("Library/Caches/com.example.review")
        result = CleanResult(id: "test", trashed: true)
        AppUninstaller.trash([path], bundleIDs: [], sizes: [:], home: home, processes: { ProcessTable(entries: []) },
                             into: &result, identities: [path: identity], move: { _ in
            XCTFail("must not move a replacement")
            throw NSError(domain: "test", code: 1)
        })
        XCTAssertEqual(result.failed[path], "The item changed after review; review the uninstall again")
    }

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

    func testBrowserProfileIsKeptUnlessAsked() {
        let chrome = app("Google Chrome", "com.google.Chrome")
        make("Applications/Google Chrome.app")
        for rel in ["Library/Application Support/Google/Chrome", "Library/Caches/Google/Chrome",
                    "Library/Caches/com.google.Chrome"] { make(rel) }
        make("Library/Preferences/com.google.Chrome.plist", dir: false)
        let processes = ProcessTable(entries: [])
        let plan = fixturePlan(chrome, installed: [chrome], home: home, processes: processes)
        let rel = { (p: String) in String(p.dropFirst(self.home.count + 1)) }
        XCTAssertEqual(plan.kept?.map { rel($0.path) }, ["Library/Application Support/Google/Chrome"])
        XCTAssertFalse(plan.paths.contains(home + "/Library/Application Support/Google/Chrome"))
        XCTAssertTrue(plan.paths.contains(home + "/Library/Caches/Google/Chrome"))
        let all = fixturePlan(chrome, installed: [chrome], home: home, processes: processes, includePersonal: true)
        XCTAssertNil(all.kept)
        XCTAssertTrue(all.paths.contains(home + "/Library/Application Support/Google/Chrome"))
        XCTAssertGreaterThan(all.bytes, plan.bytes)

        // Other apps' data folders go with them as before.
        let foo = app("Foo", "com.foo.Foo")
        make("Library/Application Support/com.foo.Foo")
        XCTAssertNil(fixturePlan(foo, installed: [foo], home: home, processes: processes).kept)
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
        let plan = fixturePlan(target, installed: [target], home: home, processes: running)
        XCTAssertEqual(plan.blocked, "Foo Bar is running; quit it first")
        XCTAssertEqual(plan.paths, [target.path, home + "/Library/Caches/com.foo.Bar"])
        let result = AppUninstaller.uninstall(plan, home: home, processes: { running })
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        // A helper running from the app's data blocks the whole uninstall, not just that folder.
        let helper = ProcessTable(entries: [AgentProcess(pid: 43, name: "helper", executable: home + "/Library/Caches/com.foo.Bar/helper")])
        XCTAssertEqual(fixturePlan(target, installed: [target], home: home, processes: helper).blocked, "helper is running; quit it first")

        var vpn = app("Foo VPN", "com.foo.vpn")
        vpn.protected = AppUninstaller.protection(vpn, home: home)
        let blocked = AppUninstaller.uninstall(fixturePlan(vpn, installed: [vpn], home: home, processes: ProcessTable(entries: [])), home: home,
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

    /// A bundle the user cannot write to (installed as root) cannot be moved by macOS at all;
    /// the plan is refused up front instead of failing halfway.
    func testAnAppTheUserCannotWriteToIsRefusedBeforeAnythingMoves() throws {
        make("Applications/Locked.app/Contents")
        let path = home + "/Applications/Locked.app"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        let plan = UninstallPlan(app: app("Locked", "com.example.locked"), paths: [path], bytes: 0)
        let why = AppUninstaller.refusal(plan, home: home, processes: ProcessTable(entries: []))
        XCTAssertEqual(why, "Locked belongs to the administrator account, so Thermo cannot move it. Drag it to the Trash in Finder, which asks for your password.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
