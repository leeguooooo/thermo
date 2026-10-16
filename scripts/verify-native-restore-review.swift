// Local signed-fixture setup/status for the CLI confirmation-wait acceptance.
// Requires a private .thermo-native-review-UUID/Home and marker; never uses real apps/network.
@testable import CleanKit
import AgentCore
import CryptoKit
import Darwin
import Foundation

@main struct NativeRestoreReviewFixture {
    struct Failure: Error { let message: String }
    static func command(_ path: String, _ args: [String]) throws {
        let result = CommandRunner.run(path, arguments: args, timeout: 30)
        guard result.status == 0 else { throw Failure(message: result.output) }
    }
    static func emit(_ value: Any) throws {
        print(String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
    }
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw Failure(message: "setup|status FIXTURE_HOME required") }
        let home = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: home).deletingLastPathComponent()
        let prefix = ".thermo-native-review-"
        var node = stat()
        guard (home as NSString).lastPathComponent == "Home", root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
              lstat(root.path, &node) == 0, node.st_uid == getuid(), node.st_mode & 0o077 == 0,
              FileManager.default.fileExists(atPath: home + "/.thermo-native-review-fixture") else {
            throw Failure(message: "Requires an owned private fixture Home")
        }
        let state = home + "/state.json", target = home + "/Applications/Fixture.app", other = home + "/Applications/Other.app"
        if CommandLine.arguments[1] == "setup" {
            let key = Curve25519.Signing.PrivateKey(), package = home + "/package/Fixture.app", archive = home + "/update.zip"
            func app(_ path: String, version: String, build: String) throws {
                try FileManager.default.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: path + "/Contents/MacOS/Fixture")
                let info = ["CFBundleIdentifier":"com.example.restore-review", "CFBundleShortVersionString":version, "CFBundleVersion":build,
                            "CFBundleExecutable":"Fixture", "CFBundlePackageType":"APPL", "SUFeedURL":"https://updates.example.test/feed.xml",
                            "SUPublicEDKey":key.publicKey.rawRepresentation.base64EncodedString()]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
                try command("/usr/bin/codesign", ["--force", "--sign", "-", path])
            }
            try app(target, version: "1.0", build: "100"); try app(package, version: "2.0", build: "200")
            try command("/usr/bin/ditto", ["-c", "-k", "--keepParent", package, archive])
            guard let installed = AppUninstaller.read(target), let source = NativeAppUpdates.sources(apps: [installed]).first else { throw Failure(message: "source unavailable") }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: archive))
            let release = SparkleRelease(build: "200", version: "2.0", enclosureFingerprint: "owned-fixture", signature: try key.signature(for: bytes).base64EncodedString(), length: Int64(bytes.count), hardware: [])
            let prepared = try NativeUpdateTransaction.prepare(.init(source: source, status: "available", message: "fixture", release: release), archive: URL(fileURLWithPath: archive), home: home)
            let result = NativeUpdateTransaction.commit(prepared, home: home, processes: { .init(entries: []) }, afterSwap: {})
            guard result.outcome == "succeeded", let receipt = result.receipt else { throw Failure(message: result.message) }
            try FileManager.default.copyItem(atPath: target, toPath: other)
            guard try NativeBundleValidation.facts(other).seal == receipt.replacement.seal else { throw Failure(message: "copy differs") }
            try NativeUpdateTransaction.discard(prepared, home: home)
            let recordFile = try NativeUpdateTransaction.storage(home, create: false) + "/" + receipt.id + ".json"
            let value = ["id":receipt.id, "target":target, "other":other, "backup":receipt.backup, "recordFile":recordFile]
            try JSONSerialization.data(withJSONObject: value).write(to: URL(fileURLWithPath: state)); try emit(value)
        } else {
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: state))) as! [String:String]
            let record = try NativeUpdateTransaction.load(value["id"]!, home: home)
            func build(_ path: String) -> String { AppMetadata.dictionary(path + "/Contents/Info.plist")?["CFBundleVersion"] as? String ?? "unknown" }
            try emit(["targetBuild":build(target), "otherBuild":build(other), "backupBuild":build(record.backup), "recordTarget":record.target, "phase":record.phase])
        }
    }
}
