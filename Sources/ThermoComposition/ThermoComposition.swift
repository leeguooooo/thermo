import AppKit
import ModuleDevTesting
import ThermoShell

package enum ThermoComposition {
    @MainActor package static func install(){ShellApplication.install(factory:BuiltinFeatureFactory())}
    @MainActor package static func run(){
        // `thermo dev test` runs module fixtures with the app's own renderer: `Thermo --module-test FOLDER`.
        // It never starts the app: no menu bar item, no window, no second instance.
        let arguments=Array(CommandLine.arguments.dropFirst())
        if arguments.first == ModuleTestCommand.flag {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task{@MainActor in exit(await ModuleTestCommand.run(Array(arguments.dropFirst())))}
            RunLoop.main.run()
        }
        ShellApplication.run(factory:BuiltinFeatureFactory())
    }
}
