import Foundation
import SpaceFeature

@MainActor final class SpaceHostServices:SpaceServices {
    private let environment:ShellFeatureEnvironment
    init(environment:ShellFeatureEnvironment? = nil){self.environment=environment ?? .current}
    func protectRemoval(onQuit:@escaping @MainActor ()->Void)->any SpaceRemovalLease {
        HostSpaceRemovalLease(environment.protectRemoval(onQuit:onQuit))
    }
}
@MainActor private final class HostSpaceRemovalLease:SpaceRemovalLease {
    private let protection:any ShellQuitProtection
    init(_ protection:any ShellQuitProtection){self.protection=protection}
    func finish(){protection.finish()}
}
