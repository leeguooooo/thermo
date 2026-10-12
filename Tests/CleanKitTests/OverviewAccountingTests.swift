import XCTest
@testable import CleanKit
import ThermoL10n

final class OverviewAccountingTests: XCTestCase {
    var root = ""
    var home: String { root + "/Data/Users/me" }
    var data: String { root + "/Data" }
    var temp: String { data + "/private/var/folders/ab/mine" }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        for p in ["Users/me/Library/Caches", "Users/me/Library/Containers/app", "Users/me/Library/Mail", "Users/me/Library/Developer",
                  "Users/me/.codex", "Users/me/.Trash", "Users/me/Downloads", "Users/me/github.com/repo", "Users/me/stuff",
                  "Users/me/Documents", "Users/other", "Users/Shared", "Applications/A.app",
                  "Library/Developer/CoreSimulator", "Library/Java", "private/tmp/x", "private/var/db", "private/var/vm",
                  "private/var/folders/ab/mine/T", "private/var/folders/ab/mine/C", "private/var/folders/ab/mine/X/clone",
                  "private/var/folders/ab/mine/0", "private/var/folders/zz/system", "private/etc",
                  "opt/homebrew", "opt/other", "usr/local", "cores",
                  "System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime",
                  "System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_CodeLM", "System/Library/Caches",
                  ".Spotlight-V100", "Volumes/disk"] {
            try FileManager.default.createDirectory(atPath: data + "/" + p, withIntermediateDirectories: true)
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func spots() -> [SpaceOverview.Spot] {
        SpaceOverview.spots(home: home, dataRoot: data, userTemp: temp, projectRoots: [home + "/github.com"])
    }

    /// The folders each heading measures: its children when it expands, else its paths.
    func measured(_ s: SpaceOverview.Spot) -> [String] {
        s.paths.flatMap { p in s.expand && s.children > 0 && FS.isDirectory(p) ? FS.children(p) : [p] }
    }

    func testEveryFolderIsCountedOnceAndOnlyOnce() {
        let all = spots().flatMap(measured)
        XCTAssertEqual(all.count, Set(all).count, "a folder under two headings is counted twice")
        // Nothing measured is inside another measured folder.
        for a in all { for b in all where a != b { XCTAssertFalse(b.hasPrefix(a + "/"), "\(b) is inside \(a)") } }
        for expected in [home + "/.codex", home + "/stuff", home + "/Library/Mail", home + "/github.com/repo", data + "/Users/other",
                         data + "/Users/Shared", data + "/Library/Java", data + "/private/var/db", data + "/private/etc", data + "/opt/other",
                         data + "/cores", temp + "/0", data + "/private/var/folders/zz/system",
                         data + "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_CodeLM", data + "/System/Library/Caches"] {
            XCTAssertTrue(all.contains(expected), expected)
        }
    }

    func testClonesSwapSimulatorsAndRootOnlyFoldersAreLeftToTheirOwnSources() {
        let all = spots().flatMap(measured)
        for excluded in [temp + "/X", data + "/private/var/vm", data + "/.Spotlight-V100", data + "/Volumes",
                         data + "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime"] {
            XCTAssertFalse(all.contains { $0 == excluded || $0.hasPrefix(excluded + "/") }, excluded)
        }
        let byID = Dictionary(uniqueKeysWithValues: spots().map { ($0.id, $0) })
        XCTAssertEqual(byID["system-data"]?.reportsDenied, false)
        XCTAssertEqual(byID["apps"]?.reportsDenied, true)
    }

    func testVolumesOfTheStartupContainerBecomeMacOSAndSwap() throws {
        let plist: [String: Any] = ["Containers": [
            ["Volumes": [["DeviceIdentifier": "disk1s1", "Name": "iSCPreboot", "Roles": ["Preboot"], "CapacityInUse": 5]]],
            ["Volumes": [
                ["DeviceIdentifier": "disk3s1", "Name": "Macintosh HD", "Roles": ["System"], "CapacityInUse": 12_600_000_000],
                ["DeviceIdentifier": "disk3s2", "Name": "Preboot", "Roles": ["Preboot"], "CapacityInUse": 9_000_000_000],
                ["DeviceIdentifier": "disk3s5", "Name": "Data", "Roles": ["Data"], "CapacityInUse": 451_000_000_000],
                ["DeviceIdentifier": "disk3s6", "Name": "VM", "Roles": ["VM"], "CapacityInUse": 15_900_000_000],
                ["DeviceIdentifier": "disk3s7", "Name": "Scratch", "Roles": [String](), "CapacityInUse": 1_000_000_000],
            ]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let volumes = try XCTUnwrap(SpaceOverview.parseVolumes(data, dataDevice: "disk3s5"))
        XCTAssertEqual(volumes.map(\.device), ["disk3s1", "disk3s2", "disk3s6", "disk3s7"], "the Data volume is walked, not counted whole")
        let entries = Dictionary(uniqueKeysWithValues: SpaceOverview.volumeEntries(volumes).map { ($0.id, $0) })
        XCTAssertEqual(entries["macos"]?.bytes, 21_600_000_000)
        XCTAssertEqual(entries["macos"]?.children.count, 2)
        XCTAssertNotNil(entries["macos"]?.action)
        XCTAssertEqual(entries["swap"]?.bytes, 15_900_000_000)
        XCTAssertEqual(entries["volumes"]?.bytes, 1_000_000_000)
        XCTAssertNil(SpaceOverview.parseVolumes(data, dataDevice: "disk9s9"))
    }

    func testRemainderIsNamedAndCachedOverviewsRelocalize() throws {
        L10n.override = .english
        defer { L10n.override = nil }
        // A tiny fixture on a real volume: nearly all used space is unattributed, so the remainder must appear.
        let result = SpaceOverview.measure(home: home, spots: Array(spots().prefix(2)),
                                          footprint: { _, _ in DiskFootprint(allocated: 1, files: 1, newest: nil, denied: false) })
        let other = try XCTUnwrap(result.entries.first { $0.id == "other" })
        XCTAssertEqual(other.title, "Not attributed to a folder")
        XCTAssertNil(result.overcounted)
        var o = SpaceOverview(capacity: 100, free: 10, purgeable: 0, entries: SpaceOverview.volumeEntries([
            .init(name: "System", roles: ["System"], bytes: 5, device: "d1"), .init(name: "VM", roles: ["VM"], bytes: 5, device: "d2")]), duration: 1)
        o.language = "en"
        L10n.override = .simplifiedChinese
        let zh = try XCTUnwrap(o.localizedForCurrentLanguage())
        XCTAssertEqual(zh.entries.first { $0.id == "macos" }?.action, "不能删除")
    }
}

final class OverviewTitleTests: XCTestCase {
    func testDataVolumePathsReadAsTheirUsualNamesAndAssetsAreNamed() {
        L10n.override = .english
        defer { L10n.override = nil }
        XCTAssertEqual(SpaceOverview.displayTitle("/System/Volumes/Data/opt/homebrew/share", home: "/Users/me"), "/opt/homebrew/share")
        XCTAssertEqual(SpaceOverview.displayTitle("/Users/me/.codex", home: "/Users/me"), "~/.codex")
        let codeLM = "/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_CodeLM"
        XCTAssertEqual(SpaceOverview.displayTitle(codeLM, home: "/Users/me"), "Xcode predictive code completion model (UAF_FM_CodeLM)")
        XCTAssertNotNil(SpaceOverview.assetAction(codeLM))
        XCTAssertEqual(SpaceOverview.displayTitle("/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_KextDenyList", home: "/x"), "KextDenyList")
        XCTAssertNil(SpaceOverview.assetAction("/Users/me/Library/Caches"))
    }
}
