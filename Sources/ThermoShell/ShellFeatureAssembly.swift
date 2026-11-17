import CaptureControlAPI
import NativeFeatureAPI
import SearchControlAPI
import ToolsControlAPI

package protocol ShellFeatureFactory:Sendable {
    func makeAssembly(environment:@escaping @MainActor @Sendable ()->ShellFeatureEnvironment)->ShellFeatureAssembly
}

/// No concrete feature type crosses into the shell, including its application control bridge.
package struct ShellFeatureAssembly:Sendable {
    package let definitions:[NativeFeatureDefinition]
    package let makeSearchAccess:@MainActor @Sendable (NativeFeatureStore)->any SearchApplicationAccess
    package let makeCaptureControl:@MainActor @Sendable (NativeFeatureStore)->any CaptureApplicationControl
    package let makeTools:@MainActor @Sendable (NativeFeatureStore)->any ToolsApplicationAccess
    package init(definitions:[NativeFeatureDefinition],makeSearchAccess:@escaping @MainActor @Sendable (NativeFeatureStore)->any SearchApplicationAccess,
                 makeCaptureControl:@escaping @MainActor @Sendable (NativeFeatureStore)->any CaptureApplicationControl,
                 makeTools:@escaping @MainActor @Sendable (NativeFeatureStore)->any ToolsApplicationAccess) {
        self.definitions=definitions;self.makeSearchAccess=makeSearchAccess;self.makeCaptureControl=makeCaptureControl;self.makeTools=makeTools
    }
}
