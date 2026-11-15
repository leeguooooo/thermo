import AppKit
import XCTest
@testable import CleanKit
@testable import ThermoApp

@MainActor final class SpaceSkippedRemovalTests:XCTestCase {
    private final class Calls:@unchecked Sendable {
        private let lock=NSLock();private var count=0
        func hit(){lock.lock();count+=1;lock.unlock()}
        var value:Int {lock.lock();defer{lock.unlock()};return count}
    }
    private func checkSkippedRemoval(permanent:Bool)async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-skipped-removal-"+UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Downloads"),withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("Downloads/item"),bytes=Data("fixture".utf8),calls=Calls()
        try bytes.write(to:file)
        let model=SpaceLensModel(root:root.path,cache:root.appendingPathComponent("cache.json"),remove:{_,_,_,_,_,_ in calls.hit();return .init(id:"fixture",trashed:true)},delete:{_,_,_,_,_,_ in calls.hit();return .init(id:"fixture",trashed:false)})
        model.toggle(file.path,bytes:Int64(bytes.count))
        XCTAssertNotNil(model.removalReview())
        model.trash(permanent:permanent)
        XCTAssertTrue(model.working)
        // Detached work cannot pass its MainActor recheck until this synchronous turn yields.
        model.work.cancel()
        await model.work.finish()
        XCTAssertEqual(calls.value,0)
        XCTAssertFalse(model.working)
        XCTAssertTrue(model.canStopFeature)
        XCTAssertEqual(AppExitGuard.reply(show:{_ in}),.terminateNow)
        XCTAssertEqual(model.basket[file.path],Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testSkippedTrashReleasesBusyStateAndGlobalExitLease()async throws {try await checkSkippedRemoval(permanent:false)}
    func testSkippedPermanentRemovalReleasesBusyStateAndGlobalExitLease()async throws {try await checkSkippedRemoval(permanent:true)}
}
