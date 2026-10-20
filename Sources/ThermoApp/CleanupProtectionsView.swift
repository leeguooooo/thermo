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
            HStack(spacing: Theme.Space.s) {
                Label(tr("Protected locations"), systemImage: "shield.checkered").font(Theme.heading)
                InfoButton(text: tr("These rules keep matching locations out of cleanup. Allowing a location does not start cleanup."))
                Spacer()
            }
            if let issue = model.issue { Label(issue, systemImage: "exclamationmark.triangle").font(Theme.secondary).foregroundStyle(Theme.caution).textSelection(.enabled) }
            if let notice = model.notice { NoticeBanner(text: notice) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let review = model.review {
                        if let issue = review.value.removalIssue {
                            Label(issue, systemImage: "exclamationmark.triangle").font(Theme.secondary).foregroundStyle(Theme.caution)
                            Text(tr("Fix invalid rules in the file, then refresh. Cleanup stays blocked until the list is valid."))
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        } else if model.entries.isEmpty {
                            EmptyState(symbol: "shield", title: tr("No protected locations."))
                        }
                        if !model.entries.isEmpty {
                            InspectorPanel {
                                ForEach(Array(model.entries.enumerated()), id: \.element) { i, entry in
                                    if i > 0 { InspectorDivider(inset: Theme.Space.m) }
                                    HStack(spacing: Theme.Space.s) {
                                        Text(FSPath.tilde(entry)).font(Theme.mono).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Button(tr("Allow in next cleanup")) { if model.allow(entry) { changed() } }
                                            .buttonStyle(PillButtonStyle()).controlSize(.small)
                                            .disabled(!model.canChange)
                                            .accessibilityLabel(tr("Allow %1$@ in next cleanup", FSPath.tilde(entry)))
                                    }
                                    .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                                }
                            }
                        }
                        ForEach(review.value.rejected, id: \.line) { row in
                            Text(tr("Line %1$@: %2$@", String(row.line), tr(row.reason)) + "\n" + row.text)
                                .font(Theme.mono).foregroundStyle(Theme.caution).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(tr("Refresh")) { model.reload() }.buttonStyle(PillButtonStyle())
                Button(tr("Open protection file")) { model.openFile() }.buttonStyle(PillButtonStyle())
                Spacer()
                Button(tr("Done"), action: close).keyboardShortcut(.cancelAction).buttonStyle(PillButtonStyle(prominent: true))
            }
        }.padding(Theme.Space.xl).frame(width: 480, height: 460)
            .background(Theme.canvas)
            .preferredColorScheme(.dark)
            .onAppear { model.reload() }
    }
}
