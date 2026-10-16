@testable import AgentCore
@testable import CleanKit
import Foundation
import XCTest

final class NestedAppOwnershipTests: XCTestCase {
    var home = ""
    var app: String { home + "/Applications/Host.app" }
    var roots: [String] { [home + "/Applications"] }
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        try bundle(app, id: "com.example.host")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func bundle(_ path: String, id: String, relative: String = "Contents/Info.plist") throws {
        let file = path + "/" + relative
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: file))
    }
    func snapshot() -> AppOwnershipSnapshot { .capture(directories: roots) }
    func data(_ id: String) throws -> String {
        let path = home + "/Library/Caches/" + id
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("owned cache".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }
    func report() -> OrphanScanReport {
        AppUninstaller.reviewedOrphanReport(home: home, known: [], now: Date().addingTimeInterval(40 * 86400), spotlight: { _ in .absent },
            processes: .init(entries: []), directories: roots)
    }

    func testDeepNestedXPCIdentityKeepsItsIndependentDataOutOfOrphans() throws {
        try bundle(app + "/Contents/Library/LoginItems/Login.app", id: "org.vendor.login")
        try bundle(app + "/Contents/Library/LoginItems/Login.app/Contents/XPCServices/Worker.xpc", id: "net.independent.worker")
        let cache = try data("net.independent.worker")
        let result = report()
        XCTAssertTrue(result.complete); XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache))
        XCTAssertTrue(snapshot().declaredBundleIDs.contains("net.independent.worker"))
    }
    func testVersionedFrameworkAndItsXPCDeclarationsAreReadWithoutExecutingCode() throws {
        let framework = app + "/Contents/Frameworks/Shared.framework"
        try bundle(framework, id: "org.independent.framework", relative: "Versions/A/Resources/Info.plist")
        try bundle(framework + "/Versions/A/XPCServices/Service.xpc", id: "net.independent.service")
        try FileManager.default.createSymbolicLink(atPath: framework + "/Versions/Current", withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework + "/Resources", withDestinationPath: "Versions/Current/Resources")
        _ = try data("org.independent.framework"); _ = try data("net.independent.service")
        let result = report()
        XCTAssertTrue(result.complete, "\(result.issues)"); XCTAssertTrue(result.items.isEmpty)
    }
    func testRunningNestedAppMayShareAFrameworkInsideItsOuterHost() throws {
        let framework = app + "/Contents/Frameworks/Shared.framework"
        let helper = app + "/Contents/Library/LoginItems/Helper.app"
        try bundle(framework, id: "org.independent.framework", relative: "Resources/Info.plist")
        try bundle(helper, id: "org.independent.helper")
        try FileManager.default.createDirectory(atPath: helper + "/Contents/Frameworks", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: helper + "/Contents/Frameworks/Shared.framework", withDestinationPath: framework)
        let result = AppOwnershipSnapshot.capture(directories: roots, additionalPaths: [helper], requiredPaths: [helper])
        XCTAssertTrue(result.complete, "\(result.issues)")
        XCTAssertTrue(result.declaredBundleIDs.contains("org.independent.framework"))
    }
    func testUnreadableNestedInfoMakesOwnershipAndResidualReportIncomplete() throws {
        try XCTSkipIf(getuid() == 0, "requires ordinary user permissions")
        let nested = app + "/Contents/PlugIns/Extension.appex"
        try bundle(nested, id: "net.independent.extension")
        let file = nested + "/Contents/Info.plist"
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file) }
        XCTAssertFalse(snapshot().complete)
        let result = report()
        XCTAssertFalse(result.complete); XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.path == nested })
    }
    func testMissingExecutableBundleMetadataIsNotACompleteInventory() throws {
        let nested = app + "/Contents/XPCServices/Missing.xpc"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        XCTAssertFalse(snapshot().complete)
        XCTAssertTrue(snapshot().issues.contains(nested))
    }
    func testNestedInfoRewriteChangesFingerprintEvenWhenOuterBundleMetadataIsUnchanged() throws {
        let nested = app + "/Contents/XPCServices/Worker.xpc"
        try bundle(nested, id: "net.independent.before")
        let before = snapshot(), outer = AppDataReviewIdentity.of(app)
        try bundle(nested, id: "net.independent.after")
        XCTAssertEqual(AppDataReviewIdentity.of(app), outer)
        let after = snapshot()
        XCTAssertTrue(after.complete); XCTAssertNotEqual(after.fingerprint, before.fingerprint)
        XCTAssertTrue(after.declaredBundleIDs.contains("net.independent.after"))
    }
    func testNestedBundleAppearingAfterReviewChangesFingerprint() throws {
        let before = snapshot(), outer = AppDataReviewIdentity.of(app)
        try bundle(app + "/Contents/XPCServices/Returned.xpc", id: "net.independent.returned")
        XCTAssertEqual(AppDataReviewIdentity.of(app), outer)
        XCTAssertNotEqual(snapshot().fingerprint, before.fingerprint)
    }
    func testExternalBundleLinkIsNotTraversedAsAnEmbeddedOwner() throws {
        let external = home + "/External.app"
        try bundle(external, id: "net.external.identity")
        let directory = app + "/Contents/Library/LoginItems"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: directory + "/Linked.app", withDestinationPath: external)
        let result = snapshot()
        XCTAssertFalse(result.complete); XCTAssertFalse(result.declaredBundleIDs.contains("net.external.identity"))
    }
    func testResourceBundleWithoutExecutableIdentityDoesNotInventAnOwnerOrFailTheScan() throws {
        let resource = app + "/Contents/PlugIns/Resources.bundle"
        try FileManager.default.createDirectory(atPath: resource, withIntermediateDirectories: true)
        let result = snapshot()
        XCTAssertTrue(result.complete); XCTAssertEqual(result.declaredBundleIDs, ["com.example.host"])
    }
    func testDeclaredShortIdentifiersDoNotUseTheOrphanDirectoryHeuristic() throws {
        try bundle(app + "/Contents/Frameworks/One.framework", id: "SwiftyMarkdown", relative: "Resources/Info.plist")
        try bundle(app + "/Contents/Frameworks/Helper.app", id: "SwitchHosts.helper")
        let result = snapshot()
        XCTAssertTrue(result.complete)
        XCTAssertTrue(result.declaredBundleIDs.contains("swiftymarkdown"))
        XCTAssertTrue(result.declaredBundleIDs.contains("switchhosts.helper"))
        XCTAssertFalse(AppUninstaller.isBundleID("SwiftyMarkdown"))
        XCTAssertNil(AppUninstaller.orphanID("SwiftyMarkdown", root: "Caches"))
    }
    func testFrameworkWithoutIdentifierIsRecordedWithoutInventingAnOwner() throws {
        let framework = app + "/Contents/Frameworks/COnly.framework"
        try FileManager.default.createDirectory(atPath: framework, withIntermediateDirectories: true)
        XCTAssertTrue(snapshot().complete)
        XCTAssertEqual(snapshot().declaredBundleIDs, ["com.example.host"])
    }
    func testMalformedDeclaredIdentifierRemainsAnUnknownOwner() throws {
        try bundle(app + "/Contents/XPCServices/Worker.xpc", id: "../not-a-bundle-id")
        XCTAssertFalse(snapshot().complete)
    }
    func testPeerEmbeddedOwnerProtectsDataButOwnEmbeddedOwnersDoNotBecomeIndependentPeers() throws {
        let nested = app + "/Contents/XPCServices/Worker.xpc"
        try bundle(nested, id: "net.independent.worker")
        let value = snapshot()
        XCTAssertFalse(value.dataOwners(excludingEmbeddedIn: app).contains { $0.path == nested })
        XCTAssertTrue(value.dataOwners(excludingEmbeddedIn: home + "/Applications/Other.app").contains { $0.path == nested })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertNil(json["nestedClaims"]); XCTAssertNil(json["claims"])
    }
    func testDeepDeclarationLimitReportsIncompleteRatherThanWalkingForever() throws {
        var path = app
        for i in 0..<10 { path += "/Contents/XPCServices/Worker\(i).xpc"; try bundle(path, id: "net.worker.\(i)") }
        let result = snapshot()
        XCTAssertFalse(result.complete); XCTAssertFalse(result.issues.isEmpty)
    }
}
