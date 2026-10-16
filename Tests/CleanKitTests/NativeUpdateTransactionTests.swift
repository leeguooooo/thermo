@testable import AgentCore
@testable import CleanKit
import CryptoKit
import Darwin
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
        for path in try ownedMountedImages() {
            guard NativeDiskImage.detachOwned(path) else { throw ArchiveFailure("Temporary test image cleanup unconfirmed; preserve " + home) }
        }
        guard try ownedImageRecords().isEmpty else { throw ArchiveFailure("Temporary test images remain; preserve " + home) }
        try FileManager.default.removeItem(atPath: home)
    }

    func ownedMountedImages() throws -> [String] {
        try ownedImageRecords().compactMap { $0["image-path"] as? String }
            .filter { NativeDiskImage.canonical($0).hasPrefix(home + "/") }
    }

    func ownedImageRecords() throws -> [[String: Any]] {
        let result = CommandRunner.run("/usr/bin/hdiutil", arguments: ["info", "-plist"], timeout: 15)
        let info = try NativeDiskImage.plist(result)
        guard let images = info["images"] as? [[String: Any]] else { throw ArchiveFailure("Image inventory was incomplete") }
        return images.filter { image in
            (image["image-path"] as? String).map { NativeDiskImage.canonical($0).hasPrefix(home + "/") } == true ||
            (image["system-entities"] as? [[String: Any]])?.contains {
                ($0["mount-point"] as? String).map { NativeDiskImage.canonical($0).hasPrefix(home + "/") } == true
            } == true
        }
    }

    func assertNoOwnedMountedImages(file: StaticString = #filePath, line: UInt = #line) throws {
        let records = try ownedImageRecords()
        let summary = records.map { ["image-path": $0["image-path"] ?? "unknown", "system-entities": $0["system-entities"] ?? []] }
        XCTAssertTrue(records.isEmpty, "unexpected owned images: \(summary)", file: file, line: line)
    }

    func dmg() throws {
        archive = home + "/update.dmg"
        try execute("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", (package as NSString).deletingLastPathComponent,
                                        "-format", "UDZO", archive])
        // Image creation may temporarily attach its own backing file. Establish
        // a clean fixture baseline instead of attributing it to the updater.
        if try ownedMountedImages().contains(where: { NativeDiskImage.canonical($0) == NativeDiskImage.canonical(archive) }) {
            guard NativeDiskImage.detachOwned(archive) else { throw ArchiveFailure("Created fixture image is still busy; preserve " + home) }
        }
        guard try ownedImageRecords().isEmpty else { throw ArchiveFailure("Fixture creation left an attachment; preserve " + home) }
    }

    func execute(_ executable: String, _ args: [String]) throws {
        let result = CommandRunner.run(executable, arguments: args, timeout: 30)
        guard result.status == 0 else { throw ArchiveFailure("Command exited \(result.status): " + result.output) }
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
        XCTAssertFalse(OperationJournal.read(home: home).contains { $0.action == "nativeUpdatePreparation" })
        XCTAssertNil(result.cleanupIssue)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: NativeUpdateTransaction.storage(home)).filter { $0.hasPrefix("download-") }.isEmpty)
    }

    func testPartialDownloadFailureClearsItsOwnFilesWithoutChangingTheApp() async throws {
        let source = try XCTUnwrap(NativeAppUpdates.sources(apps: [try XCTUnwrap(AppUninstaller.read(original))]).first)
        let feed = try feedData(), fixtureHome = home
        let check = await NativeAppUpdates.check(source, fetcher: { _ in feed })
        let result = await NativeUpdateTransaction.installAvailable(check, home: home, feedFetcher: { _ in feed }, downloader: { _, destination, _ in
            try Data("partial".utf8).write(to: destination)
            throw ArchiveFailure("injected partial download failure")
        })
        XCTAssertEqual(result.outcome, "failed"); XCTAssertNil(result.cleanupIssue); XCTAssertTrue(result.workspacePreservations.isEmpty)
        XCTAssertEqual(build(original), "100")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: NativeUpdateTransaction.storage(fixtureHome)).filter { $0.hasPrefix("download-") }.isEmpty)
    }

    func testDownloadDirectoryReplacementIsKeptAndReportedAfterDownloadError() async throws {
        let source = try XCTUnwrap(NativeAppUpdates.sources(apps: [try XCTUnwrap(AppUninstaller.read(original))]).first)
        let feed = try feedData()
        let check = await NativeAppUpdates.check(source, fetcher: { _ in feed })
        let result = await NativeUpdateTransaction.installAvailable(check, home: home, feedFetcher: { _ in feed }, downloader: { _, destination, _ in
            let directory = destination.deletingLastPathComponent().path
            try Data("partial".utf8).write(to: destination)
            try FileManager.default.moveItem(atPath: directory, toPath: directory + "-kept")
            try NativeUpdateTransaction.privateDirectory(directory)
            try Data("replacement".utf8).write(to: URL(fileURLWithPath: directory + "/marker"))
            throw ArchiveFailure("injected download error after replacement")
        })
        XCTAssertEqual(result.outcome, "failed"); XCTAssertNotNil(result.cleanupIssue)
        let record = try XCTUnwrap(result.preservedWorkspace)
        XCTAssertEqual(record.kind, "download"); XCTAssertEqual(result.workspaceRecordSaved, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path + "/marker"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path + "-kept/payload.archive"))
        XCTAssertThrowsError(try NativeUpdateTransaction.preservedWorkspaceURL(record, home: home))
        XCTAssertEqual(build(original), "100")
    }

    func testBothCleanupFailuresRemainDiscoverableWithoutChangingInstallResult() throws {
        let value = try prepared()
        let first = NativeUpdateTransaction.installAndDiscard(value, home: home, cleanup: { _, _ in throw ArchiveFailure("prepared cleanup fault") })
        let directory = try NativeUpdateTransaction.storage(home) + "/download-" + UUID().uuidString
        try NativeUpdateTransaction.privateDirectory(directory)
        let result = NativeUpdateTransaction.finishDownload(first, directory: directory, identity: try XCTUnwrap(FileIdentity.of(directory)),
            source: value.source, home: home, remove: { _ in throw ArchiveFailure("download cleanup fault") })
        XCTAssertEqual(result.outcome, "succeeded"); XCTAssertEqual(result.receipt?.phase, "installed")
        XCTAssertEqual(result.workspacePreservations.count, 2)
        XCTAssertTrue(result.workspacePreservations.allSatisfy(\.recorded))
        for item in result.workspacePreservations { XCTAssertNoThrow(try NativeUpdateTransaction.preservedWorkspaceURL(item.workspace, home: home)) }
        let report = NativeUpdateTransaction.recovery(home: home)
        XCTAssertEqual(report.workspaces?.count, 2); XCTAssertEqual(report.records.count, 1)
        XCTAssertEqual(build(original), "200"); XCTAssertEqual(build(try XCTUnwrap(result.receipt?.backup)), "100")
    }

    func testAdditionalCleanupRecordFailureDoesNotHideItsDirectPath() throws {
        let value = try prepared()
        let first = NativeUpdateTransaction.installAndDiscard(value, home: home, cleanup: { _, _ in throw ArchiveFailure("prepared cleanup fault") })
        let id = UUID().uuidString, root = try NativeUpdateTransaction.storage(home)
        let directory = root + "/download-" + id
        try NativeUpdateTransaction.privateDirectory(directory)
        try FileManager.default.createDirectory(atPath: root + "/workspace-" + id + ".json", withIntermediateDirectories: false)
        let result = NativeUpdateTransaction.finishDownload(first, directory: directory, identity: try XCTUnwrap(FileIdentity.of(directory)),
            source: value.source, home: home, remove: { _ in throw ArchiveFailure("download cleanup fault") })
        XCTAssertEqual(result.outcome, "succeeded"); XCTAssertEqual(result.workspaceRecordSaved, true)
        XCTAssertEqual(result.additionalPreservedWorkspaces?.first?.recorded, false)
        XCTAssertEqual(result.additionalPreservedWorkspaces?.first?.workspace.path, directory)
        XCTAssertNoThrow(try NativeUpdateTransaction.preservedWorkspaceURL(try XCTUnwrap(result.additionalPreservedWorkspaces?.first?.workspace), home: home))
    }

    func testCleanupFailureDoesNotChangeConfirmedInstallationResultOrLoseRecoveryCopy() throws {
        let value = try prepared()
        let result = NativeUpdateTransaction.installAndDiscard(value, home: home, cleanup: { _, _ in throw ArchiveFailure("injected discard failure") })
        XCTAssertEqual(result.outcome, "succeeded"); XCTAssertEqual(result.receipt?.phase, "installed")
        XCTAssertNotNil(result.cleanupIssue); XCTAssertEqual(result.workspaceRecordSaved, true)
        XCTAssertEqual(build(original), "200")
        XCTAssertEqual(build(try XCTUnwrap(result.receipt?.backup)), "100")
        let record = try XCTUnwrap(result.preservedWorkspace)
        XCTAssertNoThrow(try NativeUpdateTransaction.preservedWorkspaceURL(record, home: home))
        let report = NativeUpdateTransaction.recovery(home: home)
        XCTAssertEqual(report.records.count, 1); XCTAssertEqual(report.workspaces?.count, 1)
        let events = OperationJournal.read(home: home)
        XCTAssertEqual(events.filter { $0.action == "nativeUpdateCleanup" }.count, 1)
        XCTAssertTrue(events.contains { $0.action == "nativeUpdate" && $0.outcome == "succeeded" })
        XCTAssertEqual(events.first { $0.action == "nativeUpdateCleanup" }?.outcome, "partial")
        let recovered = NativeUpdateTransaction.restore(try XCTUnwrap(result.receipt?.id), home: home)
        XCTAssertEqual(recovered.outcome, "succeeded"); XCTAssertEqual(build(original), "100")
    }

    func testNormalPostInstallCleanupRemovesOnlyPreparedWorkspace() throws {
        let value = try prepared()
        let result = NativeUpdateTransaction.installAndDiscard(value, home: home)
        XCTAssertEqual(result.outcome, "succeeded"); XCTAssertNil(result.cleanupIssue); XCTAssertNil(result.preservedWorkspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: value.workspace))
        XCTAssertEqual(build(original), "200")
        XCTAssertEqual(build(try XCTUnwrap(result.receipt?.backup)), "100")
        XCTAssertFalse(OperationJournal.read(home: home).contains { $0.action == "nativeUpdateCleanup" })
    }

    func testCleanupFailureAlsoPreservesAnUnchangedFailedInstallationResult() throws {
        let value = try prepared()
        try Data("changed prepared bytes".utf8).write(to: URL(fileURLWithPath: value.bundle + "/Contents/Resources/data"))
        let result = NativeUpdateTransaction.installAndDiscard(value, home: home, cleanup: { _, _ in throw ArchiveFailure("injected discard failure") })
        XCTAssertEqual(result.outcome, "failed"); XCTAssertNil(result.receipt)
        XCTAssertNotNil(result.cleanupIssue); XCTAssertNotNil(result.preservedWorkspace)
        XCTAssertEqual(build(original), "100")
    }

    func testReplacedWorkspaceIsNeverDeletedDuringPostInstallCleanup() throws {
        let value = try prepared()
        try FileManager.default.moveItem(atPath: value.workspace, toPath: value.workspace + "-kept")
        try NativeUpdateTransaction.privateDirectory(value.workspace)
        try Data("replacement".utf8).write(to: URL(fileURLWithPath: value.workspace + "/replacement.txt"))
        let result = NativeUpdateTransaction.installAndDiscard(value, home: home)
        XCTAssertEqual(result.outcome, "failed"); XCTAssertNotNil(result.cleanupIssue)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: value.workspace + "/replacement.txt")), Data("replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: value.workspace + "-kept/payload.archive"))
        XCTAssertThrowsError(try NativeUpdateTransaction.preservedWorkspaceURL(try XCTUnwrap(result.preservedWorkspace), home: home))
        XCTAssertEqual(build(original), "100")
    }

    func testAuthenticatedPreparationCleanupFailurePersistsItsWorkspaceBeforeThrowing() throws {
        var image = Data(repeating: 0, count: 1024)
        image.replaceSubrange(512..<516, with: [0x6b, 0x6f, 0x6c, 0x79])
        try image.write(to: URL(fileURLWithPath: archive))
        var captured: NativeUpdateTransaction.PreservedWorkspaceFailure?
        do {
            _ = try NativeUpdateTransaction.prepare(reviewed(), archive: URL(fileURLWithPath: archive), home: home,
                copyImage: { _, _, _ in throw NativeDiskImage.CleanupFailure() })
            XCTFail("Expected preserved preparation failure")
        } catch let failure as NativeUpdateTransaction.PreservedWorkspaceFailure { captured = failure }
        let failure = try XCTUnwrap(captured)
        XCTAssertTrue(failure.recorded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failure.workspace.path + "/payload.archive"))
        XCTAssertNoThrow(try NativeUpdateTransaction.preservedWorkspaceURL(failure.workspace, home: home))
        XCTAssertEqual(build(original), "100")
        XCTAssertEqual(NativeUpdateTransaction.recovery(home: home).workspaces?.count, 1)
    }

    func testReplacedWorkspaceIsPreservedEvenWhenPreparationThrowsAnOrdinaryError() throws {
        var image = Data(repeating: 0, count: 1024)
        image.replaceSubrange(512..<516, with: [0x6b, 0x6f, 0x6c, 0x79])
        try image.write(to: URL(fileURLWithPath: archive))
        var path: String?
        do {
            _ = try NativeUpdateTransaction.prepare(reviewed(), archive: URL(fileURLWithPath: archive), home: home, copyImage: { _, workspace, _ in
                path = workspace
                try FileManager.default.moveItem(atPath: workspace, toPath: workspace + "-kept")
                try NativeUpdateTransaction.privateDirectory(workspace)
                try Data("replacement must stay".utf8).write(to: URL(fileURLWithPath: workspace + "/replacement.txt"))
                throw ArchiveFailure("ordinary injected preparation error")
            })
            XCTFail("Expected preserved workspace failure")
        } catch let error as NativeUpdateTransaction.PreservedWorkspaceFailure {
            XCTAssertTrue(error.recorded)
            XCTAssertThrowsError(try NativeUpdateTransaction.preservedWorkspaceURL(error.workspace, home: home))
        }
        let workspace = try XCTUnwrap(path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: workspace + "/replacement.txt")), Data("replacement must stay".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace + "-kept/payload.archive"))
        XCTAssertEqual(build(original), "100")
        XCTAssertEqual(NativeUpdateTransaction.recovery(home: home).workspaces?.count, 1)
    }

    func testPreparationFailureReturnsPreservedPathAndRecordsInspectionHistory() async throws {
        let source = try XCTUnwrap(NativeAppUpdates.sources(apps: [try XCTUnwrap(AppUninstaller.read(original))]).first)
        let feed = try feedData()
        let check = await NativeAppUpdates.check(source, fetcher: { _ in feed })
        let root = try NativeUpdateTransaction.storage(home), fixtureHome = home
        let result = await NativeUpdateTransaction.installAvailable(check, home: home, feedFetcher: { _ in feed }, downloader: { _, _, _ in
            let workspace = root + "/" + UUID().uuidString
            try NativeUpdateTransaction.privateDirectory(workspace)
            throw NativeUpdateTransaction.preserveWorkspace(workspace, identity: try XCTUnwrap(FileIdentity.of(workspace)),
                target: source.app.path, reason: "cleanup unconfirmed fixture", home: fixtureHome)
        })
        XCTAssertEqual(result.outcome, "failed"); XCTAssertEqual(result.workspaceRecordSaved, true)
        let workspace = try XCTUnwrap(result.preservedWorkspace)
        XCTAssertNoThrow(try NativeUpdateTransaction.preservedWorkspaceURL(workspace, home: home))
        XCTAssertEqual(build(original), "100")
        let records = OperationJournal.read(home: home).filter { $0.action == "nativeUpdatePreparation" }
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records.first?.outcome, "partial")
        XCTAssertEqual(records.first?.undo?.kind, "nativePreparation"); XCTAssertEqual(records.first?.undo?.ref, workspace.id)
    }

    func testCancelledFeedRecheckRecordsAStoppedPreparationWithoutDownloading() async throws {
        let source = try XCTUnwrap(NativeAppUpdates.sources(apps: [try XCTUnwrap(AppUninstaller.read(original))]).first)
        let feed = try feedData()
        let check = await NativeAppUpdates.check(source, fetcher: { _ in feed })
        let result = await NativeUpdateTransaction.installAvailable(check, home: home, feedFetcher: { _ in throw CancellationError() },
            downloader: { _, _, _ in XCTFail("Cancelled recheck must not download") })
        XCTAssertEqual(result.message, "Update preparation stopped; the installed app was not replaced")
        XCTAssertNil(result.preservedWorkspace); XCTAssertEqual(build(original), "100")
        let history = OperationJournal.read(home: home).filter { $0.action == "nativeUpdatePreparation" }
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history.first?.outcome, "failed")
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

    func testPrivateUpdateCopyDoesNotDetachAnAlreadyMountedOriginalImage() throws {
        try dmg()
        let mount = home + "/original-mounted"
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
        let mountIdentity = try XCTUnwrap(FileIdentity.of(mount))
        for attempt in 0..<3 {
            let result = CommandRunner.run("/usr/bin/hdiutil", arguments: ["attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", "-mountpoint", mount, archive], timeout: 30)
            if result.status == 0 { break }
            guard attempt < 2, !result.timedOut, !result.cancelled,
                  [EAGAIN, EBUSY].contains(result.status), try ownedImageRecords().isEmpty,
                  FileIdentity.of(mount) == mountIdentity else { throw ArchiveFailure("Fixture attach exited \(result.status): " + result.output) }
            usleep(200_000)
        }
        let before = try ownedMountedImages()
        XCTAssertEqual(before.map(NativeDiskImage.canonical), [NativeDiskImage.canonical(archive)])
        let prepared = try prepared()
        let result = NativeUpdateTransaction.install(prepared, home: home)
        XCTAssertEqual(result.outcome, "succeeded", result.message)
        try NativeUpdateTransaction.discard(prepared, home: home)
        XCTAssertEqual(try ownedMountedImages().map(NativeDiskImage.canonical), [NativeDiskImage.canonical(archive)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount + "/Fixture.app/Contents/Info.plist"))
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
