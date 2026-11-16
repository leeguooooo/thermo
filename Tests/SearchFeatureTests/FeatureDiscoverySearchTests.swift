import Foundation
import NativeFeatureAPI
import SearchCore
import XCTest
@testable import SearchFeature

@MainActor private final class SearchDiscoveryProbe:FeatureDiscoveryAccess {
    let item=FeatureDiscoveryItem(id:"com.example.capture",name:"Recording",summary:"Record the screen",symbol:"viewfinder",storage:"Built in",permissions:["Screen Recording"])
    var enabled=false,enableCalls=0,recommendationsEnabled=false
    func matches(_ query:String)->[FeatureDiscoveryItem]{query=="record" && !enabled ? [item]:[]}
    func enable(_ reviewed:FeatureDiscoveryItem)throws{XCTAssertEqual(reviewed,item);enabled=true;enableCalls+=1}
    func claimRecommendation(_ id:String)->FeatureDiscoveryItem?{nil}
}
@MainActor final class FeatureDiscoverySearchTests:XCTestCase {
    func testKeyboardSelectionReviewsBeforeEnablingAndCancelDoesNotEnable() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-owned-discovery-search-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let service=SearchDiscoveryProbe(),model=LocalSearchModel(directory:root,executeQuery:{term,_ in .init(query:term,items:[])})
        model.discovery=service;model.query="record"
        for _ in 0..<100 where model.searching {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(model.featureChoices,[service.item]);XCTAssertEqual(service.enableCalls,0)
        model.openSelected()
        XCTAssertEqual(model.featureReview,service.item);XCTAssertTrue(model.presentingDialog)
        model.cancelFeatureReview();XCTAssertEqual(service.enableCalls,0);XCTAssertFalse(model.presentingDialog)
        model.openSelected();model.enableReviewedFeature()
        XCTAssertEqual(service.enableCalls,1);XCTAssertTrue(model.featureChoices.isEmpty);XCTAssertNil(model.featureReview)
        model.stop();await model.finishStopping()
    }
}
