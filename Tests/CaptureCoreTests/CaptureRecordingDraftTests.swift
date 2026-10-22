import Foundation
import XCTest
@testable import CaptureCore

final class CaptureRecordingDraftTests:XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-draft-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        addTeardownBlock { try FileManager.default.removeItem(at:url) }; return url
    }
    func testReadyAndInterruptedDraftsSurviveReopeningStore() throws {
        let root = try root(), store = CaptureRecordingDraftStore(root:root)
        var ready = try store.create(); ready.status = .ready
        try Data("sample movie".utf8).write(to:store.movie(ready.id)); try store.update(ready)
        let interrupted = try store.create(); try Data("partial movie".utf8).write(to:store.movie(interrupted.id))
        let reopened = CaptureRecordingDraftStore(root:root), drafts = try reopened.list()
        XCTAssertEqual(Set(drafts.map(\.id)),Set([ready.id,interrupted.id]))
        XCTAssertEqual(drafts.first(where:{$0.id == ready.id})?.status,.ready)
        XCTAssertEqual(drafts.first(where:{$0.id == interrupted.id})?.status,.recording)
        let attributes = try FileManager.default.attributesOfItem(atPath:store.directory(ready.id).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o700)
    }
    func testSymlinkedFoldersAndMovieFilesAreNotRead() throws {
        let root = try root(), store = CaptureRecordingDraftStore(root:root.appendingPathComponent("drafts"))
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:false)
        let draft = try store.create(); try Data("outside".utf8).write(to:outside.appendingPathComponent("movie"))
        try FileManager.default.createSymbolicLink(at:store.movie(draft.id),withDestinationURL:outside.appendingPathComponent("movie"))
        try FileManager.default.createSymbolicLink(at:store.directory(UUID()),withDestinationURL:outside)
        XCTAssertTrue(try store.list().isEmpty)
        try store.discard(draft.id)
        XCTAssertEqual(try Data(contentsOf:outside.appendingPathComponent("movie")),Data("outside".utf8))
    }
    func testMalformedAndMissingMoviesAreIgnored() throws {
        let store = CaptureRecordingDraftStore(root:try root()), valid = try store.create()
        XCTAssertTrue(try store.list().isEmpty)
        try Data("movie".utf8).write(to:store.movie(valid.id))
        try Data("invalid JSON".utf8).write(to:store.directory(valid.id).appendingPathComponent("draft.json"))
        XCTAssertTrue(try store.list().isEmpty)
    }
}
