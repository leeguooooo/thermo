import CleanKit
import AVKit
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
            if let notice = model.notice { NoticeBanner(text: notice, dismiss: { model.notice = nil }) }
            if let url = model.pendingP2P { p2pPrompt(url) }
            if model.installingP2P { NoticeBanner(text: tr("Installing the P2P engine…"), busy: true) }
            if model.pendingFfmpeg != nil { ffmpegPrompt }
            if model.installingFfmpeg { NoticeBanner(text: tr("Installing FFmpeg…"), busy: true) }
            if model.browsing { browser }
            if let video = model.video { videoPanel(video) }
            if !model.jobs.isEmpty { jobsPanel }
            settingsPanel
            accountsPanel
        }
        .onAppear {
            model.reloadAccounts()
            model.restoreJobs()
            model.startBackgroundRefresh()
        }
        .sheet(item: $model.login) { target in
            YunXLoginSheet(model: model, target: target)
        }
        .sheet(item: $backup) { mode in
            YunXBackupSheet(model: model, mode: mode)
        }
        .sheet(item: Binding(get: { model.preview }, set: { if $0 == nil { model.closePreview() } })) { preview in
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text(preview.title).font(.headline).lineLimit(1)
                    Spacer()
                    Button(tr("Close")) { model.closePreview() }.buttonStyle(PillButtonStyle())
                }
                VideoPlayer(player: preview.player).onAppear { preview.player.play() }
            }.padding(Theme.Space.m).frame(width: 760, height: 500)
        }
        .sheet(isPresented: Binding(get: { model.savePicker != nil }, set: { if !$0 { model.savePicker = nil } })) {
            YunXSavePickerSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.torrentPick != nil }, set: { if !$0 { model.torrentPick = nil } })) {
            YunXTorrentSheet(model: model)
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
                    Button(tr("Open .torrent…")) { pickTorrent() }.buttonStyle(PillButtonStyle())
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
                Text(tr("P2P downloads need the Gopeed engine, fetched from its GitHub release."))
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(tr("Cancel")) { model.pendingP2P = nil }.buttonStyle(PillButtonStyle())
                Button(tr("Install")) { Task { await model.installP2P() } }.buttonStyle(PillButtonStyle(prominent: true))
            }.padding(Theme.Space.m)
        }
    }

    private var ffmpegPrompt: some View {
        InspectorPanel {
            HStack {
                Text(tr("Merging video and audio works best with FFmpeg, fetched from martin-riedl.de."))
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(tr("Use built-in")) { model.declineFfmpeg() }.buttonStyle(PillButtonStyle())
                Button(tr("Install")) { Task { await model.installFfmpeg() } }.buttonStyle(PillButtonStyle(prominent: true))
            }.padding(Theme.Space.m)
        }
    }

    private func pickTorrent() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.openTorrent(url) }
    }

    private var settingsPanel: some View {
        InspectorPanel {
            DisclosureGroup(tr("Download settings")) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack {
                        Text(tr("Save to")).font(.callout)
                        Text(model.saveDirectoryLabel).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if !model.settings.saveDirectory.isEmpty {
                            Button(tr("Use Downloads")) { model.settings.saveDirectory = "" }.buttonStyle(.link)
                        }
                        Button(tr("Choose…")) { pickFolder() }.buttonStyle(.link)
                    }
                    number(tr("Speed limit (KB/s, 0 is unlimited)"), $model.settings.speedLimitKB)
                    Text(tr("The limit covers HTTP downloads, not P2P.")).font(.caption).foregroundStyle(Theme.textSecondary)
                    number(tr("P2P connections"), $model.settings.p2pConnections)
                    number(tr("P2P tasks at once"), $model.settings.p2pMaxRunning)
                    Toggle(tr("DHT"), isOn: $model.settings.p2pDHT).toggleStyle(.checkbox)
                    Picker(tr("P2P proxy"), selection: $model.settings.proxyMode) {
                        Text(tr("Direct")).tag(YunXSettings.ProxyMode.direct)
                        Text(tr("System")).tag(YunXSettings.ProxyMode.system)
                        Text(tr("Manual")).tag(YunXSettings.ProxyMode.manual)
                    }.frame(maxWidth: 260)
                    if model.settings.proxyMode == .manual {
                        HStack {
                            TextField(tr("Proxy host"), text: $model.settings.proxyHost).textFieldStyle(.roundedBorder)
                            number(tr("Port"), $model.settings.proxyPort)
                        }
                    }
                    Text(tr("Extra trackers, one per line")).font(.callout)
                    TextEditor(text: Binding(get: { model.settings.trackers.joined(separator: "\n") }, set: { text in
                        model.settings.trackers = text.components(separatedBy: "\n")
                    })).font(.caption).frame(height: 56).border(Theme.textTertiary.opacity(0.3))
                }.padding(.top, Theme.Space.xs)
            }.padding(Theme.Space.m)
        }
    }

    private func number(_ title: String, _ value: Binding<Int>) -> some View {
        HStack {
            Text(title).font(.callout)
            TextField("", value: value, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 90)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.saveDirectory = url.path
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
                    if model.canSaveToDrive {
                        Button(tr("Save to drive")) { Task { await model.beginSave() } }
                            .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.selected.isEmpty)
                    }
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
                Toggle("", isOn: ticked(file)).toggleStyle(.checkbox).labelsHidden().accessibilityLabel(file.name)
                Image(systemName: "folder").foregroundStyle(Theme.accent).accessibilityHidden(true)
                Button(file.name) { Task { await model.enter(file) } }.buttonStyle(.link).lineLimit(1)
                Spacer()
                Button { model.downloadSelected(only: file) } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.plain).help(tr("Download")).accessibilityLabel(tr("Download"))
            } else {
                Toggle(isOn: ticked(file)) { Text(file.name).lineLimit(1) }.toggleStyle(.checkbox)
                Spacer()
                Text(ByteFormat.string(file.size)).font(.caption).foregroundStyle(Theme.textSecondary)
                if model.previewable(file) {
                    Button { Task { await model.preview(file) } } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.plain).help(tr("Preview")).accessibilityLabel(tr("Preview"))
                }
                Button { model.downloadSelected(only: file) } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.plain).help(tr("Download")).accessibilityLabel(tr("Download"))
            }
        }
    }

    private func ticked(_ file: DriveFile) -> Binding<Bool> {
        Binding(get: { model.selected.contains(file.id) }, set: { on in
            if on { model.selected.insert(file.id) } else { model.selected.remove(file.id) }
        })
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
                        if model.previewable(media) {
                            Button(tr("Preview")) { Task { await model.preview(media) } }.buttonStyle(PillButtonStyle()).controlSize(.small)
                        }
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
                ForEach(model.jobGroups) { group in
                    if group.isFolder {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(Theme.accent).accessibilityHidden(true)
                            Text(group.title).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text(tr("%1$@ files", String(group.jobs.count))).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    ForEach(group.jobs) { job in jobRow(job).padding(.leading, group.isFolder ? Theme.Space.s : 0) }
                }
            }.padding(Theme.Space.m)
        }
    }

    private func jobRow(_ job: YunXJob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.name).lineLimit(1)
                Spacer()
                switch job.state {
                case .queued:
                    Button(tr("Cancel")) { model.cancel(job) }.buttonStyle(.link)
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
        case .queued: return tr("Queued")
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

/// Picks the folder in the account that a share is saved into.
struct YunXSavePickerSheet: View {
    @ObservedObject var model: YunXDownloadModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(tr("Save to drive")).font(.headline)
            if let picker = model.savePicker {
                HStack(spacing: 4) {
                    ForEach(Array(picker.trail.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.textTertiary) }
                        Button(item.name) { Task { await model.pickerUp(to: index) } }.buttonStyle(.link).lineLimit(1)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(picker.folders, id: \.id) { folder in
                            Button(folder.name) { Task { await model.pickerEnter(folder) } }.buttonStyle(.link).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 220)
            }
            HStack {
                Spacer()
                Button(tr("Cancel")) { model.savePicker = nil; dismiss() }.buttonStyle(PillButtonStyle())
                Button(tr("Save here")) { Task { await model.confirmSave() } }.buttonStyle(PillButtonStyle(prominent: true))
            }
        }.padding(Theme.Space.l).frame(width: 420)
    }
}

/// Which files of a torrent to fetch.
struct YunXTorrentSheet: View {
    @ObservedObject var model: YunXDownloadModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(model.torrentPick?.name ?? "").font(.headline).lineLimit(2)
            if let pick = model.torrentPick {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(pick.files.enumerated()), id: \.offset) { index, file in
                            Toggle(isOn: Binding(get: { model.torrentPick?.selected.contains(index) == true }, set: { on in
                                if on { model.torrentPick?.selected.insert(index) } else { model.torrentPick?.selected.remove(index) }
                            })) {
                                HStack {
                                    Text(file.displayPath).lineLimit(1)
                                    Spacer()
                                    Text(ByteFormat.string(file.size)).font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }
                }.frame(height: 280)
            }
            HStack {
                Spacer()
                Button(tr("Cancel")) { model.torrentPick = nil }.buttonStyle(PillButtonStyle())
                Button(tr("Download selected")) { model.confirmTorrent() }
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(model.torrentPick?.selected.isEmpty != false)
            }
        }.padding(Theme.Space.l).frame(width: 520)
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
    enum Mode: Hashable { case web, password, sms }
    @State private var mode: Mode?
    @State private var code = ""
    @State private var challenge: YunXSmsChallenge?
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
            if modes.count > 1 {
                Picker("", selection: Binding(get: { current }, set: { mode = $0; challenge = nil; message = nil })) {
                    ForEach(modes, id: \.self) { Text(title($0)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            switch current {
            case .password:
                TextField(tr("Account"), text: $account).textFieldStyle(.roundedBorder)
                SecureField(tr("Password"), text: $password).textFieldStyle(.roundedBorder)
                if target == .drive(.lanzou) { pasteField }
            case .sms:
                TextField(tr("Phone number"), text: $account).textFieldStyle(.roundedBorder)
                HStack {
                    TextField(tr("Verification code"), text: $code).textFieldStyle(.roundedBorder)
                    Button(challenge == nil ? tr("Send code") : tr("Send again")) { sendCode() }
                        .buttonStyle(PillButtonStyle()).disabled(saving || account.isEmpty)
                }
            case .web:
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
                default:
                    YunXLoginWeb(url: URL(string: YunXXunleiWeb.loginURL)!, detected: $detected) { web, done in
                        web.evaluateJavaScript(YunXXunleiWeb.readScript) { value, _ in
                            let raw = (value as? String)?.removingPercentEncoding ?? ""
                            done(raw.isEmpty || XunleiCredential.parseWebLogin(raw) == nil ? nil : raw)
                        }
                    }
                    SecureField(tr("Or paste the Cookie or token"), text: $pasted).textFieldStyle(.roundedBorder)
                }
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
        .frame(width: current == .web ? 760 : 380, height: current == .web ? 620 : nil)
    }

    private var modes: [Mode] {
        switch target {
        case .drive(.xunlei): return [.web, .password, .sms]
        case .drive(.guangya): return [.password, .sms]
        default: return [target.method == .form ? .password : .web]
        }
    }

    private var current: Mode { mode ?? modes[0] }

    private func title(_ mode: Mode) -> String {
        switch mode {
        case .web: return tr("Web")
        case .password: return tr("Password")
        case .sms: return tr("SMS")
        }
    }

    private func sendCode() {
        guard case let .drive(platform) = target else { return }
        saving = true
        message = nil
        Task {
            defer { saving = false }
            do { challenge = try await model.sendSms(platform, phone: account) } catch { message = error.localizedDescription }
        }
    }

    private var pasteField: some View {
        SecureField(tr("Or paste the Cookie"), text: $pasted).textFieldStyle(.roundedBorder)
    }

    private var canSave: Bool {
        switch current {
        case .web: return detected != nil || !pasted.isEmpty
        case .sms: return challenge != nil && !account.isEmpty && !code.isEmpty
        case .password: return !pasted.isEmpty || (!account.isEmpty && !password.isEmpty)
        }
    }

    private func save() {
        saving = true
        message = nil
        Task {
            defer { saving = false }
            do {
                if current == .sms, let challenge {
                    try await model.smsLogin(phone: account, code: code.trimmingCharacters(in: .whitespaces), challenge: challenge)
                } else if current == .password, target == .drive(.xunlei) {
                    if let needed = try await model.xunleiPasswordLogin(account: account, password: password) {
                        challenge = needed
                        mode = .sms
                        return
                    }
                } else if let secret = pasted.isEmpty ? (current == .web ? detected : nil) : pasted {
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
