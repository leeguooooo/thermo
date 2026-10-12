import XCTest
import CleanKit
@testable import thermo

final class CleanStreamTests: XCTestCase {
    func testConcurrentEventsRemainCompleteJSONLines() throws {
        var data = Data()
        let stream = CleanCommand.ScanStream(write: { data.append($0) })
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            stream.emit(.init(event: "progress", step: "project \(index)\n下一步"))
        }
        let lines = data.split(separator: 10)
        XCTAssertEqual(lines.count, 40)
        for line in lines {
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            XCTAssertEqual(event["event"] as? String, "progress")
            XCTAssertTrue((event["step"] as? String)?.contains("\n下一步") == true)
        }
    }

    func testFinishedEventPreservesCancellationAndScope() throws {
        var report = ScanReport(items: [], denied: [], started: Date(timeIntervalSince1970: 0), duration: 1,
                                cancelled: true)
        report.categories = [.projects]
        var data = Data()
        let stream = CleanCommand.ScanStream(write: { data.append($0) })
        stream.emit(.init(event: "finished", report: report))
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let saved = try XCTUnwrap(event["report"] as? [String: Any])
        XCTAssertEqual(saved["cancelled"] as? Bool, true)
        XCTAssertEqual(saved["categories"] as? [String], ["projects"])
        XCTAssertEqual(saved["started"] as? String, "1970-01-01T00:00:00Z")
    }
}
