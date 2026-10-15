@testable import AgentCore
@testable import CleanKit
import CryptoKit
import Foundation
import XCTest

final class NativeUpdateTransactionTests: XCTestCase {
    var home = "", original = "", package = "", archive = ""
    var key = Curve25519.Signing.PrivateKey()

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        original = home + "/Applications/Fixture.app"
        package = home + "/package/Fixture.app"
        archive = home + "/update.zip"
        try makeApp(original, version: "1.0", build: "100")
        try makeApp(package, version: "2.0", build: "200")
        try zip()
    }
    override func tearDownWithError() throws {
        for path in try ownedMountedImages() { XCTAssertTrue(NativeDiskImage.detachOwned(path), "temporary test image must detach") }
        try FileManager.default.removeItem(atPath: home)
    }

    func ownedMountedImages() throws -> [String] {
        let result = CommandRunner.run("/usr/bin/hdiutil", arguments: ["info", "-plist"], timeout: 15)
        let info = try NativeDiskImage.plist(result)
        return (info["images"] as? [[String: Any]] ?? []).compactMap { $0["image-path"] as? String }
            .filter { NativeDiskImage.canonical($0).hasPrefix(home + "/") }
    }

    func assertNoOwnedMountedImages(file: StaticString = #filePath, line: UInt = #line) throws {
        let paths = try ownedMountedImages()
        XCTAssertTrue(paths.isEmpty, "unexpected owned images: " + paths.joined(separator: ", "), file: file, line: line)
    }

    func dmg() throws {
        archive = home + "/update.dmg"
        try execute("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", (package as NSString).deletingLastPathComponent,
                                        "-format", "UDZO", archive])
    }

    func execute(_ executable: String, _ args: [String]) throws {
        let result = CommandRunner.run(executable, arguments: args, timeout: 30)
        guard result.status == 0 else { throw ArchiveFailure(result.output) }
    }
    func makeApp(_ path: String, version: String, build: String, id: String = "com.example.thermo-native-fixture") throws {
        try FileManager.default.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path + "/Contents/Resources", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: path + "/Contents/MacOS/Fixture")
        let info = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleVersion": build,
                    "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
                    "SUFeedURL": "https://updates.example.test/feed.xml", "SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString()]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        try Data(("resource-" + build).utf8).write(to: URL(fileURLWithPath: path + "/Contents/Resources/data"))
        try execute("/usr/bin/codesign", ["--force", "--sign", "-", path])
    }
    func zip() throws {
        try? FileManager.default.removeItem(atPath: archive)
        try execute("/usr/bin/ditto", ["-c", "-k", "--keepParent", package, archive])
    }
    func reviewed(signature: String? = nil) throws -> NativeUpdateCheck {
        let app = try XCTUnwrap(AppUninstaller.read(original))
        let source = try XCTUnwrap(NativeAppUpdates.sources(apps: [app]).first)
        let data = try Data(contentsOf: URL(fileURLWithPath: archive))
        let signed = try signature ?? key.signature(for: data).base64EncodedString()
        let release = SparkleRelease(build: "200", version: "2.0", enclosureFingerprint: "fixture", signature: signed,
                                     length: Int64(data.count), hardware: [])
        return NativeUpdateCheck(source: source, status: "available", message: "fixture", release: release)
    }
    func prepared() throws -> PreparedNativeUpdate {
        try NativeUpdateTransaction.prepare(reviewed(), archive: URL(fileURLWithPath: archive), home: home)
    }
    func build(_ path: String) -> String? { NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleVersion"] as? String }

    func testSignedZIPInstallsAtomicallyAndRestoresThePreservedApp() throws {
        let prepared = try prepared()
        let before = try NativeBundleValidation.treeSeal(original)
        let result = NativeUpdateTransaction.commit(prepared, home: home, processes: { ProcessTable(entries: []) }, afterSwap: {})
        XCTAssertEqual(result.outcome, "succeeded", result.message)
        XCTAssertEqual(build(original), "200")
        let receipt = try XCTUnwrap(result.receipt)
        XCTAssertEqual(build(receipt.backup), "100")
        XCTAssertEqual(NativeUpdateTransaction.receipts(home: home).first?.phase, "installed")
        let restored = NativeUpdateTransaction.recover(receipt.id, home: home, processes: { ProcessTable(entries: []) })
        XCTAssertEqual(restored.outcome, "succeeded", restored.message)
        XCTAssertEqual(build(original), "100")
        XCTAssertEqual(try NativeBundleValidation.treeSeal(original), before)
        XCTAssertEqual(build(receipt.backup), "200")
        try NativeUpdateTransaction.discard(prepared, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.workspace))
    }

    func testWrongArchiveSignatureNeverTouchesTheOriginal() throws {
        let other = Curve25519.Signing.PrivateKey()
        let data = try Data(contentsOf: URL(fileURLWithPath: archive))
        let review = try reviewed(signature: other.signature(for: data).base64EncodedString())
        XCTAssertThrowsError(try NativeUpdateTransaction.prepare(review, archive: URL(fileURLWithPath: archive), home: home))
        XCTAssertEqual(build(original), "100")
    }

    func testSignedAppInternalVersionedLinksAcceptSystemPathAliases() throws {
        let framework = package + "/Contents/Resources/Versioned"
        try FileManager.default.createDirectory(atPath: framework + "/Versions/A/Resources", withIntermediateDirectories: true)
        try Data("vendor resource".utf8).write(to: URL(fileURLWithPath: framework + "/Versions/A/Resources/data"))
        try FileManager.default.createSymbolicLink(atPath: framework + "/Versions/Current", withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework + "/Resources", withDestinationPath: "Versions/Current/Resources")
        try execute("/usr/bin/codesign", ["--force", "--sign", "-", package])
        XCTAssertNoThrow(try NativeBundleValidation.facts(package))
    }

    func testSystemPathAliasComparisonStillRejectsExternalAndAbsoluteLinks() throws {
        let link = package + "/Contents/Resources/link"
        try Data("outside".utf8).write(to: URL(fileURLWithPath: home + "/outside"))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "../../../../outside")
        XCTAssertThrowsError(try NativeBundleValidation.treeSeal(package))
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: package + "/Contents/Resources/data")
        XCTAssertThrowsError(try NativeBundleValidation.treeSeal(package))
    }

    func testUnsignedOrModifiedCodeIsRejectedEvenInsideASignedArchive() throws {
        try Data("modified".utf8).write(to: URL(fileURLWithPath: package + "/Contents/Resources/data"))
        try zip()
        XCTAssertThrowsError(try prepared())
        XCTAssertEqual(build(original), "100")
    }

    func testPostSwapFailureActuallyRollsBack() throws {
        let prepared = try prepared()
        let before = try NativeBundleValidation.treeSeal(original)
        let result = NativeUpdateTransaction.commit(prepared, home: home, processes: { ProcessTable(entries: []) }, afterSwap: {
            throw ArchiveFailure("synthetic post-swap failure")
        })
        XCTAssertEqual(result.outcome, "failed")
        XCTAssertEqual(result.receipt?.phase, "rolledBack")
        XCTAssertEqual(try NativeBundleValidation.treeSeal(original), before)
        XCTAssertEqual(build(original), "100")
    }

    func testConcurrentReplacementIsNeverOverwrittenByRollback() throws {
        let prepared = try prepared()
        let result = NativeUpdateTransaction.commit(prepared, home: home, processes: { ProcessTable(entries: []) }, afterSwap: {
            try FileManager.default.moveItem(atPath: self.original, toPath: self.original + ".external")
            try self.makeApp(self.original, version: "3.0", build: "300")
            throw ArchiveFailure("synthetic concurrent replacement")
        })
        XCTAssertEqual(result.outcome, "unconfirmed")
        XCTAssertEqual(build(original), "300")
        XCTAssertEqual(build(try XCTUnwrap(result.receipt).backup), "100")
    }

    func testCorruptedBackupIsNeverUsedForAutomaticRollback() throws {
        let prepared = try prepared()
        let result = NativeUpdateTransaction.commit(prepared, home: home, processes: { ProcessTable(entries: []) }, afterSwap: {
            let parent = (self.original as NSString).deletingLastPathComponent
            let leaf = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: parent).first { $0.hasPrefix(".thermo-update-") })
            try Data("corrupted backup".utf8).write(to: URL(fileURLWithPath: parent + "/" + leaf + "/previous.app/Contents/Resources/data"))
        })
        XCTAssertEqual(result.outcome, "unconfirmed")
        XCTAssertEqual(build(original), "200", "the verified new app must not be replaced with a corrupted backup")
        XCTAssertNoThrow(try NativeBundleValidation.facts(original))
    }

    func testChangedPreparedBundleDoesNotReachTheSwap() throws {
        let prepared = try prepared()
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: prepared.bundle + "/Contents/Resources/data"))
        let result = NativeUpdateTransaction.commit(prepared, home: home, processes: { ProcessTable(entries: []) }, afterSwap: { XCTFail("must not swap") })
        XCTAssertEqual(result.outcome, "failed")
        XCTAssertEqual(build(original), "100")
    }

    func testRecoveryRefusesAnAppChangedAfterInstallation() throws {
        let result = NativeUpdateTransaction.commit(try prepared(), home: home, processes: { ProcessTable(entries: []) }, afterSwap: {})
        let receipt = try XCTUnwrap(result.receipt)
        try Data("user changed app".utf8).write(to: URL(fileURLWithPath: original + "/Contents/Resources/data"))
        let recovered = NativeUpdateTransaction.recover(receipt.id, home: home, processes: { ProcessTable(entries: []) })
        XCTAssertEqual(recovered.outcome, "failed")
        XCTAssertEqual(build(original), "200")
        XCTAssertEqual(build(receipt.backup), "100")
    }

    func testSymlinkLeavingBundleIsRejected() throws {
        try FileManager.default.createSymbolicLink(atPath: package + "/Contents/Resources/outside", withDestinationPath: "../../../../outside")
        try execute("/usr/bin/codesign", ["--force", "--sign", "-", package])
        try zip()
        XCTAssertThrowsError(try prepared())
        XCTAssertEqual(build(original), "100")
    }

    func testNativeArchitectureCannotBeReplacedWithIntelOnly() throws {
        let prepared = try prepared()
        var old = prepared.original, new = prepared.replacement
        old.architectures = ["arm64", "x86_64"]; new.architectures = ["x86_64"]
        XCTAssertThrowsError(try NativeBundleValidation.compatible(new, with: old, release: prepared.release, host: "arm64"))
        new.architectures = ["arm64"]
        XCTAssertThrowsError(try NativeBundleValidation.compatible(new, with: old, release: prepared.release, host: "x86_64"))
        XCTAssertNoThrow(try NativeBundleValidation.compatible(new, with: old, release: prepared.release, host: "arm64"))
    }

    func feedData(build: String = "200", token: String = "initial", signature supplied: String? = nil, format: String = "zip") throws -> Data {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: archive))
        let signature = try supplied ?? key.signature(for: bytes).base64EncodedString()
        return Data("<rss xmlns:s=\"\(SparkleFeed.namespace)\"><channel><item><s:version>\(build)</s:version><s:shortVersionString>2.0</s:shortVersionString><enclosure url=\"https://updates.example.test/Fixture.\(format)?token=\(token)\" length=\"\(bytes.count)\" s:edSignature=\"\(signature)\"/></item></channel></rss>".utf8)
    }

    func testDownloadPreparationAndCommitUseTheSameAuthenticatedPipeline() async throws {
        let source = try XCTUnwrap(NativeAppUpdates.sources(apps: [try XCTUnwrap(AppUninstaller.read(original))]).first)
        let feed = try feedData()
        let check = await NativeAppUpdates.check(source, fetcher: { _ in feed })
        XCTAssertEqual(check.status, "available")
        let sourceArchive = URL(fileURLWithPath: archive)
        let result = await NativeUpdateTransaction.installAvailable(check, home: home, feedFetcher: { _ in feed }, downloader: { url, destination, length in
            XCTAssertEqual(url.host, "updates.example.test")
            XCTAssertNotNil(length)
            try FileManager.default.copyItem(at: sourceArchive, to: destination)
        })
        XCTAssertEqual(result.outcome, "succeeded", result.message)
        XCTAssertEqual(build(original), "200")
        XCTAssertEqual(result.receipt?.phase, "installed")
    }

    func testDMGDownloadPipelineAcceptsDeclaredFormatAndCleansItsMount() async throws {
        try dmg()
        let source = try XCTUnwrap(NativeAppUpdates.sources(apps: [try XCTUnwrap(AppUninstaller.read(original))]).first)
        let feed = try feedData(format: "dmg")
        let check = await NativeAppUpdates.check(source, fetcher: { _ in feed })
        XCTAssertNil(NativeUpdateTransaction.installationRefusal(check))
        let sourceArchive = URL(fileURLWithPath: archive)
        let result = await NativeUpdateTransaction.installAvailable(check, home: home, feedFetcher: { _ in feed }, downloader: { url, destination, _ in
            XCTAssertEqual(url.pathExtension, "dmg")
            try FileManager.default.copyItem(at: sourceArchive, to: destination)
        })
        XCTAssertEqual(result.outcome, "succeeded", result.message)
        XCTAssertEqual(build(original), "200")
        try assertNoOwnedMountedImages()
    }

    func testFeedChangingBeforeDownloadDoesNotStartAnInstaller() async throws {
        let source = try XCTUnwrap(NativeAppUpdates.sources(apps: [try XCTUnwrap(AppUninstaller.read(original))]).first)
        let initial = try feedData(), changed = try feedData(build: "201")
        let check = await NativeAppUpdates.check(source, fetcher: { _ in initial })
        let result = await NativeUpdateTransaction.installAvailable(check, home: home, feedFetcher: { _ in changed }, downloader: { _, _, _ in
            XCTFail("a changed release must not reach download")
        })
        XCTAssertEqual(result.outcome, "failed")
        XCTAssertEqual(build(original), "100")
    }

    func testRotatingSignedDownloadURLDoesNotChangeAuthenticatedRelease() async throws {
        let source = try XCTUnwrap(NativeAppUpdates.sources(apps: [try XCTUnwrap(AppUninstaller.read(original))]).first)
        let initial = try feedData()
        let check = await NativeAppUpdates.check(source, fetcher: { _ in initial })
        let renewed = try feedData(token: "renewed")
        let sourceArchive = URL(fileURLWithPath: archive)
        let result = await NativeUpdateTransaction.installAvailable(check, home: home, feedFetcher: { _ in renewed }, downloader: { url, destination, _ in
            XCTAssertEqual(url.query, "token=renewed")
            try FileManager.default.copyItem(at: sourceArchive, to: destination)
        })
        XCTAssertEqual(result.outcome, "succeeded", result.message)
        XCTAssertEqual(build(original), "200")
    }

    func testResignedDifferentArchiveCannotReplaceTheReviewedBytes() throws {
        let first = try reviewed()
        var data = try Data(contentsOf: URL(fileURLWithPath: archive))
        data[10] ^= 1 // Change ZIP metadata without changing its length or advertised app version.
        try data.write(to: URL(fileURLWithPath: archive))
        let later = try reviewed()
        XCTAssertThrowsError(try NativeUpdateTransaction.prepare(later, archive: URL(fileURLWithPath: archive), home: home,
                                                                reviewedArchiveSignature: first.release?.signature)) { error in
            XCTAssertEqual(error.localizedDescription, "The downloaded archive differs from the reviewed signed archive")
        }
        XCTAssertEqual(build(original), "100")
    }

    func testWrongBundleIDInAnAuthenticArchiveIsRejected() throws {
        let infoURL = URL(fileURLWithPath: package + "/Contents/Info.plist")
        var info = try XCTUnwrap(NSDictionary(contentsOf: infoURL) as? [String: String])
        info["CFBundleIdentifier"] = "com.example.other-app"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        try execute("/usr/bin/codesign", ["--force", "--sign", "-", package])
        try zip()
        XCTAssertThrowsError(try prepared())
        XCTAssertEqual(build(original), "100")
    }

    func testOriginalSigningRequirementRejectsDifferentAdhocCode() throws {
        // Exercise the designated-requirement branch with synthetic, locally ad-hoc signed code.
        // This does not substitute for Developer ID certificate-rotation acceptance.
        XCTAssertNoThrow(try NativeBundleValidation.publisherMatches(original: original, replacement: original, team: "synthetic-nonempty-team"))
        XCTAssertThrowsError(try NativeBundleValidation.publisherMatches(original: original, replacement: package, team: "synthetic-nonempty-team"))
    }

    func testSignedDMGInstallsRestoresAndLeavesNoMountedVolume() throws {
        try dmg()
        let prepared = try prepared()
        try assertNoOwnedMountedImages()
        let result = NativeUpdateTransaction.commit(prepared, home: home, processes: { ProcessTable(entries: []) }, afterSwap: {})
        XCTAssertEqual(result.outcome, "succeeded", result.message)
        XCTAssertEqual(build(original), "200")
        let restored = NativeUpdateTransaction.recover(try XCTUnwrap(result.receipt).id, home: home, processes: { ProcessTable(entries: []) })
        XCTAssertEqual(restored.outcome, "succeeded", restored.message)
        XCTAssertEqual(build(original), "100")
        try assertNoOwnedMountedImages()
        try NativeUpdateTransaction.discard(prepared, home: home)
    }

    func testSignedZIP64UsesTheSameInstallerAndRecovery() throws {
        try zip64Fixture(Data(contentsOf: URL(fileURLWithPath: archive))).write(to: URL(fileURLWithPath: archive))
        let prepared = try prepared()
        let result = NativeUpdateTransaction.commit(prepared, home: home, processes: { ProcessTable(entries: []) }, afterSwap: {})
        XCTAssertEqual(result.outcome, "succeeded", result.message)
        XCTAssertEqual(build(original), "200")
        let recovered = NativeUpdateTransaction.recover(try XCTUnwrap(result.receipt).id, home: home, processes: { ProcessTable(entries: []) })
        XCTAssertEqual(recovered.outcome, "succeeded", recovered.message)
        XCTAssertEqual(build(original), "100")
    }

    func testDMGWithMultipleAppsFailsAndStillDetaches() throws {
        try makeApp(home + "/package/Other.app", version: "2.0", build: "200", id: "com.example.other")
        try dmg()
        XCTAssertThrowsError(try prepared())
        try assertNoOwnedMountedImages()
        XCTAssertEqual(build(original), "100")
    }

    func testDiskImageLicenseEncryptionAndUnknownMetadataStayOutsideThermo() {
        let valid: [String: Any] = ["Properties": ["Encrypted": false, "Software License Agreement": false, "Checksummed": true],
                                    "Format": "UDZO", "Size Information": ["Total Bytes": 10_000_000]]
        XCTAssertNoThrow(try NativeDiskImage.validateInfo(valid))
        for flag in ["Encrypted", "Software License Agreement", "Checksummed"] {
            var bad = valid
            var properties = valid["Properties"] as! [String: Bool]
            properties[flag] = flag != "Checksummed"
            bad["Properties"] = properties
            XCTAssertThrowsError(try NativeDiskImage.validateInfo(bad))
        }
        XCTAssertThrowsError(try NativeDiskImage.validateInfo([:]))
    }

    func testUnreadableRecoveryRecordDoesNotLookLikeAnEmptyHistory() throws {
        let root = try NativeUpdateTransaction.storage(home)
        try Data("broken receipt".utf8).write(to: URL(fileURLWithPath: root + "/" + UUID().uuidString + ".json"))
        let report = NativeUpdateTransaction.recovery(home: home)
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertFalse(report.issues.isEmpty)
    }

    func testEmptyRecoveryLookupDoesNotCreateStorage() {
        let report = NativeUpdateTransaction.recovery(home: home)
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/Library/Application Support/Thermo/app-updates"))
    }

    func testZIPDirectoryRejectsTraversalAndAbsolutePaths() throws {
        func zip(_ name: String) -> Data {
            var data = Data()
            func number(_ value: UInt64, _ size: Int) { for i in 0..<size { data.append(UInt8((value >> (8 * i)) & 255)) } }
            let filename = Data(name.utf8)
            number(0x04034b50, 4); number(20, 2); number(0x800, 2); number(0, 2)
            number(0, 2); number(0, 2); number(0, 4); number(1, 4); number(1, 4)
            number(UInt64(filename.count), 2); number(0, 2); data.append(filename); data.append(0)
            let offset = data.count
            number(0x02014b50, 4); number(20, 2); number(20, 2); number(0x800, 2); number(0, 2)
            number(0, 2); number(0, 2); number(0, 4); number(1, 4); number(1, 4)
            number(UInt64(filename.count), 2); number(0, 2); number(0, 2); number(0, 2); number(0, 2); number(0, 4); number(0, 4)
            data.append(filename)
            let size = data.count - offset
            number(0x06054b50, 4); number(0, 2); number(0, 2); number(1, 2); number(1, 2)
            number(UInt64(size), 4); number(UInt64(offset), 4); number(0, 2)
            return data
        }
        let url = URL(fileURLWithPath: home + "/manifest.zip")
        try zip("safe-file").write(to: url)
        XCTAssertEqual(try NativeZipManifest.validate(url), 1)
        for name in ["../escape", "/tmp/escape", "Folder/../../escape", "Folder\\escape"] {
            try zip(name).write(to: url)
            XCTAssertThrowsError(try NativeZipManifest.validate(url))
        }
    }
}
