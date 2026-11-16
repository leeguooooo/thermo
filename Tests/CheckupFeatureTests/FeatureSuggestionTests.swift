import Foundation
import ModuleKit
import NativeFeatureAPI
import LocalAIUI
import XCTest
@testable import CleanKit
@testable import CheckupFeature

@MainActor private final class CheckupDiscoveryProbe:FeatureDiscoveryAccess {
    let item=FeatureDiscoveryItem(id:"com.example.inspection",name:"Inspection",summary:"Inspect this finding",symbol:"cpu",storage:"Built in",permissions:[])
    var recommendationsEnabled=true,seen=false,enableCalls=0,claimCalls=0
    func matches(_ query:String)->[FeatureDiscoveryItem]{[]}
    func enable(_ reviewed:FeatureDiscoveryItem)throws{XCTAssertEqual(reviewed,item);enableCalls+=1}
    func claimRecommendation(_ id:String)->FeatureDiscoveryItem? {
        claimCalls+=1
        guard recommendationsEnabled,!seen,id==item.id else{return nil}
        seen=true;return item
    }
}
@MainActor final class FeatureSuggestionTests:XCTestCase {
    func testOneReportDoesNotRepeatSuggestionsAndReviewBlocksStopUntilCancelled() async {
        let name="thermo-owned-suggestion-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let service=CheckupDiscoveryProbe()
        let model=CheckupModel(defaults:defaults,measure:{_,_ in .init()},
            backend:{.http(name:"Fixture",base:URL(string:"https://example.invalid")!,model:"Fixture")},
            asker:{_,_ in .init(overall:.attention,summary:"Fixture",findings:[],source:"fixture",made:Date())})
        model.discovery=service
        model.start(reading:nil);await model.work.finish();model.send();await model.work.finish()
        model.refreshSuggestions(modules:[service.item.id,service.item.id])
        XCTAssertEqual(model.featureSuggestions,[service.item]);XCTAssertEqual(service.claimCalls,1)
        model.reviewFeature(service.item);XCTAssertFalse(model.canStopFeature);XCTAssertEqual(service.enableCalls,0)
        model.cancelFeatureReview();XCTAssertTrue(model.canStopFeature);XCTAssertEqual(service.enableCalls,0)
        model.dismissSuggestion(service.item.id)
        model.refreshSuggestions(modules:[service.item.id]);XCTAssertTrue(model.featureSuggestions.isEmpty);XCTAssertEqual(service.claimCalls,1)
        model.recommendationsEnabled=false;XCTAssertFalse(service.recommendationsEnabled)
        model.stopFeature();await model.finishFeatureStop()
    }
}
