import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

final class CleanupProtectionsModel: ObservableObject {
    let home: String
    @Published private(set) var review: Whitelist.ProtectionReview?
    @Published private(set) var issue: String?
    @Published private(set) var notice: String?
    init(home: String = NSHomeDirectory()) { self.home = home }
    var entries: [String] { review?.value.entries ?? [] }
    var canChange: Bool { review != nil && issue == nil && review?.value.rejected.isEmpty == true }
    func reload() {
        review = nil; issue = nil; notice = nil
        do { review = try Whitelist.review(home: home) }
        catch { issue = error.localizedDescription }
    }
    @discardableResult func allow(_ entry: String) -> Bool {
        guard canChange, let review else { return false }
        notice = nil
        do {
            try Whitelist.removeReviewed(entry, review: review)
            reload()
            notice = tr("This rule no longer protects files. Scan again before cleaning; other rules and safety checks still apply.")
            return true
        } catch { issue = error.localizedDescription; return false }
    }
    func openFile() { NSWorkspace.shared.open(Whitelist.url(home: home)) }
}

struct CleanupProtectionsButton: View {
    @ObservedObject var disk: DiskModel
    var compact = false
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            if compact { Image(systemName: "shield.checkered") }
            else { Label(tr("Protected locations"), systemImage: "shield.checkered") }
        }
        .buttonStyle(PillButtonStyle()).help(tr("Protected locations"))
        .accessibilityLabel(tr("Protected locations"))
        .disabled(disk.cleaning || disk.scanning)
        .sheet(isPresented: $showing) {
            CleanupProtectionsView(changed: { disk.protectionRulesChanged() }, close: { showing = false })
        }
    }
}

struct CleanupProtectionsView: View {
    @StateObject private var model: CleanupProtectionsModel
    let changed: () -> Void
    let close: () -> Void
    init(home: String = NSHomeDirectory(), changed: @escaping () -> Void, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: CleanupProtectionsModel(home: home)); self.changed = changed; self.close = close
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(tr("Protected locations"), systemImage: "shield.checkered").font(.title2.weight(.semibold))
            Text(tr("These rules keep matching locations out of cleanup. Allowing a location does not start cleanup."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let issue = model.issue { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
            if let notice = model.notice { Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let review = model.review {
                        if let issue = review.value.removalIssue {
                            Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text(tr("Fix invalid rules in the file, then refresh. Cleanup stays blocked until the list is valid."))
                                .font(.caption).foregroundStyle(.secondary)
                        } else if model.entries.isEmpty {
                            Text(tr("No protected locations.")).foregroundStyle(.secondary)
                        }
                        ForEach(model.entries, id: \.self) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(FSPath.tilde(entry)).font(.caption.monospaced()).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button(tr("Allow in next cleanup")) { if model.allow(entry) { changed() } }
                                    .disabled(!model.canChange)
                                    .accessibilityLabel(tr("Allow %1$@ in next cleanup", FSPath.tilde(entry)))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).glass(radius: 10)
                        }
                        ForEach(review.value.rejected, id: \.line) { row in
                            Text(tr("Line %1$@: %2$@", String(row.line), tr(row.reason)) + "\n" + row.text)
                                .font(.caption.monospaced()).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(tr("Refresh")) { model.reload() }
                Button(tr("Open protection file")) { model.openFile() }
                Spacer()
                Button(tr("Done"), action: close).keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 480, height: 460)
            .onAppear { model.reload() }
    }
}
