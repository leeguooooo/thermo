@testable import SpaceFeature

@MainActor final class FixtureSpaceServices:SpaceServices {
    private final class Lease:SpaceRemovalLease {func finish(){}}
    func protectRemoval(onQuit:@escaping @MainActor ()->Void)->any SpaceRemovalLease {Lease()}
}
