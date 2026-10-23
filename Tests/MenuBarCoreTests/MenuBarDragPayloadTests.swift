import XCTest
@testable import MenuBarCore

final class MenuBarDragPayloadTests: XCTestCase {
    func testKnownAppRoundTrips() throws {
        let payload = MenuBarDragPayload(bundle: "org.example.app")
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(try MenuBarDragPayload.read(data, knownBundles: [payload.bundle], ownBundle: "org.example.host"), payload)
    }
    func testUnknownOrRemovedSourceCannotChangeAssignments() throws {
        let data = try JSONEncoder().encode(MenuBarDragPayload(bundle: "org.example.app"))
        XCTAssertThrowsError(try MenuBarDragPayload.read(data, knownBundles: [], ownBundle: "org.example.host"))
    }
    func testSystemAndHostCannotBeMovedEvenWhenPresentInCatalog() throws {
        for bundle in ["com.apple.controlcenter", "dev.thermo.app", "org.example.host"] {
            let data = try JSONEncoder().encode(MenuBarDragPayload(bundle: bundle))
            XCTAssertThrowsError(try MenuBarDragPayload.read(data, knownBundles: [bundle], ownBundle: "org.example.host"))
        }
    }
    func testMalformedFutureAndOversizedPayloadsAreRejected() {
        for data in [Data("broken".utf8), Data("{\"version\":2,\"bundle\":\"org.example.app\"}".utf8), Data(repeating: 32, count: 1_025)] {
            XCTAssertThrowsError(try MenuBarDragPayload.read(data, knownBundles: ["org.example.app"], ownBundle: "org.example.host"))
        }
    }
}
