import CleanKit
import XCTest
@testable import ThermoApp

@MainActor
final class SpaceLensWholeDiskTests: XCTestCase {
    func testWholeDiskRootKeepsTrashLimitedToHomeAndRefusesVirtualRows() {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = SpaceLensModel(root: "/", cache: cache)
        XCTAssertEqual(model.home, NSHomeDirectory())
        XCTAssertNotNil(model.refusal("/Applications"))
        XCTAssertNotNil(model.refusal("/System/Library"))
        XCTAssertNotNil(model.refusal(SpaceLens.virtualPrefix + "unreadable"))
    }
}
