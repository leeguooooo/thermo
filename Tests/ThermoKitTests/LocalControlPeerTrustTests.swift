import XCTest
import Security
import Darwin
@testable import ThermoKit

final class LocalControlPeerTrustTests: XCTestCase {
    func testKernelAuditTokenMatchesPinnedExecutableAndRejectsOtherTeam() throws {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        XCTAssertEqual(SecCodeCopySelf([],&code),errSecSuccess)
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code),[],&staticCode),errSecSuccess)
        XCTAssertEqual(SecCodeCopySigningInformation(try XCTUnwrap(staticCode),SecCSFlags(rawValue:kSecCSSigningInformation),&info),errSecSuccess)
        let metadata = try XCTUnwrap(info as? [String:Any])
        let executable = try XCTUnwrap(metadata[kSecCodeInfoMainExecutable as String] as? URL)
        let pinned = try LocalControlPeerTrust(team:nil,developmentExecutable:executable)
        var sockets = [Int32](repeating:-1,count:2)
        XCTAssertEqual(socketpair(AF_UNIX,SOCK_STREAM,0,&sockets),0)
        defer { sockets.forEach { close($0) } }
        var token = audit_token_t(), size = socklen_t(MemoryLayout<audit_token_t>.size)
        XCTAssertEqual(getsockopt(sockets[0],SOL_LOCAL,LOCAL_PEERTOKEN,&token,&size),0)
        let data = withUnsafeBytes(of:&token) { Data($0) }
        XCTAssertTrue(pinned.accepts(auditToken:data))
        XCTAssertFalse(pinned.accepts(auditToken:Data()))
        let wrongTeam = try LocalControlPeerTrust(team:"0000000000",developmentExecutable:executable)
        XCTAssertFalse(wrongTeam.accepts(auditToken:data))
        XCTAssertThrowsError(try LocalControlPeerTrust(team:"injected\"",developmentExecutable:executable))
    }
    func testDevelopmentRequirementCannotUseMissingOrUnsignedData() throws {
        let path = URL(fileURLWithPath:"/private/tmp/thermo-peer-" + UUID().uuidString)
        try Data("not executable code".utf8).write(to:path)
        defer { try? FileManager.default.removeItem(at:path) }
        XCTAssertThrowsError(try LocalControlPeerTrust(team:nil,developmentExecutable:path))
    }
}
