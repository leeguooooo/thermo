import XCTest
import ModuleKit
import NativeFeatureAPI
import AgentDiagnosticsFeature
@testable import ThermoApp

@MainActor final class AgentHostRoutingTests:XCTestCase {
    func testAllAreasAndHomeResolveToDeclaredPagesAndCommandSix() {
        XCTAssertTrue(NativeModules.problems.isEmpty,NativeModules.problems.joined(separator:"\n"))
        XCTAssertFalse(HostPageSpecification.pages.contains{$0.argument=="agents"})
        let manifest=BuiltinModuleManifests.agents
        XCTAssertEqual(NativeModules.page(.native(.init(manifest.id,"home")))?.entry.navigationKey,"6")
        for entry in manifest.entries {
            let page=MainPage.native(.init(manifest.id,entry.id))
            XCTAssertEqual(MainPage(argument:entry.scene!),page)
            XCTAssertEqual(NativeModules.page(page)?.target,page)
            XCTAssertEqual(NativeModules.page(.module(manifest.id,entry.id))?.target,page)
            XCTAssertEqual(MainPage.module(manifest.id,entry.id).nativeRoute,page.nativeRoute)
        }
    }
    func testOffWindowUIAndNavigationStayCold() {
        let name="thermo-agent-host-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.agents.id))
        var made=0
        let original=AgentDiagnosticsFeature.registration
        let definition=NativeFeatureDefinition(manifest:original.manifest,ui:original.ui,makeSession:{_ in made+=1;fatalError("off UI")})
        let models=AppModels(defaults:defaults,nativeDefinitions:[definition]),center=ModuleCenter(defaults:defaults)
        let ui=models.nativeFeatures.windowUI(selection:.init(original.manifest.id,"home"),locations:[.agents])
        XCTAssertTrue(ui.sidebar.isEmpty);XCTAssertNil(ui.backdrop)
        XCTAssertNil(center.navigationKey(.native(.init(original.manifest.id,"home"))))
        XCTAssertFalse(center.shows(.native(.init(original.manifest.id,"mcp"))))
        XCTAssertFalse(models.nativeFeatures.status(original.manifest.id).modelLoaded);XCTAssertEqual(made,0)
        defaults.set(true,forKey:ModulePreferences.key(original.manifest.id))
        XCTAssertEqual(center.navigationKey(.native(.init(original.manifest.id,"home"))),"6")
    }
}
