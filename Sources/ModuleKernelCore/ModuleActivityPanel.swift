import ModuleKit
import SwiftUI
import ThermoUI
import ThermoL10n

/// Settings: what one module has read, deleted, reached and ended through Thermo.
package struct ModuleActivityPanel: View {
    private let name:String
    private let load:@Sendable ()->ModuleAccessLog.Summary
    private let loadRecent:@Sendable ()->[ModuleAccessRecord]
    private let close:()->Void
    package init(name:String,load:@escaping @Sendable ()->ModuleAccessLog.Summary,recent:@escaping @Sendable ()->[ModuleAccessRecord] = {[]},close:@escaping ()->Void) {self.name=name;self.load=load;self.loadRecent=recent;self.close=close}
    @State private var summary = ModuleAccessLog.Summary()
    @State private var recent:[ModuleAccessRecord]=[]
    @State private var loading=true

    package var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(tr("What %1$@ did through Thermo", name)).font(Theme.heading)
                Spacer()
                Button(tr("Done"), action: close).keyboardShortcut(.defaultAction)
            }
            if loading {ProgressView(tr("Loading access records…"))}
            else if summary == ModuleAccessLog.Summary() && recent.isEmpty {
                Text(tr("Nothing yet.")).font(Theme.body).foregroundStyle(Theme.textSecondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if !recent.isEmpty {
                        Text(tr("Recent requests")).font(Theme.label).foregroundStyle(Theme.textTertiary)
                        ForEach(Array(recent.enumerated()),id:\.offset){_,record in
                            VStack(alignment:.leading,spacing:4){
                                HStack {
                                    Text(Capability.Kind(rawValue:record.capability).map(ModuleCapabilityText.title) ?? record.capability).font(Theme.body)
                                    Spacer()
                                    Text(record.time,style:.time).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                    Text(outcome(record.outcome)).font(Theme.caption).foregroundStyle(record.outcome == .allowed ? Theme.good:Theme.caution)
                                }
                                if let target=record.targets.first {Text(target).font(Theme.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)}
                                if record.targetCount>1{Text(tr("%1$@ targets in this request",String(record.targetCount))).font(Theme.caption).foregroundStyle(Theme.textTertiary)}
                                if let detail=record.detail,!detail.isEmpty {Text(detail).font(Theme.secondary).foregroundStyle(Theme.textSecondary).lineLimit(2)}
                            }
                        }
                    }
                    group(tr("Files read"), summary.read)
                    group(tr("Moved to the Trash"), summary.deleted)
                    group(tr("Connected to"), summary.hosts)
                    group(tr("Ended"), summary.ended)
                    if summary.denied + summary.declined + summary.failed > 0 {
                        Text(tr("%1$@ requests were refused, %2$@ were not confirmed and %3$@ failed.",
                                String(summary.denied), String(summary.declined), String(summary.failed)))
                            .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24).frame(width: 560, height: 440).foregroundStyle(Theme.textPrimary).background(Theme.canvas).preferredColorScheme(.dark)
        .task {
            let load=load,loadRecent=loadRecent
            let values=await Task.detached{(load(),loadRecent())}.value
            guard !Task.isCancelled else{return}
            summary=values.0;recent=values.1;loading=false
        }
    }

    private func outcome(_ value:ModuleAccessRecord.Outcome)->String {
        switch value {case .allowed:return tr("Done");case .denied:return tr("Refused");case .declined:return tr("Not confirmed");case .failed:return tr("failed")}
    }

    @ViewBuilder func group(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.label).foregroundStyle(Theme.textTertiary)
                ForEach(items.suffix(200), id: \.self) { item in
                    Text(item).font(Theme.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
    }
}
