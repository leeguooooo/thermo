import CleanKit
import Sparkle
import XCTest

final class UpdateVersionCompatibilityTests: XCTestCase {
    func testCommonBuildVersionsAgreeWithPinnedSparkleComparator() {
        let comparator = SUStandardVersionComparator()
        let versions = ["1", "1.0", "1.0.0", "1.0.1", "1.0a1", "1.0b2", "1.0rc1", "2", "10", "100", "100.01", "100.1", "2.0-beta1", "1,0", "1 0"]
        for a in versions { for b in versions {
            XCTAssertEqual(UpdateVersion.compare(a, b), comparator.compareVersion(a, toVersion: b), "\(a) / \(b)")
        } }
    }

    func testHugeVersionsAndInvalidMetadataDoNotOverflowOrPretendEqual() {
        XCTAssertEqual(UpdateVersion.compare(String(repeating: "9", count: 80), String(repeating: "1", count: 79)), .orderedDescending)
        for version in ["", "latest", "1\n2", "1\0hidden", String(repeating: "1", count: 129)] {
            XCTAssertNil(UpdateVersion.compare(version, "1"))
        }
    }
}
