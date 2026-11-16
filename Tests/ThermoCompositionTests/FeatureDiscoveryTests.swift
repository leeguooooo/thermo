import Foundation
import ModuleHost
import ModuleKit
import NativeFeatureAPI
import ThermoL10n
import XCTest
@testable import ThermoShell

@MainActor final class FeatureDiscoveryTests:ThermoCompositionTestCase {
    private func withService(_ body:(FeatureDiscoveryService,ModuleCenter,UserDefaults,()->Int)throws->Void) rethrows {
        let name="thermo-owned-discovery-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModuleCenter.key(BuiltinModuleManifests.capture.id))
        var starts=0
        let center=ModuleCenter(manager:ModuleManager(app:URL(fileURLWithPath:"/nonexistent/ThermoDiscovery.app")),defaults:defaults,startBuiltin:{_ in starts+=1})
        let service=FeatureDiscoveryService(center:center,defaults:defaults,catalog:ShellNativeCatalog.catalog)
        try body(service,center,defaults,{starts})
    }
    func testChineseRecordingIntentUsesMetadataAndRequiresReviewedEnable() throws {
        let language=L10n.override;L10n.override = .simplifiedChinese;defer{L10n.override=language}
        try withService{service,center,_,starts in
            let item=try XCTUnwrap(service.matches("录屏").first)
            XCTAssertEqual(item.id,BuiltinModuleManifests.capture.id)
            XCTAssertTrue(item.storage.contains("无需额外下载"))
            XCTAssertTrue(item.permissions.contains{$0.contains("屏幕录制")})
            XCTAssertEqual(starts(),0,"Searching metadata must not construct or start the disabled feature")
            XCTAssertFalse(center.isOn(item.id))
            try service.enable(item)
            XCTAssertTrue(center.isOn(item.id));XCTAssertEqual(starts(),1)
            try service.enable(item)
            XCTAssertEqual(starts(),1,"A repeated confirmation must not restart an already enabled feature")
            XCTAssertTrue(service.matches("录屏").isEmpty)
        }
    }
    func testChangedAccessDescriptionAndUnknownFeatureCannotBeEnabled() throws {
        let language=L10n.override;L10n.override = .english;defer{L10n.override=language}
        try withService{service,center,defaults,starts in
            let item=try XCTUnwrap(service.matches("recording").first)
            let changed=FeatureDiscoveryItem(id:item.id,name:item.name,summary:item.summary,symbol:item.symbol,storage:item.storage,permissions:[])
            XCTAssertThrowsError(try service.enable(changed))
            XCTAssertFalse(center.isOn(item.id));XCTAssertEqual(starts(),0)
            let unknown=FeatureDiscoveryItem(id:"com.example.unknown",name:"Unknown",summary:"",symbol:"",storage:"",permissions:[])
            XCTAssertThrowsError(try service.enable(unknown))
            XCTAssertNil(defaults.object(forKey:ModuleCenter.key(unknown.id)))
        }
    }
    func testRecommendationOptOutDoesNotConsumeAndSeenChoiceSurvivesServiceRecreation() {
        withService{service,center,defaults,starts in
            let id=BuiltinModuleManifests.capture.id
            service.recommendationsEnabled=false
            XCTAssertNil(service.claimRecommendation(id))
            service.recommendationsEnabled=true
            XCTAssertNotNil(service.claimRecommendation(id))
            XCTAssertNil(service.claimRecommendation(id))
            let next=FeatureDiscoveryService(center:center,defaults:defaults,catalog:ShellNativeCatalog.catalog)
            XCTAssertNil(next.claimRecommendation(id));XCTAssertEqual(starts(),0)
        }
    }
}
