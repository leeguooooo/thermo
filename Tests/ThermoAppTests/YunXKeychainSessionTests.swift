import Foundation
import Security
import XCTest
@testable import ThermoApp

final class YunXKeychainSessionTests: XCTestCase {
    func testAutomaticReadsNeverRequestAuthorizationAndReuseUnlockedData() throws {
        var requests: [Bool] = []
        let session = YunXKeychainSession(read: { _, interactive in
            requests.append(interactive)
            return Data("saved".utf8)
        }, write: { _, _ in XCTFail("unexpected write") })
        for _ in 0..<5 { XCTAssertEqual(try session.read("vault"), Data("saved".utf8)) }
        XCTAssertEqual(requests, [false])
    }

    func testDeniedAccessDoesNotPromptAgainOrOverwriteSavedJobs() {
        var requests: [Bool] = []
        let session = YunXKeychainSession(read: { _, interactive in
            requests.append(interactive)
            throw YunXKeychainError.status(errSecInteractionNotAllowed)
        }, write: { _, _ in XCTFail("must not overwrite inaccessible records") })
        for _ in 0..<5 { XCTAssertThrowsError(try session.read("downloads")) }
        XCTAssertThrowsError(try session.write(Data("[]".utf8), account: "downloads"))
        XCTAssertTrue(session.authorizationRequired)
        XCTAssertEqual(requests, [false])
    }

    func testExplicitAuthorizationRestoresAllItemsAndSubsequentReadsStaySilent() throws {
        var requests: [(String, Bool)] = []
        let session = YunXKeychainSession(read: { account, interactive in
            requests.append((account, interactive))
            if !interactive { throw YunXKeychainError.status(errSecInteractionNotAllowed) }
            return Data(account.utf8)
        }, write: { _, _ in })
        XCTAssertThrowsError(try session.read("vault"))
        try session.authorize()
        XCTAssertFalse(session.authorizationRequired)
        for account in ["vault", "downloads", "trackers"] {
            XCTAssertEqual(try session.read(account), Data(account.utf8))
        }
        XCTAssertEqual(requests.map(\.0), ["vault", "vault", "downloads", "trackers"])
        XCTAssertEqual(requests.map(\.1), [false, true, true, true])
    }

    func testCancellationStopsAuthorizationAndBackgroundReadsDoNotRetry() {
        var requests: [String] = []
        let session = YunXKeychainSession(read: { account, _ in
            requests.append(account)
            throw YunXKeychainError.status(errSecUserCanceled)
        }, write: { _, _ in XCTFail("unexpected write") })
        XCTAssertThrowsError(try session.authorize())
        for _ in 0..<5 { XCTAssertThrowsError(try session.read("vault")) }
        XCTAssertEqual(requests, ["vault"])
        XCTAssertTrue(session.authorizationRequired)
    }

    func testOnlyExplicitRetryCanRecoverFromCancellation() throws {
        var attempts = 0
        let session = YunXKeychainSession(read: { _, _ in
            attempts += 1
            if attempts == 1 { throw YunXKeychainError.status(errSecUserCanceled) }
            return nil
        }, write: { _, _ in })
        XCTAssertThrowsError(try session.read("vault", interactive: true))
        XCTAssertThrowsError(try session.read("vault"))
        XCTAssertNil(try session.read("vault", interactive: true))
        XCTAssertFalse(session.authorizationRequired)
        XCTAssertEqual(attempts, 2)
    }

    func testWritesUpdateCachedDataOnlyAfterPersistenceSucceeds() throws {
        var failWrite = true
        var reads = 0
        let session = YunXKeychainSession(read: { _, _ in reads += 1; return Data("old".utf8) }, write: { _, _ in
            if failWrite { throw YunXKeychainError.status(errSecNotAvailable) }
        })
        XCTAssertThrowsError(try session.write(Data("new".utf8), account: "vault"))
        XCTAssertEqual(try session.read("vault"), Data("old".utf8))
        failWrite = false
        try session.write(Data("new".utf8), account: "vault")
        XCTAssertEqual(try session.read("vault"), Data("new".utf8))
        XCTAssertEqual(reads, 1)
    }

    func testMissingItemsAreCachedAndCanBeCreated() throws {
        var reads = 0
        var saved: Data?
        let session = YunXKeychainSession(read: { _, _ in reads += 1; return nil }, write: { _, data in saved = data })
        XCTAssertNil(try session.read("vault"))
        XCTAssertNil(try session.read("vault"))
        try session.write(Data("first".utf8), account: "vault")
        XCTAssertEqual(try session.read("vault"), saved)
        XCTAssertEqual(reads, 1)
    }
}
