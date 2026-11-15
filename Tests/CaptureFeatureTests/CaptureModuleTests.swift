import CaptureControlAPI
import HotkeyCore
import AppKit
import AgentCore
import CaptureCore
import CaptureScriptCore
import ModuleKit
import XCTest
@testable import CaptureFeature

@MainActor final class CaptureModuleTests: XCTestCase {
    final class Flag { var on = false; var accessRequests = 0 }
    enum Failure: Error { case release }
    final class Lease: CleanScreenHotkeyLease {
        var released = false; var fails = false
        func release() throws { if fails { throw Failure.release }; released = true }
    }
    final class Backend: CleanScreenHotkeyBackend {
        var leases: [Lease] = []; var events: [(Bool) -> Void] = []
        func register(_ key: CleanScreenKeyBinding, event: @escaping (Bool) -> Void) throws -> CleanScreenHotkeyLease {
            let lease = Lease(); leases.append(lease); events.append(event); return lease
        }
    }
    func workspace(_ flag: Flag, root: URL, backend: Backend) -> CaptureWorkspace {
        let shortcuts = CaptureShortcutModel(backend: backend, read: { nil }, write: { _ in }, pinFocused: { false }, execute: { _ in })
        return CaptureWorkspace(pinSession: CapturePinSession(store: .init(root: root)),
            screenCaptureAccess: { flag.accessRequests += 1; return false },
            featureEnabled: { flag.on }, shortcuts: shortcuts)
    }

    func testColdOffNeverRegistersHotkeysOrAsksForScreenAccess() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = Flag(), backend = Backend(), model = workspace(flag, root: root, backend: backend)
        defer { model.shutdown() }
        model.activate(); model.capture(); model.captureScrolling(); model.recordScreen(); model.recordScreen(draftsOnly: true)
        model.showSavingSettings(); model.showActionSettings(); model.pinClipboard(); model.showPinLibrary()
        XCTAssertTrue(backend.leases.isEmpty)
        XCTAssertEqual(flag.accessRequests, 0)
        XCTAssertFalse(model.capturing || model.recordingActive)
        XCTAssertThrowsError(try model.perform(.screenshot))
        do { _ = try await model.executeScript("return 1;"); XCTFail("started worker while off") } catch {}
        let host=CaptureCLIHost(),access=CaptureExecutionAccess(canUse:{model.enabled},workspace:{model})
        for operation in [CaptureControlRequest.Operation.run("return 1;"),.action("status")] {
            let response=await host.handle(.init(id:UUID(),operation:operation,dryRun:true),access:access)
            XCTAssertFalse(response.succeeded);XCTAssertTrue(response.report.issue?.contains("switched off") == true)
        }
        XCTAssertFalse(model.scriptRunning)
    }
    func testEnablePrewarmsOnceStopReleasesAndReenableRegistersAgain() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = Flag(), backend = Backend(), model = workspace(flag, root: root, backend: backend)
        defer { model.shutdown() }
        flag.on = true; model.activate()
        let count = backend.leases.count
        XCTAssertGreaterThan(count, 0)
        model.activate(); XCTAssertEqual(backend.leases.count, count)
        XCTAssertEqual(flag.accessRequests, 0, "prewarming never asks for screen recording")
        try model.stopFeature(); flag.on = false
        XCTAssertTrue(backend.leases.allSatisfy { $0.released })
        flag.on = true; model.activate()
        XCTAssertEqual(backend.leases.count, count * 2)
    }
    func testBusyOrUnconfirmedShortcutReleaseRefusesStop() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = Flag(), backend = Backend(), model = workspace(flag, root: root, backend: backend)
        defer { model.shutdown() }
        flag.on = true; model.activate(); model.scriptRunning = true
        XCTAssertThrowsError(try model.stopFeature())
        XCTAssertFalse(backend.leases.contains { $0.released })
        model.scriptRunning = false
        let lease = try XCTUnwrap(backend.leases.first); lease.fails = true
        XCTAssertThrowsError(try model.stopFeature())
        XCTAssertTrue(model.shortcuts.uncertain)
        let count = backend.leases.count; model.activate()
        XCTAssertEqual(backend.leases.count, count, "never reregister over an uncertain lease")
        lease.fails = false; try model.stopFeature()
        XCTAssertTrue(lease.released)
    }


}
