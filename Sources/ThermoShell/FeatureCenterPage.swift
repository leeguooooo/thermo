import ModuleKernelCore
import ModuleKit
import SwiftUI
import ThermoL10n
import ThermoUI

struct FeatureCenterPage:View {
    @ObservedObject var center:ModuleCenter
    var body:some View {
        WindowPage(title:tr("Feature Center"),subtitle:tr("Choose what runs in Thermo and review its declared access.")) {
            HStack {
                Text(tr("%1$@ of %2$@ features are on.",String(center.switches.filter{$0.enabled}.count),String(center.switches.count)))
                    .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(tr("All operation history")){MainWindow.show(.native(.init(BuiltinModuleManifests.history.id,"home")))}
                    .buttonStyle(PillButtonStyle())
            }
            Text(tr("Access records cover requests handled by module permissions. Other recorded changes appear in operation history."))
                .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            VStack(spacing:0){ModuleSwitches(center:center)}.glass(radius:Theme.radius)
        }
    }
}

struct ModuleCapabilityDetails:View {
    let manifest:ModuleManifest
    let builtin:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:Theme.Space.s) {
            Text(tr(builtin ? "Built-in features share Thermo's system permissions.":"This isolated module is limited to its declared access."))
                .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            if manifest.capabilities.isEmpty {
                Text(tr("No separate module access is declared.")).font(Theme.secondary).foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(manifest.capabilities.enumerated()),id:\.offset){_,capability in
                HStack(alignment:.top,spacing:Theme.Space.m){
                    VStack(alignment:.leading,spacing:3){
                        Text(ModuleCapabilityText.title(capability.kind)).font(Theme.body)
                        if let scope=capability.scope{Text(scope).font(Theme.mono).textSelection(.enabled).lineLimit(2).truncationMode(.middle)}
                    }
                    Spacer()
                    if capability.kind.alwaysConfirmed{Text(tr("Confirmation required")).font(Theme.caption).foregroundStyle(Theme.caution)}
                }.foregroundStyle(Theme.textSecondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct ModuleStopDetails:View {
    let progress:ModuleCenter.StopProgress
    var body:some View {
        VStack(alignment:.leading,spacing:4){
            switch progress {
            case .waiting:
                Text(tr("Waiting for current work or the module process to finish.")).foregroundStyle(Theme.caution)
            case .refused:
                Text(tr("The feature could not be switched off.")).foregroundStyle(Theme.caution)
            case .nativeFinished:
                Label(tr("Entry points closed"),systemImage:"checkmark")
                Label(tr("Background work finished"),systemImage:"checkmark")
                Text(tr("Saved records and preferences are kept. Recovery controls remain available."))
            case .processExited:
                Label(tr("Entry points closed"),systemImage:"checkmark")
                Label(tr("Module process exited"),systemImage:"checkmark")
                Text(tr("The module's saved data has not been deleted."))
            }
        }.font(Theme.secondary).foregroundStyle(Theme.textSecondary).frame(maxWidth:.infinity,alignment:.leading)
    }
}
