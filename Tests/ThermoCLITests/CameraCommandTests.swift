import XCTest
import AgentCore
@testable import thermo

final class CameraCommandTests: XCTestCase {
    func testScopedContractsIncludeAllMutationPreviews() throws {
        for sub in ["on", "off"] {
            let args = try Args(["camera", sub, "--dry-run", "--yes", "--json"])
            XCTAssertNoThrow(try CommandContract.validate(args))
            let operation = try AppControlCommand.operation(command: "camera", rest: [sub], args: args)
            XCTAssertTrue(operation.mutates); XCTAssertEqual(operation.action, "camera." + sub)
        }
        XCTAssertThrowsError(try CommandContract.validate(Args(["camera", "inspect", "--dry-run"])))
        XCTAssertThrowsError(try CommandContract.validate(Args(["camera", "status", "--limit", "1"])))
        XCTAssertThrowsError(try CameraCommand.limit("257")); XCTAssertThrowsError(try CameraCommand.limit("0"))
        XCTAssertEqual(try CameraCommand.limit(nil), 64)
    }
    func testMetadataOutputNeverClaimsProcessAttributionOrEmptyInventoryIdle() {
        let empty = CameraCommand.text(CameraReport(observation: .init(), source: "test"))
        XCTAssertTrue(empty.contains("Camera: noDevices")); XCTAssertTrue(empty.contains("application attribution unavailable"))
        let observation = CameraObservation(devices: [.init(objectID: 10, uid: "private-uid", name: "Camera\u{1b}[31m", active: true)])
        let text = CameraCommand.text(CameraReport(observation: observation, source: "test"))
        XCTAssertTrue(text.contains("active")); XCTAssertFalse(text.contains("\u{1b}")); XCTAssertFalse(text.contains("private-uid"))
    }
    func testTypedCameraControlRoundTripAndOldResponseCompatibility() throws {
        let request = AppControlRequest(action: "camera.status")
        let old = try JSONEncoder().encode(AppControlResponse(request: request, succeeded: true))
        XCTAssertNil(try JSONDecoder().decode(AppControlResponse.self, from: old).camera)
        let camera = CameraReport(observation: .init(), source: "test")
        let data = try JSONEncoder().encode(AppControlResponse(request: request, succeeded: true, camera: camera))
        XCTAssertEqual(try JSONDecoder().decode(AppControlResponse.self, from: data).camera?.state, "noDevices")
    }
}
