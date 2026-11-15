import SearchControlAPI

@MainActor enum SearchHost {
    static var access:any SearchApplicationAccess {BuiltinNativeFeatures.search.makeAccess(AppModels.shared.nativeFeatures)}
    @discardableResult static func show(settings:Bool = false)->Bool {access.show(settings:settings)}
}
