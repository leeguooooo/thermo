import AgentCore
import Darwin
import XCTest
@testable import CleanKit

final class AppMetadataTests: XCTestCase {
    var root = "", app = "", file = ""
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("app-metadata-" + UUID().uuidString).resolvingSymlinksInPath().path
        app = root + "/Fixture.app"; file = app + "/Contents/Info.plist"
        try FileManager.default.createDirectory(atPath: app + "/Contents", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: root) }
    @discardableResult func write(_ format: PropertyListSerialization.PropertyListFormat = .xml, extra: [String: Any] = [:]) throws -> Data {
        let info: [String: Any] = ["CFBundleIdentifier":"com.example.one", "CFBundleVersion":"1", "SUFeedURL":"https://updates.example.test/feed?token=SYNTHETIC_META_SECRET"].merging(extra) { _, value in value }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
        try data.write(to: URL(fileURLWithPath: file), options: .atomic); return data
    }
    func testXMLAndBinaryMetadataAreBoundToIdentityWithoutExportingRawFields() throws {
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            try write(format)
            let snapshot = try XCTUnwrap(AppMetadata.read(file))
            XCTAssertEqual(snapshot.info["CFBundleIdentifier"] as? String, "com.example.one")
            let identity = try XCTUnwrap(AppReviewIdentity.capture(app))
            XCTAssertEqual(identity.files["/Contents/Info.plist#sha256"], snapshot.digest)
            let encoded = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
            XCTAssertFalse(encoded.contains("SYNTHETIC_META_SECRET"))
            XCTAssertNotNil(AppUninstaller.read(app)?.inventoryIdentity)
        }
    }
    func testFIFOIsNotAReadableOrVerifiedMetadataFile() throws {
        XCTAssertEqual(mkfifo(file, 0o600), 0)
        XCTAssertNil(AppMetadata.read(file)); XCTAssertNil(AppReviewIdentity.capture(app))
        let visible = try XCTUnwrap(AppUninstaller.read(app))
        XCTAssertNil(visible.inventoryIdentity)
        let source = try XCTUnwrap(NativeAppUpdates.sources(apps: [visible]).first)
        XCTAssertNotNil(source.blocked); XCTAssertFalse(source.canCheck)
    }
    func testDirectorySymlinkAndOversizedSparseFileAreRejected() throws {
        try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false)
        XCTAssertNil(AppMetadata.read(file)); XCTAssertNil(AppReviewIdentity.capture(app))
        try FileManager.default.removeItem(atPath: file)
        let other = root + "/other.plist"; try Data("outside".utf8).write(to: URL(fileURLWithPath: other))
        try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: other)
        XCTAssertNil(AppMetadata.read(file)); XCTAssertNil(AppReviewIdentity.capture(app))
        try FileManager.default.removeItem(atPath: file)
        FileManager.default.createFile(atPath: file, contents: Data())
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        try handle.truncate(atOffset: UInt64(AppMetadata.maxBytes + 1)); try handle.close()
        XCTAssertNil(AppMetadata.read(file)); XCTAssertNil(AppReviewIdentity.capture(app))
    }
    func testReplacementAndInPlaceMutationDuringReadAreRejected() throws {
        let data = try write()
        XCTAssertNil(AppMetadata.read(file, afterRead: { try! data.write(to: URL(fileURLWithPath: self.file), options: .atomic) }))
        try write()
        let changed = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "com.example.one", with: "com.example.two").utf8)
        XCTAssertEqual(data.count, changed.count)
        XCTAssertNil(AppMetadata.read(file, afterRead: {
            let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: self.file))
            try! handle.write(contentsOf: changed); try! handle.close()
        }))
    }
    func testParsedSnapshotCannotBindToAReplacementAtSamePath() throws {
        let data = try write(), snapshot = try XCTUnwrap(AppMetadata.read(file))
        try data.write(to: URL(fileURLWithPath: file), options: .atomic)
        XCTAssertNil(AppReviewIdentity.capture(app, metadata: snapshot))
        XCTAssertNotNil(AppReviewIdentity.capture(app))
    }
    func testMalformedMetadataAndSpecialDeclaredKeyFilesDoNotEstablishIdentity() throws {
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertNil(AppReviewIdentity.capture(app))
        try write(extra: ["CFBundleExecutable":42])
        XCTAssertNil(AppReviewIdentity.capture(app))
        try write(extra: ["CFBundleExecutable":"Main"])
        try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS/Main", withIntermediateDirectories: true)
        XCTAssertNil(AppReviewIdentity.capture(app))
        try write()
        try FileManager.default.createDirectory(atPath: app + "/Contents/_CodeSignature", withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(app + "/Contents/_CodeSignature/CodeResources", 0o600), 0)
        XCTAssertNil(AppReviewIdentity.capture(app))
    }
    func testCancellationDoesNotPublishParsedMetadata() throws {
        try write()
        let old = ScanCancellation.current, token = ScanCancellation(); token.cancel()
        ScanCancellation.current = token; defer { ScanCancellation.current = old }
        XCTAssertNil(AppMetadata.read(file)); XCTAssertNil(AppReviewIdentity.capture(app))
    }
}
