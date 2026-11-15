import SearchControlAPI

@MainActor enum SearchHost {
    static var access:any SearchApplicationAccess {ShellState.shared.assembly.makeSearchAccess(ShellState.shared.nativeFeatures)}
    @discardableResult static func show(settings:Bool = false)->Bool {access.show(settings:settings)}
}
