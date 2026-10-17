import XCTest
import Darwin
@testable import AgentCore

final class AppControlTransportTests: XCTestCase {
    func testPrivateSocketRoundTripAndLiveListenerPreserved() throws {
        let dir = URL(fileURLWithPath: "/private/tmp/tctl-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try AppControlServer(directory: dir) { request, reply in
            reply(.init(request: request, succeeded: true, values: ["action":request.action]))
        }
        try withExtendedLifetime(server) {
            XCTAssertThrowsError(try AppControlServer(directory: dir) { _, _ in })
            let request = AppControlRequest(action: "status")
            XCTAssertNoThrow(try {
                let response = try AppControlTransport.request(request, directory: dir)
                XCTAssertEqual(response.id, request.id); XCTAssertTrue(response.succeeded)
                XCTAssertEqual(response.values["action"], "status")
            }())
        }
    }
    func testSocketDirectorySymlinkAndWrongPermissionsRefused() throws {
        let dir = URL(fileURLWithPath: "/private/tmp/tctl-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: URL(fileURLWithPath:"/private/tmp"))
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try AppControlServer(directory: dir) { _, _ in })
        XCTAssertThrowsError(try AppControlTransport.request(.init(action:"status"), directory: dir))
    }
    func testMismatchedReplyIsUnconfirmed() throws {
        let dir = URL(fileURLWithPath: "/private/tmp/tctl-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try AppControlServer(directory: dir) { _, reply in reply(.init(request:.init(action:"other"),succeeded:true)) }
        try withExtendedLifetime(server) {
            XCTAssertThrowsError(try AppControlTransport.request(.init(action:"status"),directory:dir))
        }
    }
}

extension AppControlTransportTests {
    func testPeerAuthorizationRejectsBeforeDispatch() throws {
        let dir = URL(fileURLWithPath:"/private/tmp/tca-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at:dir) }
        let server = try AppControlServer(directory:dir,authorize:{ token in
            XCTAssertEqual(token.count,MemoryLayout<audit_token_t>.size)
            return false
        }) { _,_ in XCTFail("Rejected caller must not reach the operation handler") }
        try withExtendedLifetime(server) {
            let response = try AppControlTransport.request(.init(action:"screen.start"),directory:dir)
            XCTAssertFalse(response.succeeded)
            XCTAssertTrue(response.issue?.contains("signature") == true)
        }
    }
}

extension AppControlTransportTests {
    func testClientRejectsUntrustedServerBeforeSendingRequest() throws {
        let dir = URL(fileURLWithPath:"/private/tmp/tcb-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at:dir) }
        let server = try AppControlServer(directory:dir) { _,_ in XCTFail("No request may be sent to an untrusted peer") }
        try withExtendedLifetime(server) {
            XCTAssertThrowsError(try AppControlTransport.request(.init(action:"status"),directory:dir,authorizeServer:{ _ in false }))
        }
    }
}
