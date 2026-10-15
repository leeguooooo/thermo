// Opt-in acceptance harness. Link against the current Debug CleanKit/AgentCore/
// ThermoL10n objects with -I .build/out/Products/Debug -parse-as-library.
// Arguments: scratch parent, vendor feed snapshot, older DMG, newer DMG,
// optional --download to also exercise the production HTTPS downloader.
// Never launches either app. On failure preserves the owned acceptance directory.
@testable import CleanKit
import AgentCore
import Foundation
import CryptoKit

@main
struct VendorUpdateAcceptance {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
    static func require(_ condition: Bool, _ text: String) throws {
        if !condition { throw Failure(text) }
    }
    static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 || (args.count == 6 && args[5] == "--download") else {
            throw Failure("usage: acceptance SCRATCH FEED OLD_DMG NEW_DMG [--download]")
        }
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath().path
        let root = parent + "/acceptance-" + UUID().uuidString
        try fm.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        print("Owned acceptance directory: " + root)
        fflush(stdout)
        let home = root + "/home", unpacked = root + "/older"
        try NativeUpdateTransaction.privateDirectory(home)
        try NativeUpdateTransaction.privateDirectory(unpacked)
        let feed = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let older = URL(fileURLWithPath: args[3]), newer = URL(fileURLWithPath: args[4])
        try NativeDiskImage.copyApplication(from: older, workspace: root, to: unpacked)
        let apps = try fm.contentsOfDirectory(atPath: unpacked).filter { $0.hasSuffix(".app") }
        try require(apps.count == 1, "The older image must contain one app")
        try fm.createDirectory(atPath: home + "/Applications", withIntermediateDirectories: false)
        let target = home + "/Applications/" + apps[0]
        try fm.moveItem(atPath: unpacked + "/" + apps[0], toPath: target)
        let old = try NativeBundleValidation.facts(target)
        try require(old.team != nil, "Vendor acceptance requires a real signed team")
        func review() async throws -> NativeUpdateCheck {
            guard let app = AppUninstaller.read(target), let source = NativeAppUpdates.sources(apps: [app]).first else { throw Failure("No vendor source") }
            let check = await NativeAppUpdates.check(source, fetcher: { _ in feed })
            try require(check.status == "available", "No compatible update: " + check.message)
            try require(NativeUpdateTransaction.installationRefusal(check) == nil, "The vendor release cannot be installed by this path")
            return check
        }
        let checked = try await review()
        // Corrupt only a private archive copy; authentication must fail before swap.
        var corrupt = try Data(contentsOf: newer)
        try require(corrupt.count > 1024, "Empty vendor archive")
        corrupt[1024] ^= 1
        let bad = URL(fileURLWithPath: root + "/corrupt.dmg")
        try corrupt.write(to: bad)
        var rejected = false
        do {
            let unexpected = try NativeUpdateTransaction.prepare(checked, archive: bad, home: home)
            try NativeUpdateTransaction.discard(unexpected, home: home)
        } catch { rejected = true }
        try require(rejected, "A modified vendor archive was accepted")
        try require(try NativeBundleValidation.treeSeal(target) == old.seal, "Signature failure changed the original")
        try fm.removeItem(at: bad)
        print("Modified archive rejected; original unchanged")
        fflush(stdout)
        let prepared = try NativeUpdateTransaction.prepare(checked, archive: newer, home: home)
        let installed = NativeUpdateTransaction.install(prepared, home: home)
        try require(installed.outcome == "succeeded", installed.message)
        guard let receipt = installed.receipt else { throw Failure("Missing recovery receipt") }
        let new = try NativeBundleValidation.facts(target)
        try require(try NativeBundleValidation.treeSeal(receipt.backup) == old.seal, "Backup differs from the vendor original")
        try NativeUpdateTransaction.discard(prepared, home: home)
        let restored = NativeUpdateTransaction.restore(receipt.id, home: home)
        try require(restored.outcome == "succeeded", restored.message)
        try require(try NativeBundleValidation.treeSeal(target) == old.seal, "Restored vendor bytes differ")
        try require(try NativeBundleValidation.treeSeal(receipt.backup) == new.seal, "Recovery did not preserve the newer app")
        let repeatRestore = NativeUpdateTransaction.restore(receipt.id, home: home)
        try require(repeatRestore.outcome == "succeeded", repeatRestore.message)
        print("Vendor update installed and restored; repeat recovery succeeded")
        fflush(stdout)
        let second = try NativeUpdateTransaction.prepare(try await review(), archive: newer, home: home)
        let rollback = NativeUpdateTransaction.commit(second, home: home,
            processes: { ProcessTable.current(.init(cpu: false)) }, afterSwap: { throw Failure("Injected post-swap validation failure") })
        try require(rollback.outcome == "failed" && rollback.receipt?.phase == "rolledBack", rollback.message)
        try require(try NativeBundleValidation.treeSeal(target) == old.seal, "Post-swap failure did not restore original vendor bytes")
        try NativeUpdateTransaction.discard(second, home: home)
        let verifyDownload = args.count == 6
        if verifyDownload {
            let downloaded = await NativeUpdateTransaction.installAvailable(try await review(), home: home, feedFetcher: { _ in feed })
            try require(downloaded.outcome == "succeeded", downloaded.message)
            try require(try NativeBundleValidation.treeSeal(target) == new.seal, "Production download installed different vendor bytes")
            guard let downloadedReceipt = downloaded.receipt else { throw Failure("Downloaded update has no recovery receipt") }
            let recovered = NativeUpdateTransaction.restore(downloadedReceipt.id, home: home)
            try require(recovered.outcome == "succeeded", recovered.message)
            try require(try NativeBundleValidation.treeSeal(target) == old.seal, "Downloaded update recovery changed original vendor bytes")
            print("Production HTTPS download installed and recovered identical vendor bytes")
            fflush(stdout)
        }
        let mounted = try NativeDiskImage.plist(CommandRunner.run("/usr/bin/hdiutil", arguments: ["info", "-plist"], timeout: 15))
        guard let images = mounted["images"] as? [[String: Any]] else { throw Failure("Cannot verify image cleanup") }
        try require(!images.contains { ($0["image-path"] as? String).map { NativeDiskImage.canonical($0).hasPrefix(parent + "/") } == true }, "An owned vendor image is still mounted")
        let evidence: [String: Any] = [
            "bundleID": old.bundleID, "team": old.team!, "oldVersion": old.version, "oldBuild": old.build,
            "newVersion": new.version, "newBuild": new.build, "architectures": new.architectures,
            "oldSeal": old.seal, "newSeal": new.seal, "oldArchiveSHA256": try digest(older), "newArchiveSHA256": try digest(newer),
            "feedSHA256": try digest(URL(fileURLWithPath: args[2])), "modifiedArchiveRejected": rejected,
            "installed": true, "restored": true, "repeatRecovery": true, "postSwapFailureRolledBack": true,
            "ownedImagesDetached": true, "vendorAppLaunched": false, "installedApplicationsChanged": false,
            "productionHTTPSDownloadVerified": verifyDownload
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: parent + "/acceptance-result.json"))
        try fm.removeItem(atPath: root)
        print("PASS: vendor acceptance; owned acceptance directory removed")
    }
    static func main() async {
        do { try await run() }
        catch {
            fputs("FAIL (preserving owned workspace): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
