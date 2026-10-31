import XCTest
@testable import MediaToolsKit

final class AuthCryptoTests: XCTestCase {
    /// Built independently with Python's `cryptography` using YunX's parameters.
    private let goldenV2 = "WVVOWF9BVVRIX1YyAAECAwQFBgcICQoLDA0OD2RlZmdoaWprbG1ub3mblWIGMmTKWdC0p2TC3NJJ+IUMzc78PEaswX5QGyH7ct15SqSP/Wg1y3lQFsrs+iBXzbWC0gDGnlk="
    private let goldenV1 = "WVVOWF9BVVRIX1YxAAECAwQFBgcICQoLDA0OD2RlZmdoaWprbG1ub0yMWc08UKn+pZiyXyJkCMhULVfG2y/tvb/UKpnhE8crUldAytKIS7SojU2ode9l+Ivp/aEm8jg8V0w="

    func testDecryptsExternalBackupsOfBothVersions() throws {
        for backup in [goldenV2, goldenV1] {
            XCTAssertEqual(try AuthCrypto.decrypt(backup, password: "pässword-1"), #"{"app":"yunx_auth_backup","note":"云析"}"#)
        }
    }

    func testEncryptWritesV2WithFreshSaltAndNonce() throws {
        let first = try AuthCrypto.encrypt("秘密", password: "password1")
        let second = try AuthCrypto.encrypt("秘密", password: "password1")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Data(base64Encoded: first)!.prefix(12), Data("YUNX_AUTH_V2".utf8))
        XCTAssertEqual(try AuthCrypto.decrypt(first, password: "password1"), "秘密")
        XCTAssertFalse(String(decoding: Data(base64Encoded: first)!, as: UTF8.self).contains("秘密"))
    }

    func testWrongPasswordAndTamperingFail() throws {
        let sealed = try AuthCrypto.encrypt("secret", password: "password1")
        XCTAssertThrowsError(try AuthCrypto.decrypt(sealed, password: "password2")) {
            XCTAssertEqual($0 as? AuthCryptoError, .decryptionFailed)
        }
        var bytes = Data(base64Encoded: sealed)!
        bytes[bytes.count - 1] ^= 1
        XCTAssertThrowsError(try AuthCrypto.decrypt(bytes.base64EncodedString(), password: "password1")) {
            XCTAssertEqual($0 as? AuthCryptoError, .decryptionFailed)
        }
    }

    func testRejectsShortPasswordAndNonBackups() throws {
        XCTAssertThrowsError(try AuthCrypto.encrypt("x", password: "short")) { XCTAssertEqual($0 as? AuthCryptoError, .passwordTooShort) }
        XCTAssertThrowsError(try AuthCrypto.decrypt("bm90IGEgYmFja3Vw", password: "password1")) { XCTAssertEqual($0 as? AuthCryptoError, .notABackup) }
        let truncated = Data("YUNX_AUTH_V2abc".utf8).base64EncodedString()
        XCTAssertThrowsError(try AuthCrypto.decrypt(truncated, password: "password1")) { XCTAssertEqual($0 as? AuthCryptoError, .corrupted) }
        XCTAssertTrue(AuthCrypto.isEncrypted(goldenV1))
        XCTAssertFalse(AuthCrypto.isEncrypted("{}"))
    }
}

private actor MemoryStore: BackupCredentialStore {
    var stored: [BackupAccount]
    var token: String?
    var tokenFails = false

    init(_ accounts: [BackupAccount] = [], token: String? = nil) {
        stored = accounts
        self.token = token
    }

    func failToken() { tokenFails = true }
    func accounts() async throws -> [BackupAccount] { stored }
    func upsert(_ account: BackupAccount) async throws { stored.append(account) }
    func gitHubToken() async throws -> String? { token }
    func setGitHubToken(_ token: String) async throws {
        if tokenFails { throw AuthBackupError.encodingFailed }
        self.token = token
    }
    nonisolated func isKnownVideoPlatform(_ name: String) -> Bool { name == "BILIBILI" }
}

final class AuthBackupManagerTests: XCTestCase {
    private func sample() -> [BackupAccount] {
        [
            BackupAccount(platform: "quark", fields: ["cookie": "c1", "nickname": "n"], updatedAt: 5),
            BackupAccount(platform: "uc", fields: ["cookie": ""], updatedAt: 6),
            BackupAccount(platform: "baidu", fields: ["cookie": "never"], updatedAt: 7),
            BackupAccount(platform: "ilanzou", fields: ["appToken": "t", "password": "pw"], updatedAt: 8),
            BackupAccount(platform: "video:BILIBILI", fields: ["id": "row", "cookie": "v", "remark": "r"], updatedAt: 9, isPrimary: true),
        ]
    }

    func testRoundTripThroughCiphertext() async throws {
        let source = MemoryStore(sample(), token: "gh")
        let backup = try await AuthBackupManager(store: source).export(password: "password1")
        XCTAssertTrue(AuthCrypto.isEncrypted(backup))
        let target = MemoryStore()
        let restored = try await AuthBackupManager(store: target).import(backup, password: "password1")
        XCTAssertEqual(restored, 4)
        let accounts = try await target.accounts()
        XCTAssertEqual(accounts.map(\.platform), ["quark", "ilanzou", "video:BILIBILI"])
        XCTAssertEqual(accounts[1].fields["password"], "pw")
        XCTAssertEqual(accounts[2].fields["id"], "row")
        XCTAssertEqual(accounts[2].isPrimary, true)
        let token = await target.token
        XCTAssertEqual(token, "gh")
    }

    func testJSONKeepsYunXShapeAndDropsBaidu() async throws {
        let json = try await AuthBackupManager(store: MemoryStore(sample()), now: { 77 }).exportJSON(onlyLoggedIn: false)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(root["app"] as? String, "yunx_auth_backup")
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertEqual(root["exportedAt"] as? Int, 77)
        XCTAssertNil(root["githubToken"])
        let platforms = (root["accounts"] as? [[String: Any]])?.compactMap { $0["platform"] as? String }
        XCTAssertEqual(platforms, ["quark", "uc", "ilanzou", "video:BILIBILI"])
    }

    func testImportSkipsBaiduUnknownAndBlankAndTolerantOfTokenFailure() async throws {
        let store = MemoryStore()
        await store.failToken()
        let json = """
        {"app":"yunx_auth_backup","githubToken":"gh","accounts":[
          {"platform":"baidu","cookie":"x"},
          {"platform":"quark","cookie":""},
          {"platform":"video:GONE","cookie":"x"},
          {"platform":"video:BILIBILI","cookie":"v"},
          {"platform":"pan115","cookie":"c","updatedAt":12}
        ]}
        """
        let count = try await AuthBackupManager(store: store, now: { 1 }).import(json)
        XCTAssertEqual(count, 2)
        let accounts = try await store.accounts()
        XCTAssertEqual(accounts[0].fields["id"], "BILIBILI")
        XCTAssertEqual(accounts[0].updatedAt, 1)
        XCTAssertEqual(accounts[1].updatedAt, 12)
    }

    func testImportRejectsForeignJSON() async {
        do {
            _ = try await AuthBackupManager(store: MemoryStore()).import(#"{"app":"other"}"#)
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? AuthBackupError, .invalidBackup)
        }
    }

    func testSaveIsOwnerOnlyAndRefusesPlaintext() throws {
        let dir = try makeRoot().url
        let target = dir.appendingPathComponent("sub/a.yunx")
        XCTAssertThrowsError(try AuthBackupManager.save(#"{"cookie":"x"}"#, to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try AuthBackupManager.save(try AuthCrypto.encrypt("x", password: "password1"), to: target)
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testFileNameIsEncryptedExtension() {
        XCTAssertTrue(AuthBackupManager.defaultFileName(date: Date(timeIntervalSince1970: 0)).hasSuffix(".yunx"))
    }
}
