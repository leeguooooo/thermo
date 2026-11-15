import Foundation
import SpaceFeature

@MainActor final class SpaceHostServices:SpaceServices {
    func protectRemoval(onQuit:@escaping @MainActor ()->Void)->any SpaceRemovalLease {
        HostSpaceRemovalLease(onQuit:onQuit)
    }
}
@MainActor private final class HostSpaceRemovalLease:SpaceRemovalLease {
    private var token:UUID?
    init(onQuit:@escaping @MainActor ()->Void){token=AppExitGuard.beginManualRemoval(onQuit:onQuit)}
    func finish(){if let token {self.token=nil;AppExitGuard.endManualRemoval(token)}}
    deinit {if let token {Task{@MainActor in AppExitGuard.endManualRemoval(token)}}}
}
