import ModuleKernelCore
import ModuleHost
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

/// One line of what the feature costs, sampled every few seconds while the page is open.
struct ModuleUsageLine:View {
    @ObservedObject var center:ModuleCenter
    let id:String
    let builtin:Bool
    var body:some View {
        TimelineView(.periodic(from:.now,by:3)){_ in
            Text(Self.text(center.usage(id,builtin:builtin)))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .accessibilityIdentifier("module-center-usage-"+id)
        }
    }
    static func memory(_ bytes:UInt64)->String {ByteCountFormatter.string(fromByteCount:Int64(clamping:bytes),countStyle:.memory)}
    static func text(_ usage:ModuleCenter.Usage)->String {
        switch usage {
        case .off: return tr("Off: uses no memory or energy.")
        case .notRunning: return tr("Not running now: uses no memory or energy.")
        case .shared(let thermo):
            guard let thermo else {return tr("Runs inside Thermo's process; its own memory and energy can't be measured separately.")}
            return tr("Runs inside Thermo's process (Thermo in total: %1$@); its own share can't be measured separately.",memory(thermo.footprintBytes))
        case .process(let usage):
            let cpu=String(format:"%.1f",usage.cpuSeconds)
            guard usage.energyJoules > 0 else {
                return tr("Own process: memory %1$@, CPU %2$@ s since start; energy not reported by the system.",memory(usage.footprintBytes),cpu)
            }
            return tr("Own process: memory %1$@, CPU %2$@ s, energy %3$@ J since start.",memory(usage.footprintBytes),cpu,String(format:"%.1f",usage.energyJoules))
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
    @ObservedObject var center:ModuleCenter
    let id:String
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
                FeatureStopChecklist(center:center,id:id)
            case .processExited:
                Label(tr("Entry points closed"),systemImage:"checkmark")
                Label(tr("Module process exited"),systemImage:"checkmark")
                Text(tr("The module's saved data has not been deleted."))
            }
        }.font(Theme.secondary).foregroundStyle(Theme.textSecondary).frame(maxWidth:.infinity,alignment:.leading)
    }
}

/// What switching a built-in feature off released, and the files it kept, each with a way to move it to the Trash.
struct FeatureStopChecklist:View {
    @ObservedObject var center:ModuleCenter
    let id:String
    @State private var items:[FeatureDataCleanup.Item]?
    @State private var result:FeatureDataCleanup.Result?
    @State private var confirming=false
    var body:some View {
        let footprint=BuiltinModuleFootprints.footprint(id)
        VStack(alignment:.leading,spacing:4){
            if footprint.globalShortcuts {Label(tr("Global shortcuts released"),systemImage:"checkmark")}
            Label(tr(footprint.loginItems ? "Login items removed":"No login items belong to this feature"),systemImage:"checkmark")
            Label(tr("Preferences are kept, so switching it on again restores your setup."),systemImage:"info.circle")
            if let items {
                if items.isEmpty {
                    Label(tr("No saved data left behind."),systemImage:"checkmark")
                } else {
                    Text(tr("Saved data kept on this Mac:"))
                    ForEach(items){item in
                        HStack{
                            Text(tr(item.data.title))
                            Text(ByteCountFormatter.string(fromByteCount:item.bytes,countStyle:.file)).foregroundStyle(Theme.textTertiary)
                            Spacer()
                        }.help(item.path)
                    }
                    if let result,!result.failed.isEmpty {
                        Text(tr("%1$@ items could not be moved to the Trash.",String(result.failed.count))).foregroundStyle(Theme.caution)
                    }
                    Button(tr("Move saved data to Trash…")){confirming=true}
                        .buttonStyle(PillButtonStyle()).controlSize(.small)
                        .disabled(center.isOn(id))
                        .accessibilityIdentifier("module-center-trash-data-"+id)
                }
                if let result,!result.moved.isEmpty {
                    Label(tr("Moved to Trash. Undo it from operation history."),systemImage:"trash")
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id:id){await reload()}
        .confirmationDialog(tr("Move this feature's saved data to the Trash?"),isPresented:$confirming){
            Button(tr("Move to Trash"),role:.destructive){
                guard let items,!center.isOn(id) else{return}
                let id=id
                Task{
                    let done=await Task.detached{FeatureDataCleanup.trash(id,items)}.value
                    result=done;await reload()
                }
            }
            Button(tr("Cancel"),role:.cancel){}
        } message:{
            Text(tr("You can put it back from operation history. The feature starts empty the next time it is switched on."))
        }
    }
    private func reload()async {
        let id=id
        items=await Task.detached{FeatureDataCleanup.present(id)}.value
    }
}
