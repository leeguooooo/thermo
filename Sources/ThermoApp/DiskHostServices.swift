import DiskFeature
import Foundation

/// Application policy and cross-feature presentation stay in the assembly adapter.
@MainActor final class DiskHostServices:DiskServices {
    func requestScanNotifications(){Monitor.requestNotificationPermission()}
    func revealInSpace(_ path:String)->Bool {Self.reveal(path)}
    static func reveal(_ path:String,models:AppModels = .shared,open:@MainActor (MainPage)->Void = {MainWindow.show($0)})->Bool {
        guard let page=SpaceModule.reveal(path,models:models) else{return false}
        open(page);return true
    }
}
