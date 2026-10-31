import CloudDriveKit
import MediaToolsKit
import VideoKit
import XCTest
@testable import ThermoApp

private final class MemoryBackend: YunXSecretBackend, @unchecked Sendable {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

final class YunXDownloadTests: XCTestCase {
    private func vault() -> YunXVault { YunXVault(backend: MemoryBackend(), now: { 1 }) }

    func testClassifiesEachLinkKind() {
        XCTAssertEqual(YunXLink.classify(" magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567 "),
                       .p2p("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"))
        guard case let .share(link)? = YunXLink.classify("https://pan.quark.cn/s/abc123 提取码：a1b2") else { return XCTFail("share") }
        XCTAssertEqual(link.platform, .quark)
        XCTAssertEqual(link.passcode, "a1b2")
        guard case let .video(video)? = YunXLink.classify("https://www.bilibili.com/video/BV1xx411c7mD") else { return XCTFail("video") }
        XCTAssertEqual(video.platform, .bilibili)
        XCTAssertNil(YunXLink.classify("not a link"))
    }

    func testCookieDetectionNeedsAllRequiredKeysOrOneAlternative() {
        let domains = [".10086.cn"]
        let partial = [(domain: ".10086.cn", name: "RMKEY", value: "1")]
        XCTAssertNil(YunXLoginMethod.detect(partial, domains: domains, required: ["Os_SSo_Sid", "RMKEY"], anyOf: []))
        XCTAssertEqual(YunXLoginMethod.detect(partial + [(".10086.cn", "authorization", "2"), (".other.cn", "x", "3")],
                                              domains: domains, required: ["Os_SSo_Sid", "RMKEY"], anyOf: ["authorization"]),
                       "RMKEY=1; authorization=2")
    }

    func testAccountsAreSeparatePerLoginAndPrimaryMoves() throws {
        let vault = vault()
        let first = try vault.add(platform: "quark", fields: ["cookie": "a", "nickname": "one"], key: "cookie")
        let second = try vault.add(platform: "quark", fields: ["cookie": "b", "nickname": "two"], key: "cookie")
        XCTAssertEqual(try vault.accounts().count, 2)
        XCTAssertEqual(try vault.active("quark")?.id, first.id)
        try vault.setPrimary(id: second.id)
        XCTAssertEqual(try vault.active("quark")?.id, second.id)
        try vault.remove(id: second.id)
        XCTAssertEqual(try vault.active("quark")?.id, first.id)
        try vault.add(platform: "quark", fields: ["cookie": "a2", "nickname": "one"], key: "cookie")
        XCTAssertEqual(try vault.accounts().map { $0.fields["cookie"] }, ["a2"])
    }

    func testRotationUpdatesTheMatchingAccountOnly() throws {
        let vault = vault()
        try vault.add(platform: "quark", fields: ["cookie": "a"], key: "cookie")
        try vault.add(platform: "uc", fields: ["cookie": "b"], key: "cookie")
        try vault.rotate(previous: DriveCredential("b"), updated: DriveCredential("c"))
        XCTAssertEqual(try vault.active("uc")?.fields["cookie"], "c")
        XCTAssertEqual(try vault.active("quark")?.fields["cookie"], "a")
    }

    func testStructuredCredentialsSurviveTheFieldMapping() {
        let xunlei = XunleiCredential(accessToken: "token.abc", refreshToken: "refresh", deviceId: "device", authType: "x").driveCredential
        let xunleiFields = YunXCredentialCodec.fields(.xunlei, credential: xunlei)
        XCTAssertEqual(XunleiCredential(YunXCredentialCodec.credential(.xunlei, fields: xunleiFields))?.refreshToken,
                       XunleiCredential(xunlei)?.refreshToken)
        let guangya = GuangYaCredential(accessToken: "a", refreshToken: "r", device: GuangYaDevice(deviceId: "d", deviceSign: "s"), accessExpiresAt: 9)
        let fields = YunXCredentialCodec.fields(.guangya, credential: guangya.driveCredential)
        XCTAssertEqual(GuangYaCredential(YunXCredentialCodec.credential(.guangya, fields: fields)), guangya)
    }

    func testEncryptedBackupRoundTripKeepsEveryAccount() async throws {
        let source = vault()
        try source.add(platform: "quark", fields: ["cookie": "__pus=secret-value", "nickname": "one"], key: "cookie")
        try source.add(platform: "quark", fields: ["cookie": "__pus=other", "nickname": "two"], key: "cookie")
        try source.add(platform: "video:BILIBILI", fields: ["cookie": "SESSDATA=1", "nickname": "b"], key: "cookie")
        let content = try await AuthBackupManager(store: YunXBackupStore(vault: source)).export(password: "backup-pass")
        XCTAssertFalse(content.contains("secret-value"))
        let target = vault()
        _ = try await AuthBackupManager(store: YunXBackupStore(vault: target)).import(content, password: "backup-pass")
        XCTAssertEqual(try target.accounts().map(\.nickname).sorted(), ["b", "one", "two"])
    }

    func testPrintingAnAccountShowsNoSecret() {
        let account = YunXAccount(id: "1", platform: "quark", fields: ["cookie": "secret-value"], updatedAt: 0, isPrimary: true)
        XCTAssertFalse("\(account)".contains("secret-value"))
        XCTAssertFalse(String(reflecting: account).contains("secret-value"))
        XCTAssertFalse(String(describing: Mirror(reflecting: account).children.map(\.value)).contains("secret-value"))
    }

    func testVideoFileNamesFallBackToTheTitle() {
        XCTAssertEqual(YunXDownloadModel.fileName(VideoMedia(url: "u", kind: .video), title: "clip"), "clip.mp4")
        XCTAssertEqual(YunXDownloadModel.fileName(VideoMedia(url: "u", kind: .image, fileName: "a.png"), title: "clip"), "a.png")
    }
}
