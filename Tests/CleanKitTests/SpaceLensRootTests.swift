import XCTest
@testable import CleanKit

final class SpaceLensRootTests: XCTestCase {
    func testTreeRootedAtSlashCoversEveryAbsolutePath() {
        let tree = SpaceTree(root: "/", scanned: Date(), folders: [:], large: [], unreadable: [], complete: true, duration: 0)
        XCTAssertTrue(tree.covers("/Users/someone"))
        XCTAssertTrue(tree.covers("/"))
        let home = SpaceTree(root: "/Users/someone", scanned: Date(), folders: [:], large: [], unreadable: [], complete: true, duration: 0)
        XCTAssertFalse(home.covers("/Users/someone-else"))
        XCTAssertTrue(SpaceLens.isVirtual(SpaceLens.virtualPrefix + "unreadable"))
    }
}
