import Foundation

@MainActor package protocol DiskServices:AnyObject {
    func requestScanNotifications()
    /// Prepare the validated path and select its canonical page, including an off-feature page.
    @discardableResult func revealInSpace(_ path:String)->Bool
}
