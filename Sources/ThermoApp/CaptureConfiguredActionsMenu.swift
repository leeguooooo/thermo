import SwiftUI
import CaptureCore
import ThermoL10n

struct CaptureConfiguredActionsMenu:View {
    @ObservedObject var model:CaptureShortcutModel
    var onIssue:()->Void = { CaptureWorkspace.shared.showActionSettings() }
    var body:some View {
        if model.settings.entries.contains(where: { $0.appearsInMenu }) {
            Menu(tr("Configured capture actions")) {
                ForEach(model.settings.entries.filter(\.appearsInMenu)) { entry in
                    let label=model.label(for:entry)
                    Button((entry.title.isEmpty ? tr(entry.action.title) : entry.title)+(label.isEmpty ? "" : "  "+label)) {
                        model.run(entry)
                        if model.issue != nil { onIssue() }
                    }
                }
            }
        }
    }
}
