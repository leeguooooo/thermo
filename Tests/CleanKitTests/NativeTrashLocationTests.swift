import XCTest
@testable import CleanKit

final class NativeTrashLocationTests: XCTestCase {
    func entry(_ destination: String, original: String = "/state/Applications/Fixture.app") -> TrashBatch.Entry {
        .init(original: original, destination: destination, identity: "fixture", bytes: 1)
    }
    func testNativeLocationMustComeFromOSLookupForTheOriginalParent() {
        let item = entry("/native/.Trash/Fixture.app")
        let root = TrashBatches.trashDirectory(item, home: "/state", currentHome: "/state", nativeTrash: { parent in
            XCTAssertEqual(parent, "/state/Applications")
            return "/native/.Trash"
        })
        XCTAssertEqual(root, "/native/.Trash")
        XCTAssertNil(TrashBatches.trashDirectory(entry("/native/.Trash/nested/Fixture.app"), home: "/state", currentHome: "/state", nativeTrash: { _ in "/native/.Trash" }))
        XCTAssertNil(TrashBatches.trashDirectory(item, home: "/state", currentHome: "/state", nativeTrash: { _ in "/different/.Trash" }))
    }
    func testAnExplicitDifferentHomeCannotExpandIntoTheCurrentUsersNativeTrash() {
        XCTAssertNil(TrashBatches.trashDirectory(entry("/native/.Trash/Fixture.app"), home: "/other", currentHome: "/current", nativeTrash: { _ in
            XCTFail("must not ask for another user's native trash"); return "/native/.Trash"
        }))
        XCTAssertEqual(TrashBatches.trashDirectory(entry("/other/.Trash/Fixture.app"), home: "/other", currentHome: "/current", nativeTrash: { _ in
            XCTFail("logical home remains the fixture boundary"); return "/native/.Trash"
        }), "/other/.Trash")
    }
    func testUnknownNativeLocationAndUnsafeOriginalPathsFailClosed() {
        for original in ["relative/Fixture.app", "/state/../Applications/Fixture.app", "/state/./Fixture.app"] {
            XCTAssertNil(TrashBatches.trashDirectory(entry("/native/.Trash/Fixture.app", original: original), home: "/state", currentHome: "/state", nativeTrash: { _ in
                XCTFail("unsafe original must not be queried"); return "/native/.Trash"
            }))
        }
        XCTAssertNil(TrashBatches.trashDirectory(entry("/native/.Trash/Fixture.app"), home: "/state", currentHome: "/state", nativeTrash: { _ in throw NSError(domain: "fixture", code: 1) }))
    }
}
