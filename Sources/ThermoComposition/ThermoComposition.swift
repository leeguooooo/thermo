import ThermoShell

package enum ThermoComposition {
    @MainActor package static func install(){ShellApplication.install(factory:BuiltinFeatureFactory())}
    @MainActor package static func run(){ShellApplication.run(factory:BuiltinFeatureFactory())}
}
