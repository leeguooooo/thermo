import ModuleKernelCore
import ModuleKit
import SwiftUI
import ThermoL10n

struct ModuleActivityView:View {
    let manifest:ModuleManifest
    let close:()->Void
    var body:some View {
        let name=BuiltinModules.manifest(manifest.id)==nil ? manifest.name:tr(manifest.name)
        let ids=[manifest.id]+BuiltinNativeFeatures.catalog.privateWorkers(manifest.id).sorted()
        return ModuleActivityPanel(name:name,load:{ModuleKernel.log.summary(modules:ids)},close:close)
    }
}
