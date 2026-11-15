package struct SearchShortcutResult:Sendable {
    package let label:String
    package let spotlightReleased:Bool
    package let confirmed:Bool
    package let issue:String?
    package init(label:String,spotlightReleased:Bool,confirmed:Bool,issue:String?) {
        self.label=label;self.spotlightReleased=spotlightReleased;self.confirmed=confirmed;self.issue=issue
    }
}
@MainActor package protocol SearchApplicationAccess:AnyObject {
    func show(settings:Bool)->Bool
    func takeOverSpotlight()->SearchShortcutResult
    func giveBackSpotlight()->SearchShortcutResult
}
