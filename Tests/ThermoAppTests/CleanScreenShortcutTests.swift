import XCTest
import Carbon
@testable import ThermoApp

@MainActor final class CleanScreenShortcutTests: XCTestCase {
    final class Lease: CleanScreenHotkeyLease {
        var releases=0, fail=false
        func release() throws { releases+=1;if fail { throw Failure.fixture } }
    }
    enum Failure: Error { case fixture }
    final class Backend: CleanScreenHotkeyBackend {
        var values:[CleanScreenKeyBinding]=[], events:[(Bool)->Void]=[], leases:[Lease]=[]
        var fail=false
        func register(_ binding: CleanScreenKeyBinding,event:@escaping (Bool)->Void) throws -> CleanScreenHotkeyLease {
            if fail { throw Failure.fixture }
            values.append(binding);events.append(event);let lease=Lease();leases.append(lease);return lease
        }
    }
    final class Store { var data:Data?; var writes=0;var actions=0 }
    func key(_ code: UInt32=8,_ label:String="C") -> CleanScreenKeyBinding {
        .init(keyCode:code,modifiers:UInt32(cmdKey)|UInt32(controlKey)|UInt32(optionKey),keyLabel:label)
    }
    func model(_ backend: Backend,_ store:Store) -> CleanScreenShortcutModel {
        .init(backend:backend,read:{store.data},write:{store.data=$0;store.writes+=1},action:{store.actions+=1})
    }
    func testOffByDefaultNeverRegistersOrWritesPreferences() {
        let backend=Backend(),store=Store();let model=model(backend,store);model.activate();model.activate()
        XCTAssertNil(model.binding);XCTAssertTrue(backend.values.isEmpty);XCTAssertEqual(store.writes,0);model.shutdown()
    }
    func testSavedBindingRestoresOnceAndShutdownKeepsPreference() throws {
        let backend=Backend(),store=Store();store.data=try JSONEncoder().encode(key());let saved=store.data
        let model=model(backend,store);model.activate();model.activate()
        XCTAssertEqual(backend.values,[key()]);XCTAssertEqual(store.writes,0)
        model.shutdown();XCTAssertEqual(backend.leases[0].releases,1);XCTAssertEqual(store.data,saved)
    }
    func testInvalidOrOversizedPreferencesDoNotRegisterAndCanBeCleared() {
        for data in [Data("not json".utf8),Data(repeating:0,count:1025)] {
            let backend=Backend(),store=Store();store.data=data;let model=model(backend,store);model.activate()
            XCTAssertNil(model.binding);XCTAssertNotNil(model.issue);XCTAssertTrue(backend.values.isEmpty)
            model.apply(nil);XCTAssertNil(store.data);XCTAssertNil(model.issue);model.shutdown()
        }
    }
    func testConflictKeepsTheWorkingBindingAndStoredValue() {
        let backend=Backend(),store=Store();let model=model(backend,store);model.apply(key());let saved=store.data
        backend.fail=true;model.apply(key(40,"K"))
        XCTAssertEqual(model.binding,key());XCTAssertEqual(store.data,saved);XCTAssertNotNil(model.issue)
        XCTAssertEqual(backend.leases[0].releases,0);backend.events[0](true);XCTAssertEqual(store.actions,1);model.shutdown()
    }
    func testReplacementIgnoresQueuedEventsForThePreviousRegistration() {
        let backend=Backend(),store=Store();let model=model(backend,store);model.apply(key());model.apply(key(40,"K"))
        XCTAssertEqual(backend.leases[0].releases,1)
        backend.events[0](true);XCTAssertEqual(store.actions,0)
        backend.events[1](true);XCTAssertEqual(store.actions,1);model.shutdown()
    }
    func testRepeatedPressesDoNotToggleUntilReleaseIncludingInterceptedInput() {
        let backend=Backend(),store=Store();let model=model(backend,store);let binding=key();model.apply(binding)
        backend.events[0](true);backend.events[0](true)
        model.input(code:8,flags:binding.modifiers,down:true,repeated:false)
        XCTAssertEqual(store.actions,1)
        model.input(code:8,flags:0,down:false,repeated:false)
        model.input(code:8,flags:binding.modifiers,down:true,repeated:true);XCTAssertEqual(store.actions,1)
        model.input(code:8,flags:binding.modifiers,down:true,repeated:false);XCTAssertEqual(store.actions,2);model.shutdown()
    }
    func testRecordOldShortcutDoesNotStartScreenAndFocusLossIsOwnerBound() {
        let backend=Backend(),store=Store();let model=model(backend,store);model.apply(key())
        let a=UUID(),b=UUID();model.beginRecording(a);model.beginRecording(b);model.cancelRecording(a)
        XCTAssertEqual(model.recordingOwner,b)
        backend.events[0](true);XCTAssertNil(model.recordingOwner);XCTAssertEqual(store.actions,0)
        backend.events[0](false);backend.events[0](true);XCTAssertEqual(store.actions,1);model.shutdown()
    }
    func testInvalidRecordingPreservesTheOldBindingAndAllowsRetry() {
        let backend=Backend(),store=Store();let model=model(backend,store);model.apply(key());let owner=UUID();model.beginRecording(owner)
        model.record(.init(keyCode:0,modifiers:0,keyLabel:"A"),owner:owner)
        XCTAssertEqual(model.binding,key());XCTAssertNotNil(model.issue);XCTAssertEqual(model.recordingOwner,owner)
        model.record(key(40,"K"),owner:owner);XCTAssertEqual(model.binding,key(40,"K"));XCTAssertNil(model.recordingOwner);model.shutdown()
    }
    func testReleaseFailureDisablesActionsAndClearsAutoRegistrationOnRestart() {
        let backend=Backend(),store=Store();let model=model(backend,store);model.apply(key());backend.leases[0].fail=true
        model.apply(key(40,"K"));XCTAssertTrue(model.uncertain);XCTAssertNil(model.binding);XCTAssertNil(store.data);XCTAssertNotNil(model.issue)
        XCTAssertEqual(backend.leases[1].releases,1)
        backend.events[0](true);backend.events[1](true);XCTAssertEqual(store.actions,0)
        model.apply(key(1,"S"));XCTAssertEqual(backend.values.count,2)
        backend.leases[0].fail=false;model.shutdown()
    }
    func testChangingOnlyTheDisplayLabelDoesNotReregisterThePhysicalGesture() {
        let backend=Backend(),store=Store();let model=model(backend,store);model.apply(key());model.apply(key(8,"С"))
        XCTAssertEqual(backend.values.count,1);XCTAssertEqual(model.binding?.keyLabel,"С")
        backend.events[0](true);XCTAssertEqual(store.actions,1);model.shutdown()
    }
    func testClearReleasesOnlyItsLeaseAndLateEventsDoNothing() {
        let backend=Backend(),store=Store();let model=model(backend,store);model.apply(key());model.apply(nil)
        XCTAssertEqual(backend.leases[0].releases,1);XCTAssertNil(store.data)
        backend.events[0](true);XCTAssertEqual(store.actions,0);model.shutdown();XCTAssertEqual(backend.leases[0].releases,1)
    }
    func testNewRecordingCannotFireUntilItsCaptureKeyIsReleased() {
        let backend=Backend(),store=Store();let model=model(backend,store);let owner=UUID()
        model.beginRecording(owner);model.record(key(),owner:owner)
        backend.events[0](true);XCTAssertEqual(store.actions,0)
        backend.events[0](false);backend.events[0](true);XCTAssertEqual(store.actions,1);model.shutdown()
    }
    func testBindingValidationRejectsReservedKeysAndUnknownFlags() {
        XCTAssertTrue(key().valid);XCTAssertEqual(key().label,"⌃⌥⌘C")
        for binding in [key(53,"Esc"),key(55,"Command"),key(128,"X"),.init(keyCode:8,modifiers:UInt32(shiftKey),keyLabel:"C"),
                        .init(keyCode:8,modifiers:key().modifiers|0x80000000,keyLabel:"C"),key(8,"\u{1b}")] { XCTAssertFalse(binding.valid) }
    }
}
