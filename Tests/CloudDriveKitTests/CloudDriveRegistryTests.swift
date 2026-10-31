import XCTest
@testable import CloudDriveKit

final class CloudDriveRegistryTests: XCTestCase {
    func testRegistersEveryPlatformOnce() {
        let registry = CloudDriveRegistry(transport: FakeTransport())
        XCTAssertEqual(registry.providers.map(\.platform), DrivePlatform.allCases)
        for platform in DrivePlatform.allCases { XCTAssertEqual(registry.provider(platform)?.platform, platform) }
    }

    func testRouterReachesEveryPlatform() throws {
        let links: [(String, DrivePlatform)] = [
            ("https://pan.quark.cn/s/abc", .quark), ("https://drive.uc.cn/s/abc", .uc),
            ("https://pan.xunlei.com/s/abc", .xunlei), ("https://yun.139.com/shareweb/#/w/i/abc", .c139),
            ("https://www.123pan.com/s/abc-def", .pan123), ("https://115.com/s/swabc12345", .pan115),
            ("https://www.guangyapan.com/s/abc", .guangya), ("https://www.ilanzou.com/s/abc", .ilanzou),
            ("https://www.lanzoux.com/abc", .lanzou),
        ]
        XCTAssertEqual(Set(links.map(\.1)), Set(DrivePlatform.allCases))
        let router = CloudDriveRegistry(transport: FakeTransport()).router
        for (url, platform) in links { XCTAssertEqual(try router.route(url).provider.platform, platform, url) }
    }

    func testDrivesThatListAnonymouslyAdmitGuests() {
        for provider in CloudDriveRegistry(transport: FakeTransport()).providers {
            XCTAssertTrue(provider.capabilities.contains(.guestShareAccess), provider.platform.rawValue)
        }
    }

    func testPatchJSONSendsPatch() async throws {
        let transport = FakeTransport(fallback: json("{}"))
        _ = try await HTTPClient(transport: transport).patchJSON("https://x.example/a", json: ["name": "b"])
        XCTAssertEqual(transport.requests[0].method, .patch)
        XCTAssertEqual(transport.requests[0].method.rawValue, "PATCH")
        XCTAssertEqual(transport.requests[0].headers["Content-Type"], "application/json")
        XCTAssertEqual(try transport.body(0)["name"] as? String, "b")
    }

    func testXunleiRenameIsASignedPatch() async throws {
        let transport = FakeTransport(fallback: json(#"{"id":"f1","name":"b"}"#))
        let account = XunleiCredential(accessToken: "tok", refreshToken: "r", deviceId: "dev1", captchaToken: "cap", nickname: "n")
        let renamed = try await XunleiAPI(transport: transport).renameFile(fileId: "f1", name: "b", credential: account)
        XCTAssertTrue(renamed)
        let patch = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(patch.method, .patch)
        XCTAssertEqual(patch.url.absoluteString, "\(XunleiConstants.filesURL)/f1")
        XCTAssertEqual(patch.headers["Authorization"], "Bearer tok")
        XCTAssertEqual(try transport.body(transport.requests.count - 1)["name"] as? String, "b")
    }

    func testSharedTempDirectoryName() {
        XCTAssertEqual(DriveTempDirectory.name, "Thermo临时转存")
        for name in [QuarkConstants.tempDirectoryName, UCConstants.tempDirectoryName, Pan115Constants.tempDirectoryName, XunleiConstants.tempDirectoryName] {
            XCTAssertEqual(name, DriveTempDirectory.name)
        }
        XCTAssertEqual(GuangYaConstants.tempDirectoryPrefix, "Thermo临时转存_")
    }
}
