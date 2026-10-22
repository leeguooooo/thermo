import XCTest
@testable import CaptureCore

final class CaptureActionSettingsTests:XCTestCase {
    func testDefaultsPreserveGesturesAndRoundTripStableActionIDs() throws {
        let settings=CaptureActionSettings.defaults;XCTAssertTrue(settings.valid)
        XCTAssertEqual(settings.entries.map(\.action),[.screenshot,.pinClipboard]);XCTAssertEqual(settings.entries[0].shortcut?.label,"⌥⌘3")
        XCTAssertEqual(try CaptureActionSettings.decode(settings.data()),settings)
        XCTAssertTrue(String(data:try settings.data(),encoding:.utf8)!.contains("pinClipboard"))
        XCTAssertFalse(settings.entries[0].appearsInMenu)
        var old=try JSONSerialization.jsonObject(with:settings.data()) as! [String:Any];var entries=old["entries"] as! [[String:Any]];entries[0].removeValue(forKey:"showInMenu");old["entries"]=entries
        XCTAssertTrue(try CaptureActionSettings.decode(JSONSerialization.data(withJSONObject:old)).entries[0].appearsInMenu)
    }
    func testGlobalAndPinScopesValidateTheirOwnGestures() {
        let letter=CaptureShortcut(keyCode:0,modifiers:0,keyLabel:"A"),escape=CaptureShortcut(keyCode:53,modifiers:0,keyLabel:"Esc"),function=CaptureShortcut(keyCode:79,modifiers:0,keyLabel:"F18")
        XCTAssertTrue(letter.valid);XCTAssertFalse(letter.validGlobal);XCTAssertTrue(escape.valid);XCTAssertFalse(escape.validGlobal);XCTAssertTrue(function.validGlobal)
        XCTAssertTrue(CaptureShortcut(keyCode:20,modifiers:CaptureShortcut.control,keyLabel:"3").validGlobal)
        var entry=CaptureShortcutEntry(action:.closePin,scope:.pin,shortcut:letter);XCTAssertTrue(entry.valid);entry.scope = .global;XCTAssertFalse(entry.valid)
    }
    func testDuplicateContextUnknownActionsAndOversizedProfilesAreRejected() throws {
        var settings=CaptureActionSettings.defaults;var duplicate=settings.entries[0];duplicate.id=UUID();settings.entries.append(duplicate);XCTAssertFalse(settings.valid)
        settings.entries[2].scope = .pin;XCTAssertTrue(settings.valid)
        let data=try settings.data(),string=String(data:data,encoding:.utf8)!.replacingOccurrences(of:"screenshot",with:"unknownAction")
        XCTAssertThrowsError(try CaptureActionSettings.decode(Data(string.utf8)))
        XCTAssertThrowsError(try CaptureActionSettings.decode(Data(repeating:32,count:65537)))
    }
}
