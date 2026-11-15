import Foundation
import SpaceFeature

@MainActor final class SpaceHostServices:SpaceServices {
    private let environment:ShellFeatureEnvironment
    init(environment:ShellFeatureEnvironment = .current){self.environment=environment}
    func protectRemoval(onQuit:@escaping @MainActor ()->Void)->any SpaceRemovalLease {
        HostSpaceRemovalLease(environment.protectRemoval(onQuit:onQuit))
    }
}
@MainActor private final class HostSpaceRemovalLease:SpaceRemovalLease {
    private let protection:any ShellQuitProtection
    init(_ protection:any ShellQuitProtection){self.protection=protection}
    func finish(){protection.finish()}
}
