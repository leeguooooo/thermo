import CleanKit
import XCTest
@testable import SpaceFeature
import NativeFeatureAPI

@MainActor
final class SpaceLensWholeDiskTests: XCTestCase {
    func testWholeDiskRootKeepsTrashLimitedToHomeAndRefusesVirtualRows() {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = SpaceLensModel(services:FixtureSpaceServices(),root: "/", cache: cache)
        XCTAssertEqual(model.home, NSHomeDirectory())
        XCTAssertNotNil(model.refusal("/Applications"))
        XCTAssertNotNil(model.refusal("/System/Library"))
        XCTAssertNotNil(model.refusal(SpaceLens.virtualPrefix + "unreadable"))
    }
}
