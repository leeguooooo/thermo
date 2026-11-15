import ModuleKit
import SwiftUI
import ThermoUI
import ThermoL10n

/// Settings: what one module has read, deleted, reached and ended through Thermo.
package struct ModuleActivityPanel: View {
    private let name:String
    private let load:@Sendable ()->ModuleAccessLog.Summary
    private let close:()->Void
    package init(name:String,load:@escaping @Sendable ()->ModuleAccessLog.Summary,close:@escaping ()->Void) {self.name=name;self.load=load;self.close=close}
    @State private var summary = ModuleAccessLog.Summary()

    package var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(tr("What %1$@ did through Thermo", name)).font(Theme.heading)
                Spacer()
                Button(tr("Done"), action: close).keyboardShortcut(.defaultAction)
            }
            if summary == ModuleAccessLog.Summary() {
                Text(tr("Nothing yet.")).font(Theme.body).foregroundStyle(Theme.textSecondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
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
            let load=load
            summary = await Task.detached {load()}.value
        }
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
