import Darwin
import Foundation
import XCTest
@testable import AgentCore

final class ProcessObservationTests: XCTestCase {
    func testUnknownPIDDoesNotLookLikeCompleteEmptyPaths() {
        let result=OpenFiles.observe(-1)
        XCTAssertFalse(result.complete);XCTAssertTrue(result.paths.isEmpty)
    }
    func testInvalidDescriptorBudgetsAreRejectedWithoutAllocation() {
        for limit in [0,65_537] {
            let result=OpenFiles.observe(getpid(),maximumDescriptors:limit)
            XCTAssertFalse(result.complete);XCTAssertTrue(result.truncated);XCTAssertTrue(result.paths.isEmpty)
        }
    }
    func testOwnOpenDescriptorIsObservedWithoutCleanupInventoryFiltering() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("owned-open-file");try Data("fixture".utf8).write(to:file)
        let handle=try FileHandle(forReadingFrom:file);defer { try? handle.close() }
        let expected=FileIdentity.of(file.path)
        XCTAssertNotNil(expected)
        let result=OpenFiles.observe(getpid())
        XCTAssertTrue(result.paths.contains { FileIdentity.of($0)==expected })
    }
}
