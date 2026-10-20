import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

@MainActor
final class PrivacyToolsModel: ObservableObject {
    @Published var busy = false
    @Published var result: String?
    @Published var profiles: [PrivacyBrowserProfile] = []
    @Published var location: PrivacyExitLocation?
    let service = PrivacyToolsService()

    func perform(_ action: @escaping @Sendable (PrivacyToolsService) throws -> String) {
        guard !busy else { return }; busy = true
        let service = service
        Task.detached(priority: .userInitiated) {
            let result: String
            do { result = try action(service) } catch { result = error.localizedDescription }
            await MainActor.run { self.result = result; self.busy = false }
        }
    }
    func inspect() {
        guard !busy else { return }; busy = true
        let service = service
        Task.detached {
            do {
                let profiles = try service.discoverProfiles()
                await MainActor.run { self.profiles = profiles; self.result = tr("Browser profile scan completed."); self.busy = false }
            } catch { await MainActor.run { self.result = error.localizedDescription; self.busy = false } }
        }
    }
    func lookup() {
        guard !busy else { return }; busy = true; location = nil
        let service = service
        Task {
            do { location = try await service.lookupExitLocation(); result = tr("Exit location detected. Review the timezone before applying it.") }
            catch { result = error.localizedDescription }
            busy = false
        }
    }
}

@MainActor
struct PrivacyToolsView: View {
    @ObservedObject var model: PrivacyToolsModel
    @State private var pending: Action?
    init(model: PrivacyToolsModel) { self.model = model }

    private enum Action: String, Identifiable {
        case location, webRTC, cookies, restoreBrowser, environment, dns, lookup, timezone, china, restoreTimezone
        var id: String { rawValue }
        var title: String {
            switch self {
            case .location: return tr("Block default browser location")
            case .webRTC: return tr("Restrict WebRTC")
            case .cookies: return tr("Clear mail.com cookies")
            case .restoreBrowser: return tr("Restore last browser change")
            case .environment: return tr("Remove Claude launchd variables")
            case .dns: return tr("Flush DNS cache")
            case .lookup: return tr("Look up exit region")
            case .timezone: return tr("Apply detected timezone")
            case .china: return tr("Set Beijing timezone")
            case .restoreTimezone: return tr("Restore previous timezone")
            }
        }
        var detail: String {
            switch self {
            case .location: return tr("Quit Chrome, Edge, Brave and Firefox first. Sets the default location permission to blocked; existing per-site grants may override it. Firefox location is disabled. Settings are backed up. Restart browsers afterward.")
            case .webRTC: return tr("Quit Chrome, Edge, Brave and Firefox first. Restricts non-proxied UDP in Chromium and disables WebRTC in Firefox. Calls and meetings may stop working. Settings are backed up. Restart browsers afterward.")
            case .cookies: return tr("Quit supported browsers first. Deletes only mail.com and its subdomain cookies, signing you out there. SQLite backups contain sensitive login data and are retained privately. Cookie restore requires manual recovery while browsers are closed.")
            case .restoreBrowser: return tr("Quit supported browsers first. Restores the latest settings backup only if the files still match Thermo's changes. Newer external edits prevent automatic restore. Cookie backups are separate.")
            case .environment: return tr("Removes only named Claude and Anthropic variables from your user launchd environment. Values are never read or backed up, so this cannot be undone. Shell startup files, current processes, AWS, Google Cloud and proxy variables are unchanged. Restart apps afterward.")
            case .dns: return tr("macOS will request administrator approval to clear cached DNS answers. DNS servers, firewall rules and proxy configuration are unchanged.")
            case .lookup: return tr("Contacts ipwho.is over HTTPS to estimate this app's exit country and timezone. The service receives your public IP. Browser-only proxies may use a different exit. This lookup does not change settings.")
            case .timezone, .china: return tr("macOS will request administrator approval. Saves the previous system timezone before changing it. Automatic timezone settings may override this change. Country, region and display language are unchanged.")
            case .restoreTimezone: return tr("macOS will request administrator approval to restore the timezone saved before Thermo's first change. Country, region and language are unchanged.")
            }
        }
        var symbol: String {
            switch self {
            case .location: return "location.slash"
            case .webRTC: return "video.slash"
            case .cookies: return "envelope.badge"
            case .restoreBrowser: return "arrow.uturn.backward"
            case .environment: return "terminal"
            case .dns: return "network"
            case .lookup: return "mappin.and.ellipse"
            case .timezone: return "clock.badge.checkmark"
            case .china: return "clock"
            case .restoreTimezone: return "clock.arrow.circlepath"
            }
        }
        /// One line on the row; the full `detail` is shown before anything runs.
        var summary: String {
            switch self {
            case .location: return tr("Sets the default location permission to blocked. Existing site grants may override it.")
            case .webRTC: return tr("Limits non-proxied WebRTC traffic. Calls and meetings may stop working.")
            case .cookies: return tr("Deletes only mail.com cookies and signs you out there.")
            case .restoreBrowser: return tr("Restores the latest settings backup if the files still match Thermo's changes.")
            case .environment: return tr("Removes named Claude and Anthropic variables from the user launchd environment.")
            case .dns: return tr("Clears cached DNS answers. DNS servers and proxies are unchanged.")
            case .lookup: return tr("Asks ipwho.is for this app's exit country and timezone. Changes nothing.")
            case .timezone: return tr("Sets the system timezone to the detected one.")
            case .china: return tr("Sets the system timezone to Asia/Shanghai.")
            case .restoreTimezone: return tr("Restores the timezone saved before Thermo's first change.")
            }
        }
        var tags: [(String, Bool)] {
            switch self {
            case .location, .webRTC: return [(tr("Quit browsers first"), false), (tr("Backed up"), false)]
            case .cookies: return [(tr("Quit browsers first"), false), (tr("Signs you out"), true)]
            case .restoreBrowser: return [(tr("Quit browsers first"), false)]
            case .environment: return [(tr("Cannot be undone"), true)]
            case .dns: return [(tr("Administrator approval"), false)]
            case .lookup: return [(tr("Sends your public IP"), false)]
            case .timezone, .china: return [(tr("Administrator approval"), false), (tr("Previous timezone saved"), false)]
            case .restoreTimezone: return [(tr("Administrator approval"), false)]
            }
        }
        var verb: String {
            switch self {
            case .restoreBrowser, .restoreTimezone: return tr("Restore…")
            case .environment: return tr("Remove…")
            case .dns: return tr("Flush…")
            case .lookup: return tr("Look up…")
            default: return tr("Apply…")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: "hand.raised").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                Text(tr("Explicit controls for local settings. Review each action before applying it. No account restriction or anonymity guarantees."))
                    .font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 2)
            if model.busy || model.result != nil {
                NoticeBanner(text: model.busy ? tr("Working…") : model.result ?? "", busy: model.busy,
                             dismiss: model.busy ? nil : { model.result = nil })
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader(title: tr("Browser profiles")) {
                    HStack(spacing: Theme.Space.s) {
                        InfoButton(text: tr("Chrome, Edge, Brave and Firefox standard profiles only. Browsers must be fully closed before changes; Thermo never closes them."))
                        Button(tr("Scan profiles")) { model.inspect() }.buttonStyle(PillButtonStyle()).controlSize(.small)
                    }
                }
                InspectorPanel {
                    if !model.profiles.isEmpty {
                        HStack(alignment: .top, spacing: Theme.Space.m) {
                            Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                                .frame(width: 18).padding(.top, 1).accessibilityHidden(true)
                            FlowChips(items: model.profiles.map(\.name))
                        }.padding(.horizontal, 14).padding(.vertical, Theme.Space.m)
                        InspectorDivider()
                    }
                    row(.location); InspectorDivider()
                    row(.webRTC); InspectorDivider()
                    row(.cookies); InspectorDivider()
                    row(.restoreBrowser); InspectorDivider()
                    linkRow("lock.doc", tr("Show private backups")) {
                        let url = model.service.home.appendingPathComponent("Library/Application Support/Thermo/PrivacyBackups")
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader(title: tr("System settings")) {
                    InfoButton(text: tr("System Location Services remain under your control in macOS Settings. DNS proxy enforcement and forced extension installation are not provided."))
                }
                InspectorPanel {
                    row(.environment); InspectorDivider()
                    row(.dns); InspectorDivider()
                    linkRow("location", tr("Open Location Services")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader(title: tr("System timezone")) {
                    InfoButton(text: tr("Timezone changes do not change country, language or browser locale. Automatic timezone can override manual changes."))
                }
                InspectorPanel {
                    row(.lookup)
                    if let location = model.location {
                        InspectorDivider()
                        row(.timezone, detected: "\(location.country) · \(location.timezone)")
                    }
                    InspectorDivider()
                    row(.china); InspectorDivider()
                    row(.restoreTimezone); InspectorDivider()
                    linkRow("globe.asia.australia", tr("Open Language & Region")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
        .disabled(model.busy)
        .alert(item: $pending) { action in
            Alert(title: Text(action.title), message: Text(action.detail), primaryButton: .destructive(Text(tr("Continue"))) { execute(action) }, secondaryButton: .cancel())
        }
    }

    private func row(_ action: Action, detected: String? = nil) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: action.symbol).font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                .frame(width: 18).frame(maxHeight: .infinity, alignment: .top).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.s) {
                    Text(action.title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                    ForEach(action.tags, id: \.0) { tag in RequirementTag(text: tag.0, warning: tag.1) }
                }
                if let detected {
                    Text(detected).font(Theme.mono).foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
                Text(action.summary).font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            Button(action.verb) { pending = action }
                .buttonStyle(PillButtonStyle()).controlSize(.small)
                .fixedSize()
                .accessibilityLabel(action.title)
                .accessibilityHint(action.summary)
        }
        .padding(.horizontal, 14).padding(.vertical, Theme.Space.m)
        .hoverHighlight()
    }

    private func linkRow(_ symbol: String, _ title: String, _ open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.textTertiary).frame(width: 18)
                    .accessibilityHidden(true)
                Text(title).font(Theme.body).foregroundStyle(Theme.accent)
                Spacer()
                Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, Theme.Space.s + 2).contentShape(Rectangle())
            .hoverHighlight()
        }.buttonStyle(.plain)
    }

    private func execute(_ action: Action) {
        switch action {
        case .location: model.perform { try $0.applyBrowser(.location) }
        case .webRTC: model.perform { try $0.applyBrowser(.webRTC) }
        case .cookies: model.perform { try $0.clearMailCookies() }
        case .restoreBrowser: model.perform { try $0.restoreLatestBrowserChange() }
        case .environment: model.perform { try $0.clearClaudeEnvironment() }
        case .dns: model.perform { try $0.flushDNS() }
        case .lookup: model.lookup()
        case .timezone:
            if let timezone = model.location?.timezone { model.perform { try $0.setTimezone(timezone) } }
        case .china: model.perform { try $0.setTimezone("Asia/Shanghai") }
        case .restoreTimezone: model.perform { try $0.restoreTimezone() }
        }
    }
}

/// Capsules that wrap onto new lines when the row is narrow.
struct FlowChips: View {
    let items: [String]
    var warnings: Set<String> = []
    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(items, id: \.self) { RequirementTag(text: $0, warning: warnings.contains($0)) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
