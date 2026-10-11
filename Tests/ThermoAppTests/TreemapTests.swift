@testable import ThermoApp
import XCTest

final class TreemapTests: XCTestCase {
    func testTilesCoverTheirShareWithoutOverlapping() {
        let box = CGRect(x: 0, y: 0, width: 600, height: 200)
        let values: [Double] = [50, 20, 10, 10, 5, 5]
        let rects = Treemap.squarify(values, in: box, total: 100)
        XCTAssertEqual(rects.count, values.count)
        let area = Double(box.width * box.height)
        for (r, v) in zip(rects, values) {
            XCTAssertEqual(Double(r.width * r.height), area * v / 100, accuracy: 1)
            XCTAssertTrue(box.insetBy(dx: -0.5, dy: -0.5).contains(r))
        }
        for i in rects.indices { for j in rects.indices where j > i {
            XCTAssertLessThan(rects[i].intersection(rects[j]).width * rects[i].intersection(rects[j]).height, 0.5)
        } }
    }

    func testWhatIsNotShownLeavesRoom() {
        let box = CGRect(x: 0, y: 0, width: 400, height: 100)
        let rects = Treemap.squarify([30, 20], in: box, total: 100)
        let used = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        XCTAssertEqual(used, 40000 * 0.5, accuracy: 1)
    }
}
