import SwiftUI
import ThermoL10n

/// ImageRenderer cannot draw AppKit-backed scroll views.
package var renderingPreview=false

/// The same confirmation layout for actions that are not an AgentDoctor `Action` (e.g. disk cleanup):
/// a title, a summary, the exact lines that will run, and a note on how it can be undone.
package struct ConfirmSheet: View {
    let title: String
    let summary: String
    let destructive: Bool
    let heading: String
    let lines: [String]
    var retainedLines: [String] = []
    var detailLines: [String] = []
    let footnote: String
    let confirmTitle: String
    var confirmEnabled = true
    /// An optional control shown above the footnote, such as a removal option.
    var accessory: AnyView? = nil
    let confirm: () -> Void
    let cancel: () -> Void

    package init(title:String,summary:String,destructive:Bool,heading:String,lines:[String],retainedLines:[String] = [],detailLines:[String] = [],footnote:String,confirmTitle:String,confirmEnabled:Bool = true,accessory:AnyView? = nil,confirm:@escaping ()->Void,cancel:@escaping ()->Void) {
        self.title=title;self.summary=summary;self.destructive=destructive;self.heading=heading;self.lines=lines
        self.retainedLines=retainedLines;self.detailLines=detailLines;self.footnote=footnote;self.confirmTitle=confirmTitle
        self.confirmEnabled=confirmEnabled;self.accessory=accessory;self.confirm=confirm;self.cancel=cancel
    }

    func list(_ values: [String]) -> some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, l in
                Text(l).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    var reviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.subheadline.weight(.semibold))
            if lines.isEmpty { Text(tr("No items selected")).font(.caption).foregroundStyle(.secondary) }
            else { list(lines) }
            if !retainedLines.isEmpty {
                Text(tr("Kept in place")).font(.subheadline.weight(.semibold))
                list(retainedLines)
            }
            if !detailLines.isEmpty {
                Text(tr("Details")).font(.subheadline.weight(.semibold))
                list(detailLines)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: destructive ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(destructive ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            // ImageRenderer cannot draw scroll views; previews get the plain list.
            if renderingPreview { reviewContent } else { ScrollView { reviewContent }.frame(maxHeight: 220) }
            if let accessory { accessory }
            Text(footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(role: destructive ? .destructive : nil, action: confirm) { Text(confirmTitle) }
                    .disabled(!confirmEnabled)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        // Set the presentation's native appearance too: a dark SwiftUI environment alone
        // can leave the sheet background light while its labels and Cancel button are white.
        .preferredColorScheme(.dark)
    }
}

