import AppKit
import CloudDriveKit
import MediaToolsKit
import SwiftUI
import ThermoL10n
import VideoKit

/// Every platform at a glance. Adding always means the same "+"; backups sit in the footer menu.
struct YunXAccountsSheet: View {
    @ObservedObject var model: YunXDownloadModel
    @ObservedObject var setup: YunXChromeUseSetup
    @State private var backup: BackupMode?
    @Environment(\.dismiss) private var dismiss

    enum BackupMode: Identifiable {
        case export, restore(URL)
        var id: String { if case .export = self { return "export" } else { return "import" } }
    }

    private var targets: [YunXLoginTarget] {
        DrivePlatform.allCases.map(YunXLoginTarget.drive) + VideoPlatform.allCases.filter(\.needsLogin).map(YunXLoginTarget.video)
    }

    private var blocked: Bool { setup.state != .ready }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text(tr("Accounts")).font(Theme.heading).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(tr("Done")) { model.cancelChromeLogin(); dismiss() }.buttonStyle(PillButtonStyle()).keyboardShortcut(.cancelAction)
            }
            if setup.state == .missing || setup.state == .notConnected { YunXChromeUseCard(setup: setup) }
            if let target = model.chromeWaiting { YunXChromeWaiting(model: model, target: target) }
            if let error = model.error { NoticeBanner(text: error, dismiss: { model.error = nil }) }
            if let notice = model.notice { NoticeBanner(text: notice, dismiss: { model.notice = nil }) }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: 3), spacing: Theme.Space.s) {
                    ForEach(targets) { target in
                        YunXAccountTile(model: model, target: target, blocked: blocked && target.chromeURL != nil) { dismiss() }
                    }
                }
            }.frame(maxHeight: 400)
            HStack {
                Text(tr("Logins are kept only in the Keychain.")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                Spacer()
                Menu(tr("Backup")) {
                    Button(tr("Import backup…")) { pickBackup() }
                    Button(tr("Export backup…")) { backup = .export }
                }.menuStyle(.borderlessButton).fixedSize().font(Theme.secondary)
            }
        }
        .padding(Theme.Space.xl).frame(width: 640)
        .background(Theme.canvas).preferredColorScheme(.dark)
        .sheet(item: $model.login) { YunXLoginSheet(model: model, target: $0) }
        .sheet(item: $backup) { YunXBackupSheet(model: model, mode: $0) }
        .task { await setup.refresh() }
    }

    private func pickBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backup = .restore(url)
    }
}

struct YunXAccountTile: View {
    @ObservedObject var model: YunXDownloadModel
    let target: YunXLoginTarget
    let blocked: Bool
    let browsed: () -> Void
    @State private var hover = false

    private var accounts: [YunXAccount] { model.accounts(for: target.platform) }
    /// 139, 123 and 115 share a first digit, so numbers stay whole.
    private var monogram: String {
        let digits = target.title.prefix { $0.isNumber }
        return digits.isEmpty ? String(target.title.prefix(1)) : String(digits)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text(monogram).font(.system(size: monogram.count > 1 ? 10 : 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surfaceActive))
                    .accessibilityHidden(true)
                Text(target.title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                YunXRowIcon(symbol: "plus", label: tr("Add account")) { Task { await model.addAccount(target) } }
                    .disabled(blocked || model.importingLogin || model.chromeWaiting != nil).opacity(blocked ? 0.35 : 1)
            }
            if accounts.isEmpty {
                Text(tr("Not signed in")).font(Theme.caption).foregroundStyle(Theme.textTertiary).frame(height: 22)
            }
            ForEach(accounts) { account in row(account) }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(hover ? Theme.surfaceRaised : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
        .onHover { hover = $0 }
    }

    private func row(_ account: YunXAccount) -> some View {
        let name = account.nickname.isEmpty ? tr("Unnamed account") : account.nickname
        return HStack(spacing: 6) {
            Text(String(name.prefix(1))).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(account.isPrimary ? Theme.accent : Theme.textTertiary))
                .accessibilityHidden(true)
            Text(name).font(Theme.secondary).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                if case let .drive(platform) = target {
                    Button(tr("Browse")) { browsed(); Task { await model.browseDrive(platform) } }
                }
                if !account.isPrimary { Button(tr("Use")) { model.makePrimary(account) } }
                Button(tr("Remove"), role: .destructive) { model.remove(account) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().opacity(hover ? 1 : 0)
            .accessibilityLabel(name)
        }.frame(height: 22)
    }
}

struct YunXSettingsSheet: View {
    @ObservedObject var model: YunXDownloadModel
    @AppStorage(YunXClipboardSetting.key) private var clipboardPrompt = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text(tr("Download settings")).font(Theme.heading).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(tr("Done")) { dismiss() }.buttonStyle(PillButtonStyle()).keyboardShortcut(.cancelAction)
            }
            InspectorPanel {
                line(tr("Save to")) {
                    Text(model.saveDirectoryLabel).font(Theme.secondary).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    if !model.settings.saveDirectory.isEmpty {
                        Button(tr("Use Downloads")) { model.settings.saveDirectory = "" }.buttonStyle(PillButtonStyle()).controlSize(.small)
                    }
                    Button(tr("Choose…")) { pickFolder() }.buttonStyle(PillButtonStyle()).controlSize(.small)
                }
                InspectorDivider(inset: 14)
                line(tr("Offer to open supported links I copy")) {
                    Toggle("", isOn: Binding(get: { clipboardPrompt }, set: {
                        clipboardPrompt = $0
                        YunXClipboardPrompt.shared.refresh()
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                InspectorDivider(inset: 14)
                line(tr("Speed limit (KB/s, 0 is unlimited)"), help: tr("The limit covers HTTP downloads, not P2P.")) { number($model.settings.speedLimitKB) }
            }
            SectionHeader(title: "P2P")
            InspectorPanel {
                line(tr("P2P connections")) { number($model.settings.p2pConnections) }
                InspectorDivider(inset: 14)
                line(tr("P2P tasks at once")) { number($model.settings.p2pMaxRunning) }
                InspectorDivider(inset: 14)
                line(tr("DHT")) { Toggle("", isOn: $model.settings.p2pDHT).labelsHidden().toggleStyle(.switch).controlSize(.small) }
                InspectorDivider(inset: 14)
                line(tr("P2P proxy")) {
                    Picker("", selection: $model.settings.proxyMode) {
                        Text(tr("Direct")).tag(YunXSettings.ProxyMode.direct)
                        Text(tr("System")).tag(YunXSettings.ProxyMode.system)
                        Text(tr("Manual")).tag(YunXSettings.ProxyMode.manual)
                    }.labelsHidden().fixedSize()
                }
                if model.settings.proxyMode == .manual {
                    InspectorDivider(inset: 14)
                    line(tr("Proxy host")) {
                        TextField(tr("Proxy host"), text: $model.settings.proxyHost).textFieldStyle(.roundedBorder).frame(width: 160)
                        number($model.settings.proxyPort)
                    }
                }
                InspectorDivider(inset: 14)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(tr("Extra trackers, one per line")).font(Theme.body).foregroundStyle(Theme.textPrimary)
                    TextEditor(text: Binding(get: { model.settings.trackers.joined(separator: "\n") }, set: { text in
                        model.settings.trackers = text.components(separatedBy: "\n")
                    })).font(Theme.mono).scrollContentBackground(.hidden).frame(height: 56).padding(Theme.Space.xs)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).strokeBorder(Theme.hairline))
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .padding(Theme.Space.xl).frame(width: 520)
        .background(Theme.canvas).preferredColorScheme(.dark)
    }

    private func line<Content: View>(_ title: String, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(title).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1).layoutPriority(1)
            if let help { InfoButton(text: help) }
            Spacer(minLength: Theme.Space.m)
            content()
        }.padding(.horizontal, 14).frame(minHeight: 40)
    }

    private func number(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.saveDirectory = url.path
    }
}
