@testable import CleanKit
import Foundation
import XCTest

final class NativeAppUpdatesTests: XCTestCase {
    private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
        func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
        func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
    }
    var home = "", path = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        path = home + "/Applications/FeedFixture.app"
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        try writeInfo()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func writeInfo(build: String = "100", feed: String = "https://updates.example.test/appcast.xml?token=SYNTHETIC_FEED_SECRET") throws {
        let info = ["CFBundleIdentifier": "com.example.feedfixture", "CFBundleShortVersionString": "1.0", "CFBundleVersion": build, "SUFeedURL": feed]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"), options: .atomic)
    }
    func source() throws -> NativeUpdateSource {
        let app = try XCTUnwrap(AppUninstaller.read(path))
        return try XCTUnwrap(NativeAppUpdates.sources(home: home, apps: [app]).first)
    }
    func xml(_ items: String) -> Data {
        Data("<rss version=\"2.0\" xmlns:s=\"\(SparkleFeed.namespace)\"><channel>\(items)</channel></rss>".utf8)
    }
    func item(_ build: String, extra: String = "", attributes: String = "") -> String {
        "<item><s:version>\(build)</s:version><s:shortVersionString>2.0</s:shortVersionString>\(extra)<enclosure url=\"https://downloads.example.test/App.zip?token=SYNTHETIC_DOWNLOAD_SECRET\" \(attributes)/></item>"
    }
    func check(_ data: Data) async throws -> NativeUpdateCheck {
        await NativeAppUpdates.check(try source(), fetcher: { _ in data }, systemVersion: "14.0", architecture: "arm64")
    }

    func testDiscoveryDoesNotExportPrivateFeedQueries() throws {
        let source = try source()
        XCTAssertEqual(source.kind, "sparkle")
        XCTAssertEqual(source.feedHost, "updates.example.test")
        XCTAssertTrue(source.canCheck)
        let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SYNTHETIC_FEED_SECRET"))
        XCTAssertFalse(encoded.contains("appcast.xml"))
    }

    func testNamespaceAliasAndRecommendedVersionElementSelectNewerBuild() async throws {
        let result = try await check(xml(item("101")))
        XCTAssertEqual(result.status, "available")
        XCTAssertEqual(result.release?.build, "101")
        XCTAssertEqual(result.release?.version, "2.0")
        XCTAssertEqual(result.release?.downloadHost, "downloads.example.test")
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SYNTHETIC_FEED_SECRET"))
        XCTAssertFalse(encoded.contains("SYNTHETIC_DOWNLOAD_SECRET"))
    }

    func testEnclosureAttributesAndRelativeURLsAreSupported() async throws {
        let data = xml("<item><enclosure url=\"app.zip\" s:version=\"102\" s:shortVersionString=\"2.1\"/></item>")
        let result = try await check(data)
        XCTAssertEqual(result.release?.build, "102")
        XCTAssertEqual(result.release?.downloadURL?.path, "/app.zip")
    }

    func testBuildVersionIsComparedInsteadOfMarketingVersion() async throws {
        let result = try await check(xml(item("99", extra: "<title>Marketing 99.0</title>")))
        XCTAssertEqual(result.status, "noNewerCompatibleVersion")
        XCTAssertNil(result.release)
    }

    func testBetaAndDeltaOnlyFeedsDoNotClaimThereAreNoUpdates() async throws {
        for data in [xml(item("102", extra: "<s:channel>beta</s:channel>")), xml(item("102", attributes: "s:deltaFrom=\"100\""))] {
            let result = try await check(data)
            XCTAssertEqual(result.status, "manual")
            XCTAssertNil(result.release)
            XCTAssertFalse(result.skipped.isEmpty)
        }
    }

    func testIncompatibleLatestDoesNotHideCompatibleIntermediateRelease() async throws {
        let data = xml(item("102", extra: "<s:minimumSystemVersion>99.0</s:minimumSystemVersion>") + item("101"))
        let result = try await check(data)
        XCTAssertEqual(result.release?.build, "101")
        XCTAssertFalse(result.skipped.isEmpty)
    }

    func testOtherOSArchitectureAndUnknownHardwareAreNotSelected() async throws {
        for data in [xml(item("102", attributes: "s:os=\"windows\"")), xml(item("102", attributes: "s:arch=\"x86_64\"")),
                     xml(item("102", extra: "<s:hardwareRequirements>unknown-hardware</s:hardwareRequirements>"))] {
            let result = try await check(data)
            XCTAssertNil(result.release)
            XCTAssertEqual(result.status, "manual")
        }
    }

    func testMaximumOSAndMinimumUpdateBuildAreEnforced() async throws {
        for data in [xml(item("102", extra: "<s:maximumSystemVersion>13.0</s:maximumSystemVersion>")),
                     xml(item("102", extra: "<s:minimumUpdateVersion>101</s:minimumUpdateVersion>"))] {
            let result = try await check(data)
            XCTAssertNil(result.release)
        }
    }

    func testAppChangingDuringFetchInvalidatesResult() async throws {
        let source = try source()
        let data = xml(item("102"))
        let result = await NativeAppUpdates.check(source, fetcher: { _ in
            try self.writeInfo(build: "101")
            return data
        })
        XCTAssertEqual(result.status, "changed")
        XCTAssertNil(result.release)
    }

    func testMalformedEntityAndOversizedFeedsFailInsteadOfLookingCurrent() async throws {
        let internalEntity = Data("<!DOCTYPE rss [<!ENTITY value '102'>]><rss><channel><item><version>&value;</version></item></channel></rss>".utf8)
        for data in [Data("not XML".utf8), internalEntity, Data(repeating: 0, count: NativeAppUpdates.feedLimit + 1)] {
            let result = try await check(data)
            XCTAssertEqual(result.status, "failed")
            XCTAssertNil(result.release)
        }
    }

    func testHTMLDoctypeInReleaseNotesIsNotTreatedAsAnXMLDeclaration() async throws {
        let data = xml(item("101", extra: "<description><![CDATA[<!DOCTYPE html><html>release notes</html>]]></description>"))
        let result = try await check(data)
        XCTAssertEqual(result.status, "available")
    }

    func testAppStoreReceiptHasPriorityOverSparkleMetadata() throws {
        try FileManager.default.createDirectory(atPath: path + "/Contents/_MASReceipt", withIntermediateDirectories: true)
        try Data("synthetic receipt".utf8).write(to: URL(fileURLWithPath: path + "/Contents/_MASReceipt/receipt"))
        XCTAssertEqual(try source().kind, "appStore")
        XCTAssertFalse(try source().canCheck)
    }

    func testUnsafeFeedCanStillBeHandedToTheUnchangedAppWithoutFetching() async throws {
        try writeInfo(feed: "http://updates.example.test/feed.xml")
        let source = try source()
        XCTAssertFalse(source.canCheck)
        XCTAssertTrue(NativeAppUpdates.unchanged(source, requireFeed: false))
        let result = await NativeAppUpdates.check(source, fetcher: { _ in XCTFail("must not fetch"); return Data() })
        XCTAssertEqual(result.status, "manual")
    }

    func testUnsafeNetworkSchemesAreRejectedBeforeAnySession() async {
        do { _ = try await NativeAppUpdates.fetch(URL(string: "file:///not-a-feed")!); XCTFail("must refuse") }
        catch { }
    }

    func testCancellationStopsTheFetchWithoutPublishingAnUpdate() async throws {
        let source = try source()
        let started = expectation(description: "fetch started")
        let task = Task {
            await NativeAppUpdates.check(source, fetcher: { _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return Data()
            })
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.status, "cancelled")
        XCTAssertNil(result.release)
    }

    func testItemsOutsideTheRSSChannelAreNotUpdateCandidates() async throws {
        let data = Data("<rss xmlns:s=\"\(SparkleFeed.namespace)\"><channel/> <other>\(item("999"))</other></rss>".utf8)
        let result = try await check(data)
        XCTAssertNil(result.release)
        let duplicateChannels = Data("<rss><channel/><channel/></rss>".utf8)
        let rejected = try await check(duplicateChannels)
        XCTAssertEqual(rejected.status, "failed")
    }

    func testFeedChecksNeverUseProposedPasswordsSSOOrClientCertificates() {
        let delegate = NativeAppUpdates.FeedRedirects()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://updates.example.test/feed")!) // Never resumed.
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNegotiate,
                       NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodServerTrust] {
            let space = URLProtectionSpace(host: "updates.example.test", port: 443, protocol: "https", realm: nil, authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: space,
                proposedCredential: URLCredential(user: "synthetic-user", password: "synthetic-password", persistence: .none),
                previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
            var completions = 0
            let complete: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = { disposition, credential in
                XCTAssertEqual(disposition, method == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge)
                XCTAssertNil(credential)
                completions += 1
            }
            delegate.urlSession(session, didReceive: challenge, completionHandler: complete)
            delegate.urlSession(session, task: task, didReceive: challenge, completionHandler: complete)
            XCTAssertEqual(completions, 2)
        }
    }
}
