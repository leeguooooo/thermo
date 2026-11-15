import AgentCore
import XCTest
import ModuleKit
@testable import ThermoShell
@testable import ThermoComposition

@MainActor final class SearchHostIntegrationTests:ThermoCompositionTestCase {
    func testSearchManifestAndWorkerOwnershipStayInTheRegistry() {
        XCTAssertTrue(NativeModules.problems.isEmpty, NativeModules.problems.joined(separator:"\n"))
        XCTAssertEqual(NativeModules.workerOwner("dev.thermo.search-preview")?.id,BuiltinModuleManifests.search.id)

        XCTAssertEqual(BuiltinModuleManifests.search.launch,.prewarm)
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
