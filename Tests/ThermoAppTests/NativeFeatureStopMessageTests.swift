import XCTest
import ModuleKit
import NativeFeatureAPI
@testable import ThermoApp

@MainActor final class NativeFeatureStopMessageTests:XCTestCase {
    func testBusyRefusalKeepsFeatureOnAndDisplaysItsActualReason() {
        let name="thermo-stop-message-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let id=BuiltinModuleManifests.apps.id,reason="Wait for the reviewed app update to finish."
        defaults.set(true,forKey:ModulePreferences.key(id))
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in throw NativeFeatureBusy(reason)})
        center.setEnabled(id,false)
        XCTAssertTrue(defaults.bool(forKey:ModulePreferences.key(id)))
        XCTAssertEqual(center.switchIssues[id],reason)
        XCTAssertTrue(center.changing.isEmpty)
    }
}
