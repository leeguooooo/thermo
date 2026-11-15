import XCTest
import ModuleKit
@testable import ThermoApp

@MainActor final class SearchHostIntegrationTests:XCTestCase {
    func testSearchManifestAndWorkerOwnershipStayInTheRegistry() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty, BuiltinModules.problems.joined(separator:"\n"))
        XCTAssertEqual(BuiltinModules.workerOwner(SearchModule.previewWorker)?.manifest.id,SearchModule.manifest.id)
        XCTAssertTrue(SearchModule.manifest.entries.allSatisfy(SearchModule.supports))
        XCTAssertEqual(SearchModule.manifest.launch,.prewarm)
    }
    func testDisabledSearchAppControlCannotPretendItsWindowWasOpened() async {
        let defaults=UserDefaults.standard,previous=defaults.volatileDomain(forName:UserDefaults.argumentDomain)
        defer{defaults.setVolatileDomain(previous,forName:UserDefaults.argumentDomain)}
        var domain=previous;domain[ModulePreferences.key(BuiltinModuleManifests.search.id)]=false
        defaults.setVolatileDomain(domain,forName:UserDefaults.argumentDomain)
        let host=AppControlHost()
        for action in ["search.show","search.settings","search.useCommandSpace"] {
            let result=await host.handle(AppControlRequest(action:action,dryRun:true))
            XCTAssertFalse(result.succeeded)
            XCTAssertTrue(result.issue?.contains("switched off")==true)
            XCTAssertNil(result.values["windowVisible"])
        }
    }
}
