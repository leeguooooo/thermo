import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureShortcutModelTests:XCTestCase {
    enum Failure:Error { case fixture }
    final class Lease:CleanScreenHotkeyLease { var released=false,fail=false;func release() throws { if fail { throw Failure.fixture };released=true } }
    final class Backend:CleanScreenHotkeyBackend {
        var keys:[CleanScreenKeyBinding]=[],events:[(Bool)->Void]=[],leases:[Lease]=[];var blocked:Set<UInt32>=[]
        func register(_ key:CleanScreenKeyBinding,event:@escaping(Bool)->Void) throws -> CleanScreenHotkeyLease {
            if blocked.contains(key.keyCode) { throw Failure.fixture };keys.append(key);events.append(event);let lease=Lease();leases.append(lease);return lease
        }
    }
    final class Store { var data:Data?;var fail=false;var actions:[CaptureAction]=[];var focused=false }
    private func setup(_ settings:CaptureActionSettings = .defaults) throws -> (CaptureShortcutModel,Backend,Store) {
        _=NSApplication.shared;let backend=Backend(),store=Store();store.data=try settings.data()
        let model=CaptureShortcutModel(backend:backend,read:{store.data},write:{ if store.fail { throw Failure.fixture };store.data=$0 },pinFocused:{store.focused},execute:{store.actions.append($0) });model.activate();return(model,backend,store)
    }
    func testHeldKeysAndScopePrecedenceDoNotDoubleExecute() throws {
        var settings=CaptureActionSettings.defaults;let key=settings.entries[0].shortcut!;settings.entries.append(.init(action:.toggleLock,scope:.pin,shortcut:key))
        let (model,backend,store)=try setup(settings);defer { model.shutdown() }
        let index=backend.keys.firstIndex { $0.keyCode == 20 }!
        backend.events[index](true);backend.events[index](true);XCTAssertEqual(store.actions,[.screenshot]);backend.events[index](false)
        store.focused=true;model.receive(key,down:true);model.receive(key,down:true);XCTAssertEqual(store.actions,[.screenshot,.toggleLock]);model.receive(key,down:false)
        var disabled=settings;disabled.shortcutsEnabled=false;XCTAssertTrue(model.apply(disabled));model.receive(key,down:true);XCTAssertEqual(store.actions.count,2)
    }
    func testFailedRegistrationAndPersistenceKeepPreviousSettingsAndLeases() throws {
        let (model,backend,store)=try setup();defer { model.shutdown() };let original=model.settings,saved=store.data
        var next=original;next.entries[0].shortcut = .init(keyCode:80,modifiers:CaptureShortcut.control,keyLabel:"F19");backend.blocked=[80]
        XCTAssertFalse(model.apply(next));XCTAssertEqual(model.settings,original);XCTAssertEqual(store.data,saved);XCTAssertFalse(backend.leases[0].released)
        backend.blocked=[];store.fail=true;XCTAssertFalse(model.apply(next));XCTAssertEqual(model.settings,original);XCTAssertEqual(store.data,saved);XCTAssertTrue(backend.leases.last!.released)
    }
    func testChangingActionAndSwappingGesturesReuseExistingRegistrations() throws {
        let (model,backend,store)=try setup();defer { model.shutdown() };var next=model.settings
        next.entries[0].action = .hidePins;let key=next.entries[0].shortcut;next.entries[0].shortcut=next.entries[1].shortcut;next.entries[1].shortcut=key
        XCTAssertTrue(model.apply(next));XCTAssertEqual(backend.keys.count,2);model.receive(key!,down:true);XCTAssertEqual(store.actions,[.pinClipboard])
    }
    func testApplyWhileKeyIsHeldDoesNotRetriggerChangedAction() throws {
        let (model,backend,store)=try setup();defer { model.shutdown() };let index=backend.keys.firstIndex { $0.keyCode == 20 }!
        backend.events[index](true);var next=model.settings;next.entries[0].action = .hidePins;XCTAssertTrue(model.apply(next))
        backend.events[index](true);XCTAssertEqual(store.actions,[.screenshot]);backend.events[index](false);backend.events[index](true);XCTAssertEqual(store.actions,[.screenshot,.hidePins])
    }
    func testReleaseFailureFreezesCallbacksAndRetainsRecoverablePreferences() throws {
        let (model,backend,store)=try setup();defer { model.shutdown() };let original=model.settings;backend.leases[0].fail=true
        var next=original;next.shortcutsEnabled=false;XCTAssertFalse(model.apply(next));XCTAssertTrue(model.uncertain);XCTAssertEqual(try CaptureActionSettings.decode(store.data!),original)
        backend.events[0](true);XCTAssertTrue(store.actions.isEmpty);XCTAssertFalse(model.apply(original))
    }
    func testRecordingDoesNotRunTheRecordedActionAndInvalidSavedProfilesStayInactive() throws {
        let (model,backend,store)=try setup();defer { model.shutdown() };let owner=UUID();var recorded:CaptureShortcut?
        model.beginRecording(owner) { recorded=$0 };backend.events[0](true);XCTAssertNotNil(recorded);XCTAssertTrue(store.actions.isEmpty);XCTAssertNil(model.recordingOwner)
        let bad=CaptureShortcutModel(backend:Backend(),read:{ Data("broken".utf8) },write:{ _ in XCTFail("Do not overwrite invalid preferences") },pinFocused:{false},execute:{ _ in XCTFail() });bad.activate();defer { bad.shutdown() };XCTAssertFalse(bad.settings.shortcutsEnabled);XCTAssertNotNil(bad.issue)
    }
    func testRuntimePinActionTargetsPinnedContentAndPreservesGroupOwnership() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let session=CapturePinSession(store:.init(root:root)),workspace=CaptureWorkspace(pinSession:session)
        let id=try session.open(.text(.init(plain:"Action QA"))),editor=try XCTUnwrap(session.windows[id]);try session.showPin(id)
        try workspace.perform(.toggleLock);XCTAssertTrue(editor.model.locked);try workspace.perform(.toggleTop);XCTAssertFalse(editor.model.pinned)
        XCTAssertThrowsError(try workspace.perform(.rotate));let group=try session.createGroup(name:"Other");try workspace.perform(.previousGroup);XCTAssertNotEqual(session.library.currentGroupID,group)
        try workspace.perform(.togglePins);XCTAssertTrue(session.library.pins[0].hidden);try workspace.perform(.showPin);XCTAssertFalse(session.library.pins[0].hidden)
        session.closeAll();workspace.shortcuts.shutdown()
    }
}
