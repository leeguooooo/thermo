import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

final class CapturePinSessionTests:XCTestCase {
    @MainActor private func image() throws -> CGImage {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:80,height:60,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));return try XCTUnwrap(ctx.makeImage())
    }
    @MainActor func testSwitchMoveCloseAndRestoreKeepGroupsIndependent() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let session=CapturePinSession(store:.init(root:root)),firstGroup=session.library.currentGroupID
        let first=try session.open(image());let other=try session.createGroup(name:"Other")
        XCTAssertEqual(session.count,0);XCTAssertFalse(session.windows[first]?.window?.isVisible ?? true)
        let second=try session.open(image());session.windows[second]?.model.pinTitle="Second"
        session.closeAll();XCTAssertNotNil(session.library.pins.first { $0.id == second }?.closedAt);XCTAssertEqual(session.count,0)
        try session.switchGroup(firstGroup);try session.restore();XCTAssertEqual(session.count,1)
        XCTAssertNotNil(session.library.pins.first { $0.id == second }?.closedAt)
        try session.movePin(first,to:other);XCTAssertEqual(session.count,0)
        try session.switchGroup(other);try session.restore(second);XCTAssertEqual(session.count,2)
        try session.setAllHidden(true);XCTAssertFalse(session.windows[first]?.window?.isVisible ?? true)
        try session.setAllHidden(false);XCTAssertTrue(session.windows[first]?.window?.isVisible ?? false)
        session.closeAll()
    }
    @MainActor func testReopenRestoresEditableDocumentAndLastWindowSettings() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let session=CapturePinSession(store:.init(root:root));let id=try session.open(image());let model=try XCTUnwrap(session.windows[id]?.model)
        model.document.append(.init(tool:.rectangle,points:[.zero,CGPoint(x:20,y:20)]));model.opacity=0.6;model.zoom=1.5;model.pan=CGPoint(x:12,y:7);model.pinTitle="Restored";try session.flush()
        let reopened=CapturePinSession(store:.init(root:root));reopened.restoreWindows();let restored=try XCTUnwrap(reopened.windows[id]?.model)
        XCTAssertEqual(restored.document.annotations.count,1);XCTAssertEqual(restored.pinTitle,"Restored");XCTAssertEqual(restored.pan,model.pan);XCTAssertEqual(restored.opacity,0.6)
        // Independent instances cannot overwrite each other after the first commits.
        try reopened.flush();XCTAssertThrowsError(try session.flush())
        for editor in session.windows.values { editor.close() };reopened.closeAll()
    }
    @MainActor func testSaveFailureRefusesWindowCloseAndRetainsPixels() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let session=CapturePinSession(store:.init(root:root));let id=try session.open(image());let window=try XCTUnwrap(session.windows[id]?.window)
        try Data("broken".utf8).write(to:root.appendingPathComponent("library.json"))
        XCTAssertFalse(session.windows[id]!.windowShouldClose(window));XCTAssertNil(session.library.pins[0].closedAt);XCTAssertNotNil(session.issue)
        session.windows[id]?.close()
    }
    @MainActor func testGroupRenameReorderDeleteAndHistoryLimit() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let session=CapturePinSession(store:.init(root:root)),original=session.library.currentGroupID
        let pin=try session.open(image());let group=try session.createGroup(name:"Group",color:"#FF8800")
        XCTAssertThrowsError(try session.createGroup(name:"group"));try session.updateGroup(group,name:"Renamed",color:nil);try session.reorderGroup(group,offset:-1);XCTAssertEqual(session.library.groups.first?.id,group)
        try session.removeGroup(original,movingTo:group);XCTAssertEqual(session.library.pins[0].groupID,group)
        try session.setHistoryLimit(0);session.closeAll();XCTAssertTrue(session.library.pins.isEmpty);XCTAssertNil(session.windows[pin])
        let second=try session.open(image());try session.clearGroup(group);XCTAssertNil(session.windows[second]);XCTAssertTrue(session.library.pins.isEmpty)
    }
    @MainActor func testMovingDormantGroupLoadsItsWindowsAndReloadUsesSavedRevision() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let original=CapturePinSession(store:.init(root:root)),first=original.library.currentGroupID
        let other=try original.createGroup(name:"Other"),pin=try original.open(image())
        try original.switchGroup(first)
        for editor in Array(original.windows.values) { editor.close() }
        let fresh=CapturePinSession(store:.init(root:root));fresh.restoreWindows();XCTAssertNil(fresh.windows[pin])
        try fresh.removeGroup(other,movingTo:first);XCTAssertNotNil(fresh.windows[pin]);XCTAssertEqual(fresh.count,1)
        original.retryLoad();XCTAssertEqual(original.library.groups.count,1);XCTAssertNotNil(original.windows[pin]);try original.flush()
        for editor in Array(fresh.windows.values) { editor.close() };original.closeAll()
    }

}
