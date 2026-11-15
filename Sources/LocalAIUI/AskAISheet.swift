import ThermoUI
import NativeFeatureAPI
import SwiftUI
import AppKit
import CleanKit
import ThermoL10n

/// The 空间透视 context menu opens this for one row.
package struct AskAISheet: View {
    let question: LocalAIQuestion
    var scope: FeatureTasks? = nil
    let close: () -> Void

    package init(question:LocalAIQuestion,scope:FeatureTasks? = nil,close:@escaping ()->Void) {
        self.question=question;self.scope=scope;self.close=close
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                if let p = question.path {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.title).font(Theme.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let p = question.path {
                        Text(FS.tilde(p)).font(Theme.mono).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if let b = question.bytes { Text(ByteFormat.string(b)).font(Theme.figure(.metric)).foregroundStyle(Theme.textPrimary) }
            }
            AskAIPanel(question: question,scope:scope)
            HStack { Spacer(); Button(tr("Done"), action: close).keyboardShortcut(.defaultAction) }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
    }
}

