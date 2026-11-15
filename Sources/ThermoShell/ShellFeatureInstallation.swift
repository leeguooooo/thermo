import Foundation
import NativeFeatureAPI

/// Metadata is readable from argument parsing; factory invocation never starts a feature.
final class ShellFeatureInstallation:@unchecked Sendable {
    struct Metadata:Sendable {
        let assembly:ShellFeatureAssembly
        let catalog:NativeFeatureCatalog
    }
    static let shared=ShellFeatureInstallation()
    private let lock=NSLock()
    private var factory:(any ShellFeatureFactory)?
    private var installed:Metadata?
    func install(factory:any ShellFeatureFactory) {
        lock.lock();defer{lock.unlock()}
        guard installed==nil else{return}
        let assembly=factory.makeAssembly(environment:{.current})
        let catalog=try! NativeFeatureCatalog(definitions:assembly.definitions)
        self.factory=factory;installed = .init(assembly:assembly,catalog:catalog)
    }
    var metadata:Metadata {
        lock.lock();defer{lock.unlock()}
        guard let installed else{preconditionFailure("Install the application composition before using the shell.")}
        return installed
    }
    func makeAssembly(environment:@escaping @MainActor @Sendable ()->ShellFeatureEnvironment)->ShellFeatureAssembly {
        lock.lock();let factory=self.factory;lock.unlock()
        guard let factory else{preconditionFailure("Install the application composition before creating shell state.")}
        return factory.makeAssembly(environment:environment)
    }
}

enum ShellNativeCatalog {
    static var catalog:NativeFeatureCatalog {ShellFeatureInstallation.shared.metadata.catalog}
    static var registrations:[NativeFeatureDefinition] {ShellFeatureInstallation.shared.metadata.assembly.definitions}
}
