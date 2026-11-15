import AppKit
import ModuleKit
import NativeFeatureAPI
import XCTest
@testable import ThermoApp

@MainActor final class DiskExitGuardIntegrationTests:XCTestCase {
    func testBusyDiskFeaturePreventsApplicationExitAndOpensItsReviewPage() {
        let route=NativeFeatureRoute(BuiltinModuleManifests.disk.id,"scan")
        var shown:[MainPage]=[]
        let reply=AppExitGuard.reply(nativeBlocker:{id in
            id==route.module ? .init(reason:"fixture cleanup is writing",route:route):nil
        },show:{shown.append($0)})
        XCTAssertEqual(reply,.terminateCancel)
        XCTAssertEqual(shown,[.native(route)])
    }
}
