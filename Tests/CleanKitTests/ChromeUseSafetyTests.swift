import XCTest
@testable import CleanKit

final class ChromeUseSafetyTests: XCTestCase {
    func testInvalidNewBackendMetricsCannotOverflowCounters() throws {
        let json = """
        {"schema":1,"generatedAt":1791647340000,"pages":[
          {"handle":"invalid","metrics":{"JSHeapUsedSize":1024,"Nodes":1e100}},
          {"handle":"valid","metrics":{"JSHeapUsedSize":1024,"Nodes":1,"JSEventListeners":1},
           "delta":{"seconds":60,"JSHeapUsedSize":2048,"Nodes":1e100},"leakClass":"nodes_climbing"}
        ]}
        """
        let input = try JSONDecoder().decode(ChromeInspector.ChromeUseReport.self, from: Data(json.utf8))
        let report = ChromeInspector.report(input)
        XCTAssertEqual(report.pages.map(\.id), ["valid"])
        XCTAssertEqual(report.unmeasured, 1)
        XCTAssertNil(report.pages.first?.growth)
        XCTAssertEqual(report.comparedPages, 0)
        XCTAssertEqual(report.comparisonSkipped, 1)
    }

    func testNewCommandRunnerBoundsTimeoutEvenWhenTermIsIgnored() {
        let start = Date()
        XCTAssertNil(ChromeInspector.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 5"], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testTaskCancellationStopsTheNewBackendChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fixture.sh")
        let marker = root.appendingPathComponent("started")
        try "#!/bin/sh\nprintf started > '\(marker.path)'\nexec /bin/sleep 5\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let task = Task { await ChromeInspector.diagnoseWithChromeUse(script.path, app: "Fixture", measure: false, watch: nil,
                                                                    appMemoryKB: nil, gpuKB: nil, progress: { _ in }) }
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let start = Date()
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
