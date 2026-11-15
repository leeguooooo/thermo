/// Global quit protection is a host capability; the feature owns reviewed removal and UI state.
@MainActor package protocol SpaceServices:AnyObject {
    func protectRemoval(onQuit:@escaping @MainActor ()->Void)->any SpaceRemovalLease
}
@MainActor package protocol SpaceRemovalLease:AnyObject {
    func finish()
}
