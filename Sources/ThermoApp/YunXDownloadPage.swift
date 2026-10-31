import CleanKit
import AppKit
import CloudDriveKit
import MediaToolsKit
import SwiftUI
import ThermoL10n
import UniformTypeIdentifiers
import VideoKit
import WebKit

/// Paste a share, video or magnet link; browse it; download. Accounts and backups sit at the bottom.
struct YunXDownloadPage: View {
    @ObservedObject var model: YunXDownloadModel
    @State private var backup: BackupMode?

    enum BackupMode: Identifiable {
        case export, restore(URL)
        var id: String { if case .export = self { return "export" } else { return "import" } }
    }

    var body: some View {
        WindowPage(title: tr("YunX Download"), subtitle: tr("Experimental · not verified with real accounts")) {
            linkPanel
            if let error = model.error { NoticeBanner(text: error, dismiss: { model.error = nil }) }
            if let url = model.pendingP2P { p2pPrompt(url) }
            if model.installingP2P { NoticeBanner(text: tr("Installing the P2P engine…"), busy: true) }
            if model.browsing { browser }
            if let video = model.video { videoPanel(video) }
            if !model.jobs.isEmpty { jobsPanel }
            accountsPanel
        }
        .onAppear { model.reloadAccounts() }
        .sheet(item: $model.login) { target in
            YunXLoginSheet(model: model, target: target)
        }
        .sheet(item: $backup) { mode in
            YunXBackupSheet(model: model, mode: mode)
        }
    }

    private var linkPanel: some View {
        InspectorPanel {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField(tr("Paste a share, video or magnet link"), text: $model.link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.open() } }
                HStack {
                    TextField(tr("Passcode (if any)"), text: $model.passcode)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button(tr("Open")) { Task { await model.open() } }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .disabled(model.busy || model.link.isEmpty)
                }
            }.padding(Theme.Space.m)
        }
    }

    private func p2pPrompt(_ url: String) -> some View {
        InspectorPanel {
            HStack {
                Text(tr("P2P downloads need the Gopeed engine, fetched from its GitHub release (about 30 MB)."))
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(tr("Cancel")) { model.pendingP2P = nil }.buttonStyle(PillButtonStyle())
                Button(tr("Install")) { Task { await model.installP2P() } }.buttonStyle(PillButtonStyle(prominent: true))
            }.padding(Theme.Space.m)
        }
    }

    private var browser: some View {
        InspectorPanel {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: 4) {
                    ForEach(Array(model.path.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.textTertiary) }
                        Button(item.name) { Task { await model.goUp(to: index) } }.buttonStyle(.link).lineLimit(1)
                    }
                    Spacer()
                    Button(tr("Download selected")) { model.downloadSelected() }
                        .buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small).disabled(model.selected.isEmpty)
                }
                if model.files.isEmpty, !model.busy {
                    Text(tr("This folder is empty.")).font(.callout).foregroundStyle(Theme.textSecondary)
                }
                ForEach(model.files, id: \.id) { file in row(file) }
            }.padding(Theme.Space.m)
        }
    }

    private func row(_ file: DriveFile) -> some View {
        HStack {
            if file.isDirectory {
                Image(systemName: "folder").foregroundStyle(Theme.accent).accessibilityHidden(true)
                Button(file.name) { Task { await model.enter(file) } }.buttonStyle(.link).lineLimit(1)
                Spacer()
            } else {
                Toggle(isOn: Binding(get: { model.selected.contains(file.id) }, set: { on in
                    if on { model.selected.insert(file.id) } else { model.selected.remove(file.id) }
                })) { Text(file.name).lineLimit(1) }.toggleStyle(.checkbox)
                Spacer()
                Text(ByteFormat.string(file.size)).font(.caption).foregroundStyle(Theme.textSecondary)
                Button { model.downloadSelected(only: file) } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.plain).help(tr("Download")).accessibilityLabel(tr("Download"))
            }
        }
    }

    private func videoPanel(_ video: VideoParseResult) -> some View {
        InspectorPanel {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(video.title.isEmpty ? video.platform.displayName : video.title).font(.headline).lineLimit(2)
                if !video.author.isEmpty { Text(video.author).font(.caption).foregroundStyle(Theme.textSecondary) }
                if !video.notice.isEmpty { Text(video.notice).font(.caption).foregroundStyle(Theme.textSecondary) }
                if !video.qualities.isEmpty {
                    Picker(tr("Quality"), selection: Binding(get: { video.selectedQn }, set: { qn in Task { await model.selectQuality(qn) } })) {
                        ForEach(video.qualities, id: \.qn) { Text($0.label).tag($0.qn) }
                    }.frame(maxWidth: 240)
                }
                ForEach(Array(video.medias.enumerated()), id: \.offset) { _, media in
                    HStack {
                        Text(YunXDownloadModel.fileName(media, title: video.title)).lineLimit(1)
                        if !media.quality.isEmpty { Text(media.quality).font(.caption).foregroundStyle(Theme.textSecondary) }
                        Spacer()
                        Button(tr("Download")) { model.download(media) }.buttonStyle(PillButtonStyle()).controlSize(.small)
                    }
                }
            }.padding(Theme.Space.m)
        }
    }

    private var jobsPanel: some View {
        InspectorPanel {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text(tr("Downloads")).font(.headline)
                    Spacer()
                    Button(tr("Clear finished")) { model.clearFinished() }.buttonStyle(.link)
                }
                ForEach(model.jobs) { job in jobRow(job) }
            }.padding(Theme.Space.m)
        }
    }

    private func jobRow(_ job: YunXJob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.name).lineLimit(1)
                Spacer()
                switch job.state {
                case .running:
                    if job.canPause { Button(tr("Pause")) { model.pause(job) }.buttonStyle(.link) }
                    Button(tr("Cancel")) { model.cancel(job) }.buttonStyle(.link)
                case .paused:
                    Button(tr("Resume")) { model.resume(job) }.buttonStyle(.link)
                    Button(tr("Cancel")) { model.cancel(job) }.buttonStyle(.link)
                case let .finished(url):
                    Button(tr("Show in Finder")) { model.reveal(url) }.buttonStyle(.link)
                case .failed, .cancelled: EmptyView()
                }
            }
            if job.state.isActive {
                if let total = job.total, total > 0 {
                    ProgressView(value: Double(job.received), total: Double(max(total, job.received)))
                } else { ProgressView().progressViewStyle(.linear) }
            }
            Text(status(job)).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
        }
    }

    private func status(_ job: YunXJob) -> String {
        switch job.state {
        case .running:
            let done = ByteFormat.string(job.received)
            let total = job.total.map { " / " + ByteFormat.string($0) } ?? ""
            return "\(done)\(total) · \(ByteFormat.string(Int64(job.speed)))/s"
        case .paused: return tr("Paused")
        case .finished: return tr("Finished")
        case let .failed(message): return message
        case .cancelled: return tr("Cancelled")
        }
    }

    private var accountsPanel: some View {
        InspectorPanel {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text(tr("Accounts")).font(.headline)
                    Spacer()
                    Button(tr("Import backup…")) { pickBackup() }.buttonStyle(.link)
                    Button(tr("Export backup…")) { backup = .export }.buttonStyle(.link)
                }
                Text(tr("Logins are kept only in the Keychain.")).font(.caption).foregroundStyle(Theme.textSecondary)
                ForEach(DrivePlatform.allCases, id: \.self) { platform in
                    accountRow(.drive(platform), own: true)
                }
                ForEach(VideoPlatform.allCases.filter(\.needsLogin), id: \.self) { platform in
                    accountRow(.video(platform), own: false)
                }
            }.padding(Theme.Space.m)
        }
    }

    private func accountRow(_ target: YunXLoginTarget, own: Bool) -> some View {
        let accounts = model.accounts(for: target.platform)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(target.title)
                Spacer()
                if own, !accounts.isEmpty, case let .drive(platform) = target {
                    Button(tr("Browse")) { Task { await model.browseDrive(platform) } }.buttonStyle(.link)
                }
                Button(tr("Add account")) { model.login = target }.buttonStyle(.link)
            }
            ForEach(accounts) { account in
                HStack {
                    Image(systemName: account.isPrimary ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(account.isPrimary ? Theme.accent : Theme.textTertiary).accessibilityHidden(true)
                    Text(account.nickname.isEmpty ? tr("Unnamed account") : account.nickname).font(.callout)
                    Spacer()
                    if !account.isPrimary { Button(tr("Use")) { model.makePrimary(account) }.buttonStyle(.link) }
                    Button(tr("Remove"), role: .destructive) { model.remove(account) }.buttonStyle(.link)
                }.padding(.leading, Theme.Space.s)
            }
        }
    }

    private func pickBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backup = .restore(url)
    }
}

/// Asks for the backup password, then the place to save it.
struct YunXBackupSheet: View {
    @ObservedObject var model: YunXDownloadModel
    let mode: YunXDownloadPage.BackupMode
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss

    private var isExport: Bool { if case .export = mode { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(isExport ? tr("Export backup") : tr("Import backup")).font(.headline)
            Text(isExport ? tr("The backup is encrypted with this password of at least 8 characters. It cannot be recovered.") : tr("Leave empty if the backup is not encrypted."))
                .font(.callout).foregroundStyle(Theme.textSecondary)
            SecureField(tr("Password"), text: $password).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(tr("Cancel")) { dismiss() }.buttonStyle(PillButtonStyle())
                Button(isExport ? tr("Export…") : tr("Import")) { run() }
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(isExport && password.utf16.count < 8)
            }
        }.padding(Theme.Space.l).frame(width: 380)
    }

    private func run() {
        let secret = password
        switch mode {
        case .export:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = AuthBackupManager.defaultFileName()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task { await model.exportBackup(password: secret, to: url) }
        case let .restore(url):
            Task { await model.importBackup(url, password: secret) }
        }
        dismiss()
    }
}

/// One login. Each sheet gets a throwaway web session, so adding a second account never reuses the first.
struct YunXLoginSheet: View {
    @ObservedObject var model: YunXDownloadModel
    let target: YunXLoginTarget
    @State private var detected: String?
    @State private var pasted = ""
    @State private var account = ""
    @State private var password = ""
    @State private var message: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(tr("Sign in to %1$@", target.title)).font(.headline)
            switch target.method {
            case let .cookie(url, domains, required, anyOf):
                if let address = URL(string: url), !url.isEmpty {
                    YunXLoginWeb(url: address, detected: $detected) { web, done in
                        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                            done(YunXLoginMethod.detect(cookies.map { ($0.domain, $0.name, $0.value) }, domains: domains, required: required, anyOf: anyOf))
                        }
                    }
                }
                pasteField
            case .xunleiWeb:
                YunXLoginWeb(url: URL(string: YunXXunleiWeb.loginURL)!, detected: $detected) { web, done in
                    web.evaluateJavaScript(YunXXunleiWeb.readScript) { value, _ in
                        let raw = (value as? String)?.removingPercentEncoding ?? ""
                        done(raw.isEmpty || XunleiCredential.parseWebLogin(raw) == nil ? nil : raw)
                    }
                }
            case .form:
                TextField(tr("Account"), text: $account).textFieldStyle(.roundedBorder)
                SecureField(tr("Password"), text: $password).textFieldStyle(.roundedBorder)
                if target == .drive(.lanzou) { pasteField }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.red) }
            HStack {
                if detected != nil { Text(tr("Login detected")).font(.callout).foregroundStyle(Theme.textSecondary) }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(tr("Cancel")) { dismiss() }.buttonStyle(PillButtonStyle())
                Button(tr("Save login")) { save() }.buttonStyle(PillButtonStyle(prominent: true)).disabled(saving || !canSave)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: target.method == .form ? 380 : 760, height: target.method == .form ? nil : 620)
    }

    private var pasteField: some View {
        SecureField(tr("Or paste the Cookie"), text: $pasted).textFieldStyle(.roundedBorder)
    }

    private var canSave: Bool {
        if detected != nil || !pasted.isEmpty { return true }
        return target.method == .form && !account.isEmpty && !password.isEmpty
    }

    private func save() {
        saving = true
        message = nil
        Task {
            defer { saving = false }
            do {
                if let secret = pasted.isEmpty ? detected : pasted {
                    try await model.saveLogin(target, secret: secret)
                } else if case let .drive(platform) = target {
                    try await model.formLogin(platform, account: account, password: password)
                }
                dismiss()
            } catch { message = error.localizedDescription }
        }
    }
}

/// The site's own login page in a non-persistent store. `probe` runs on a timer until it finds a login.
struct YunXLoginWeb: NSViewRepresentable {
    typealias Probe = (WKWebView, @escaping (String?) -> Void) -> Void
    let url: URL
    @Binding var detected: String?
    let probe: Probe

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.load(URLRequest(url: url))
        context.coordinator.begin(web, probe: probe) { detected = $0 }
        return web
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.timer?.invalidate() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var timer: Timer?
        @MainActor func begin(_ web: WKWebView, probe: @escaping Probe, found: @escaping (String?) -> Void) {
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak web] _ in
                MainActor.assumeIsolated {
                    guard let web else { return }
                    probe(web) { value in found(value) }
                }
            }
        }
    }
}
