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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("Browser & system privacy")).font(.title2.bold())
            Text(tr("Explicit controls for local settings. Review each action before applying it. No account restriction or anonymity guarantees.")).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(tr("Browser profiles"), systemImage: "globe").font(.headline)
                        Spacer()
                        Button(tr("Scan profiles")) { model.inspect() }
                    }
                    Text(tr("Chrome, Edge, Brave and Firefox standard profiles only. Browsers must be fully closed before changes; Thermo never closes them.")).font(.caption).foregroundStyle(.secondary)
                    if !model.profiles.isEmpty {
                        ForEach(model.profiles) { profile in Text(profile.name).font(.caption).textSelection(.enabled) }
                    }
                    HStack { button(.location); button(.webRTC); button(.cookies) }
                    button(.restoreBrowser)
                    Button(tr("Show private backups")) {
                        let url = model.service.home.appendingPathComponent("Library/Application Support/Thermo/PrivacyBackups")
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    }.font(.caption)
                }.padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label(tr("System settings"), systemImage: "gearshape").font(.headline)
                    HStack {
                        button(.environment); button(.dns)
                        Button(tr("Open Location Services")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(url) }
                        }
                    }
                    Text(tr("System Location Services remain under your control in macOS Settings. DNS proxy enforcement and forced extension installation are not provided.")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text(tr("System timezone")).font(.headline)
                    button(.lookup)
                    if let location = model.location {
                        Text("\(location.country) · \(location.timezone)").textSelection(.enabled)
                        button(.timezone)
                    }
                    HStack {
                        button(.china); button(.restoreTimezone)
                        Button(tr("Open Language & Region")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }
                    Text(tr("Timezone changes do not change country, language or browser locale. Automatic timezone can override manual changes.")).font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            if model.busy { ProgressView().controlSize(.small) }
            if let result = model.result {
                Text(result).font(.callout).textSelection(.enabled).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .disabled(model.busy)
        .alert(item: $pending) { action in
            Alert(title: Text(action.title), message: Text(action.detail), primaryButton: .destructive(Text(tr("Continue"))) { execute(action) }, secondaryButton: .cancel())
        }
    }
    private func button(_ action: Action) -> some View { Button(action.title) { pending = action } }
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
