import AgentCore
import AppKit
import SwiftUI
import ThermoL10n

/// The leeguooooo marketplace. Reads when the page opens; changes run only from a click here.
@MainActor
final class PluginsModel: ObservableObject {
    @Published private(set) var records: [PluginRecord] = []
    @Published private(set) var loading = false
    @Published private(set) var checkingUpdates = false
    @Published private(set) var usingCachedCopy = false
    @Published private(set) var loaded = false
    @Published private(set) var useMissing = false
    @Published private(set) var claudeMissing = false
    @Published private(set) var working: String?
    @Published var message: String?
    private var marketplace: Marketplace?
    private var use = UseManagerState()
    private var lastLoad: Date?
    private let cache = StoreCache()
    private static let cacheName = "marketplace.json"

    func open() {
        if let lastLoad, Date().timeIntervalSince(lastLoad) < 600 { return }
        refresh()
    }

    func refresh() {
        guard !loading, working == nil else { return }
        loading = true
        lastLoad = Date()
        let cache = cache
        Task {
            let fetched = await StoreFetch.data(Marketplace.url)
            if let fetched, let market = Marketplace.decode(fetched) {
                cache.write(fetched, as: Self.cacheName)
                marketplace = market
                usingCachedCopy = false
            } else {
                if marketplace == nil { marketplace = cache.read(Self.cacheName).flatMap(Marketplace.decode) }
                usingCachedCopy = marketplace != nil
            }
            await readLocalState()
            loading = false
            loaded = true
            checkForUpdates()
        }
    }

    /// Plugin versions and `use` state, off the main thread: `use status` starts Python.
    private func readLocalState() async {
        let previous = use
        let (state, useFound, claudeFound, installed) = await Task.detached(priority: .userInitiated) { () -> (UseManagerState, Bool, Bool, [InstalledPlugin]) in
            var state = previous
            let bin = AgentAccess.find("use")
            if let bin, let result = Self.execute(bin, ["status", "--json"], directory: nil, timeout: 30, captureError: false), result.status == 0 {
                state.read(status: Data(result.output.utf8))
            }
            return (state, bin != nil, AgentAccess.find("claude") != nil, ClaudePlugins.installed())
        }.value
        use = state
        useMissing = !useFound
        claudeMissing = !claudeFound
        if let marketplace { records = PluginRecords.build(marketplace, installed: installed, use: use) }
    }

    private func checkForUpdates() {
        guard let bin = AgentAccess.find("use"), !checkingUpdates else { return }
        checkingUpdates = true
        Task {
            let output = await Task.detached(priority: .utility) {
                Self.execute(bin, ["update", "--check", "--json"], directory: nil, timeout: 120, captureError: false)?.output
            }.value
            checkingUpdates = false
            guard let output, working == nil else { return }
            use.read(check: Data(output.utf8))
            if let marketplace { records = PluginRecords.build(marketplace, installed: ClaudePlugins.installed(), use: use) }
        }
    }

    func canUpdate(_ record: PluginRecord) -> Bool { PluginCommands.update(record, use: useMissing ? nil : use) != nil }

    func install(_ record: PluginRecord) {
        run(record.plugin.name, PluginCommands.install(record.plugin, marketplaceKnown: ClaudePlugins.marketplaceKnown()))
    }

    func update(_ record: PluginRecord) {
        guard let steps = PluginCommands.update(record, use: useMissing ? nil : use) else { return }
        run(record.plugin.name, steps)
    }

    func uninstall(_ record: PluginRecord) {
        guard let steps = PluginCommands.uninstall(record) else { return }
        run(record.plugin.name, steps)
    }

    /// Runs only from the confirm button, after the page has shown the command.
    func installUse() {
        guard working == nil else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-use-install-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return }
        let script = folder.appendingPathComponent("install-use.sh").path
        run("use", [PluginCommands.downloadUseInstaller(to: script), PluginCommands.runUseInstaller(at: script)]) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func run(_ name: String, _ steps: [StoreCommand], finally cleanup: @escaping @Sendable () -> Void = {}) {
        guard working == nil else { return }
        working = name
        message = nil
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                defer { cleanup() }
                for step in steps {
                    let binary: String?
                    switch step.tool {
                    case .claude: binary = AgentAccess.find("claude")
                    case .use: binary = AgentAccess.find("use")
                    case let .path(path): binary = path
                    }
                    guard let binary else { return tr("The required command was not found.") }
                    guard let result = Self.execute(binary, step.arguments, directory: step.directory, timeout: 600, captureError: true) else {
                        return tr("The command did not finish.")
                    }
                    if result.status == 75 { return tr("Another upgrade is running. Try again when it finishes.") }
                    // `marketplace update` is best effort: a stale list must not block the install.
                    if result.status != 0, !(step.arguments.starts(with: ["plugin", "marketplace", "update"])) {
                        return StoreText.clean(result.output, limit: 300) ?? tr("The command failed.")
                    }
                }
                return nil
            }.value
            working = nil
            message = failure.map { tr("%1$@: %2$@", name, $0) } ?? tr("%1$@ finished. Restart Claude Code to apply plugin changes.", name)
            lastLoad = nil
            refresh()
        }
    }

    private nonisolated static func execute(_ binary: String, _ arguments: [String], directory: String?, timeout: TimeInterval, captureError: Bool) -> CommandRunner.Result? {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        let result = CommandRunner.run(binary, arguments: arguments, directory: directory, environment: environment, timeout: timeout, captureError: captureError)
        return result.timedOut || result.cancelled ? nil : result
    }
}

struct PluginsPage: View {
    @ObservedObject var model: PluginsModel
    let open: (MainPage) -> Void
    @State private var removing: PluginRecord?
    @State private var confirmUse = false

    var body: some View {
        WindowPage(title: tr("Plugins"), subtitle: tr("Plugins from the leeguooooo marketplace for Claude Code")) {
            HStack(spacing: 8) {
                if model.checkingUpdates {
                    ProgressView().controlSize(.small)
                    Text(tr("Checking for updates…")).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button(tr("Installed plugin diagnostics")) { open(.agents(.area(.plugins))) }
                    .buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
                Button(tr("Refresh")) { model.refresh() }
                    .buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
                    .disabled(model.loading || model.working != nil)
            }
            if let message = model.message { NoticeBanner(text: message, dismiss: { model.message = nil }) }
            if let working = model.working { NoticeBanner(text: tr("Working on %1$@…", working), busy: true) }
            if model.usingCachedCopy { NoticeBanner(text: tr("Could not reach the marketplace. Showing the last saved copy.")) }
            if model.claudeMissing { NoticeBanner(text: tr("Claude Code was not found, so plugins cannot be installed from here.")) }
            if model.useMissing { useInstaller }
            if model.records.isEmpty {
                if model.loaded {
                    EmptyState(symbol: "puzzlepiece.extension", title: tr("Marketplace unavailable"),
                               detail: tr("Check the connection and refresh."))
                } else {
                    NoticeBanner(text: tr("Loading the marketplace…"), busy: true)
                }
            } else {
                InspectorPanel {
                    ForEach(Array(model.records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider() }
                        row(record)
                    }
                }
            }
        }
        .onAppear { model.open() }
        .confirmationDialog(tr("Uninstall %1$@?", removing?.plugin.name ?? ""), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { record in
            Button(tr("Uninstall"), role: .destructive) { model.uninstall(record) }
            Button(tr("Cancel"), role: .cancel) {}
        } message: { _ in
            Text(tr("This removes the Claude Code plugin. A command-line tool installed separately stays."))
        }
        .confirmationDialog(tr("Install the use manager?"), isPresented: $confirmUse) {
            Button(tr("Install")) { model.installUse() }
            Button(tr("Cancel"), role: .cancel) {}
        } message: {
            Text(PluginCommands.useInstallerDisplay)
        }
    }

    var useInstaller: some View {
        InspectorPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("The use manager is not installed")).font(.system(size: 13, weight: .medium))
                Text(tr("It keeps the *-use tools up to date. Thermo downloads and runs this script only after you confirm:"))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Text(verbatim: PluginCommands.useInstallerDisplay)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Button(tr("Install use…")) { confirmUse = true }
                    .buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small).fixedSize()
                    .disabled(model.working != nil)
            }.padding(12)
        }
    }

    func row(_ record: PluginRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: record.plugin.name).font(.system(size: 13, weight: .medium))
                    if let version = record.plugin.version {
                        Text(verbatim: version).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                    if let category = record.plugin.category {
                        Text(verbatim: AppStorePage.category(category)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                if let description = record.plugin.description {
                    Text(verbatim: description).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
                }
                Text(status(record)).font(Theme.caption).foregroundStyle(statusColor(record))
            }
            Spacer(minLength: 8)
            actions(record)
        }.padding(12)
    }

    @ViewBuilder func actions(_ record: PluginRecord) -> some View {
        HStack(spacing: 6) {
            if let homepage = record.plugin.homepage {
                Button { NSWorkspace.shared.open(homepage) } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless).help(tr("Open homepage")).accessibilityLabel(tr("Open homepage"))
            }
            if case .updateAvailable = record.state, model.canUpdate(record) {
                Button(tr("Update")) { model.update(record) }
                    .buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small).fixedSize()
            }
            if record.install == nil {
                Button(tr("Install")) { model.install(record) }
                    .buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize().disabled(model.claudeMissing)
            } else if PluginCommands.uninstall(record) != nil {
                Button(tr("Uninstall")) { removing = record }
                    .buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
            }
        }.disabled(model.working != nil)
    }

    func status(_ record: PluginRecord) -> String {
        let current = record.installedVersion ?? tr("unknown version")
        let scope = record.install == nil && record.cliVersion != nil ? " · " + tr("command-line tool only") : ""
        switch record.state {
        case .notInstalled: return tr("Not installed")
        case .installed: return tr("Installed %1$@", current) + scope
        case let .updateAvailable(latest): return tr("Update available: %1$@ → %2$@", current, latest) + scope
        }
    }

    func statusColor(_ record: PluginRecord) -> Color {
        switch record.state {
        case .notInstalled: return Theme.textTertiary
        case .installed: return .green
        case .updateAvailable: return .orange
        }
    }
}
