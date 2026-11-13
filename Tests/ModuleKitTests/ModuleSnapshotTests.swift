import Foundation
import XCTest
@testable import ModuleKit

final class ModuleSnapshotTests: XCTestCase {
    func header(_ width: UInt32, _ height: UInt32) -> Data {
        var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]
        for value in [width, height] { bytes += [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
        return Data(bytes + [8, 6, 0, 0, 0, 0, 0, 0, 0])
    }
    func testDimensionsAreBoundedBeforeDecode() {
        let size = ModuleSnapshot.dimensions(header(2200, 1480))
        XCTAssertEqual(size?.width, 2200); XCTAssertEqual(size?.height, 1480)
        for data in [Data(), Data(repeating: 0, count: 33), header(0, 1), header(1, 0), header(8193, 1), header(8192, 8192)] {
            XCTAssertNil(ModuleSnapshot.dimensions(data))
        }
    }
}
