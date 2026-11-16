import Foundation

/// Display data only. Looking for a disabled feature must not create its session.
package struct FeatureDiscoveryItem:Identifiable,Equatable,Sendable {
    package let id:String
    package let name:String
    package let summary:String
    package let symbol:String
    package let storage:String
    package let permissions:[String]
    package init(id:String,name:String,summary:String,symbol:String,storage:String,permissions:[String]) {
        self.id=id;self.name=name;self.summary=summary;self.symbol=symbol;self.storage=storage;self.permissions=permissions
    }
}
@MainActor package protocol FeatureDiscoveryAccess:AnyObject {
    func matches(_ query:String)->[FeatureDiscoveryItem]
    func enable(_ reviewed:FeatureDiscoveryItem)throws
    var recommendationsEnabled:Bool {get set}
    /// A suggestion is claimed once, even across reports and application launches.
    func claimRecommendation(_ id:String)->FeatureDiscoveryItem?
}
@MainActor package final class UnavailableFeatureDiscovery:FeatureDiscoveryAccess {
    package init(){}
    package func matches(_ query:String)->[FeatureDiscoveryItem]{[]}
    package func enable(_ reviewed:FeatureDiscoveryItem)throws{throw NativeFeatureBusy("Feature discovery is unavailable.")}
    package var recommendationsEnabled=false
    package func claimRecommendation(_ id:String)->FeatureDiscoveryItem?{nil}
}
