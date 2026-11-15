import AppKit
import XCTest
import ModuleKit
@testable import CleanKit
@testable import SpaceFeature
@testable import ThermoApp

final class SpaceRemovalProtectionIntegrationTests:XCTestCase {
    private final class Calls:@unchecked Sendable {
        private let lock=NSLock();private var count=0
        func next(){lock.lock();count+=1;lock.unlock()}
        var value:Int{lock.lock();defer{lock.unlock()};return count}
    }
    @MainActor func testConfirmedManualRemovalPinsSelectionAndBlocksQuitUntilWorkerReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Downloads/item").path
        try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
        let expected = try XCTUnwrap(ManualRemoval.reviewIdentity(path))
        let began = expectation(description: "moving"), release = DispatchSemaphore(value: 0), calls = Calls()
        defer { release.signal() }
        let model = SpaceLensModel(services:SpaceHostServices(),root: root.path, cache: root.appendingPathComponent("cache.json"), remove: { paths, _, _, _, identities, _ in
            calls.next(); XCTAssertEqual(paths, [path]); XCTAssertEqual(identities[path], expected)
            began.fulfill(); _ = release.wait(timeout: .now() + 5)
            return CleanResult(id: "manual", trashed: true)
        })
        model.toggle(path, bytes: 7); model.trash()
        await fulfillment(of: [began], timeout: 2)
        model.trash(); model.scan(); model.clearBasket(); model.toggle(path, bytes: 7)
        XCTAssertTrue(model.working); XCTAssertFalse(model.scanning); XCTAssertEqual(model.basket.count, 1); XCTAssertEqual(calls.value, 1)
        var shown: [MainPage] = []
        XCTAssertEqual(AppExitGuard.reply(show: { shown.append($0) }), .terminateCancel)
        XCTAssertEqual(shown, [.native(.init(BuiltinModuleManifests.space.id,"browse"))]); XCTAssertTrue(model.exitRequested)
        release.signal()
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.working)
        XCTAssertEqual(AppExitGuard.reply(show: { _ in }), .terminateNow)
    }
}
