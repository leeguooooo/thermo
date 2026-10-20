import AppKit
import SwiftUI
import ThermoL10n
import AgentCore

/// Sets up thermo-use: the `thermo` CLI on PATH for AI agents, and the thermo-use skill in Claude
/// Code and Codex (it is part of the *-use family in leeguooooo/plugins).
final class AgentAccess: ObservableObject {
    enum Tool: Equatable { case checking, unavailable, missing, notAdded, disabled, added }
    enum InstalledTool { case claude, codex }
    private struct CodexPluginList: Decodable {
        struct Entry: Decodable {
            var pluginId: String
            var installed: Bool
            var enabled: Bool
        }
        var installed: [Entry]
    }
    struct Status {
        var cliLinked: Bool
        var claude: Tool
        var codex: Tool
    }

    @Published private(set) var cliLinked = false
    @Published private(set) var linkProblem: String?
    @Published private(set) var claude: Tool = .checking
    @Published private(set) var codex: Tool = .checking
    @Published private(set) var checking = false
    @Published private(set) var busy: String?
    @Published var message: String?
    private var queuedCheck: (() -> Status)?
    private var installationToVerify: (InstalledTool, String)?

    static let marketplace = "leeguooooo/plugins"
    static let plugin = "thermo-use@leeguooooo-plugins"
    static let family = "use-family@leeguooooo-plugins"
    static let curl = "curl -fsSL https://raw.githubusercontent.com/leeguooooo/thermo-use/main/install.sh | sh"

    let home = NSHomeDirectory()
    var binDir: String { home + "/.local/bin" }

    /// The CLI inside this app (Contents/Helpers/thermo).
    var cli: String {
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/thermo").path
        if FileManager.default.isExecutableFile(atPath: inBundle) { return inBundle }
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("thermo").path
    }

    var ready: Bool { !checking && busy == nil && cliLinked && (claude == .added || codex == .added || (claude == .missing && codex == .missing)) }

    func refresh() {
        guard !checking, busy == nil else { return }
        refreshAfterChange()
    }

    private func refreshAfterChange() {
        refresh(check: { self.readStatus() })
    }

    /// Coalesce requests into one fresh follow-up check; older results never win.
    func refresh(check: @escaping () -> Status) {
        guard !checking, busy == nil else { queuedCheck = check; return }
        queuedCheck = nil
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let status = check()
            DispatchQueue.main.async {
                self.checking = false
                if let queued = self.queuedCheck {
                    self.queuedCheck = nil
                    self.refresh(check: queued)
                    return
                }
                guard self.busy == nil else { self.refreshAfterChange(); return }
                self.cliLinked = status.cliLinked
                self.claude = status.claude
                self.codex = status.codex
                if let (tool, label) = self.installationToVerify {
                    self.message = Self.installationMessage(tool == .claude ? status.claude : status.codex, label: label)
                    self.installationToVerify = nil
                }
            }
        }
    }

    private func readStatus() -> Status {
        let linked = AgentCLILinks.ready(directory: binDir, cli: cli)
        let claude = Self.find("claude") == nil ? .missing : Self.claudeState(home: home)
        var codex: Tool = .missing
        if let binary = Self.find("codex") {
            if let list = Self.run(binary, ["plugin", "list", "--json"], timeout: 15, captureError: false) {
                codex = Self.codexState(json: list)
            } else { codex = .unavailable }
        }
        return Status(cliLinked: linked, claude: claude, codex: codex)
    }

    static func claudeState(home: String) -> Tool {
        let path = home + "/.claude/plugins/installed_plugins.json"
        guard FileManager.default.fileExists(atPath: path) else { return .notAdded }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["plugins"] is [String: Any] else { return .unavailable }
        let installed = ClaudePlugins.installed(AgentHome(home: home))
        guard installed.contains(where: { $0.id == Self.plugin && $0.scope == "user" && FileManager.default.fileExists(atPath: $0.installPath) }) else { return .notAdded }
        guard let settingsData = try? Data(contentsOf: URL(fileURLWithPath: home + "/.claude/settings.json")),
              let settings = (try? JSONSerialization.jsonObject(with: settingsData)) as? [String: Any],
              let enabled = (settings["enabledPlugins"] as? [String: Any])?[plugin] as? Bool else { return .unavailable }
        return enabled ? .added : .disabled
    }

    static func codexState(json: String) -> Tool {
        guard let list = try? JSONDecoder().decode(CodexPluginList.self, from: Data(json.utf8)) else { return .unavailable }
        guard let item = list.installed.first(where: { $0.pluginId == plugin }) else { return .notAdded }
        guard item.installed else { return .notAdded }
        return item.enabled ? .added : .disabled
    }

    static func installationMessage(_ state: Tool, label: String) -> String {
        switch state {
        case .added: return tr("Installed and enabled in %1$@. Open a new session and check its Skill list to confirm loading.", label)
        case .disabled: return tr("Installed in %1$@, but disabled. Enable the plugin before using it.", label)
        default: return tr("The command finished, but installation in %1$@ could not be confirmed. Check its plugin settings.", label)
        }
    }

    /// `~/.local/bin/thermo` and `thermo-use` → this app's CLI. Only symlinks are replaced.
    func linkCLI() {
        do {
            try AgentCLILinks.link(directory: binDir, cli: cli)
            linkProblem = nil
        } catch {
            linkProblem = error.localizedDescription
        }
        refreshAfterChange()
    }

    func addToClaude() { install(tool: "claude", label: "Claude Code", steps: [["plugin", "marketplace", "add", Self.marketplace], ["plugin", "install", Self.plugin]]) }
    func addToCodex() { install(tool: "codex", label: "Codex", steps: [["plugin", "marketplace", "add", Self.marketplace], ["plugin", "add", Self.plugin]]) }

    private func install(tool: String, label: String, steps: [[String]]) {
        guard busy == nil, let bin = Self.find(tool) else { return }
        busy = label
        DispatchQueue.global(qos: .userInitiated).async {
            // Adding a marketplace that is already there fails harmlessly; the install is what counts.
            var ok = false
            for (i, args) in steps.enumerated() {
                let out = Self.run(bin, args, timeout: 120)
                if i == steps.count - 1 { ok = out != nil }
            }
            DispatchQueue.main.async {
                self.busy = nil
                if ok {
                    self.installationToVerify = (tool == "claude" ? .claude : .codex, label)
                    self.message = tr("The command finished. Checking installation…")
                } else {
                    self.message = tr("%1$@ could not add it; copy the command below instead.", label)
                }
                if !self.cliLinked { self.linkCLI() } else { self.refreshAfterChange() }
            }
        }
    }

    // MARK: helpers

    /// GUI apps get a bare PATH; look where these CLIs usually live.
    static func find(_ name: String) -> String? {
        let home = NSHomeDirectory()
        return [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.npm-global/bin", home + "/.bun/bin", "/usr/bin"]
            .map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Returns complete combined output only when the tool succeeds within the time limit.
    static func run(_ bin: String, _ args: [String], timeout: TimeInterval, captureError: Bool = true) -> String? {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        let result = CommandRunner.run(bin, arguments: args, environment: env, timeout: timeout, captureError: captureError)
        guard result.status == 0, !result.timedOut, !result.cancelled, !result.truncated else { return nil }
        return result.output
    }
}

/// One line in Settings: status and a button that opens the setup sheet.
struct AgentAccessRow: View {
    @StateObject private var access = AgentAccess()
    @State private var open = false

    var body: some View {
        HStack {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("AI agents (thermo-use)"))
                Text(access.checking ? tr("Checking installation…") : access.ready ? tr("CLI link verified; review agent setup") : tr("Let Claude Code, Codex and other agents check this Mac"))
                    .font(Theme.caption).foregroundStyle(access.ready ? Color.green : .secondary)
            }
            Spacer()
            Button(access.ready ? tr("Details…") : tr("Set Up…")) { open = true }
        }
        .onAppear { access.refresh() }
        .sheet(isPresented: $open) { AgentAccessSheet(access: access) { open = false } }
    }
}

struct AgentAccessSheet: View {
    @ObservedObject var access: AgentAccess
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Let AI agents check this Mac")).font(Theme.secondary.weight(.semibold))
                    Text(tr("thermo-use gives Claude Code, Codex and other agents the thermo command: why the Mac is slow, temperatures and fans, disk cleanup that knows AI tools, and AI agent diagnostics. It is part of the *-use family. Agents look freely; they only clean, change fans or quit programs when you ask."))
                        .font(Theme.secondary).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }

            step(done: access.cliLinked, title: tr("Command line"),
                 detail: access.linkProblem ?? (access.cliLinked ? tr("thermo and thermo-use are in ~/.local/bin") : tr("Puts thermo and thermo-use in ~/.local/bin, pointing at this app (they update with it)")),
                 button: access.cliLinked ? nil : (tr("Set Up"), access.linkCLI), allowWhileChecking: true)
            step(done: access.claude == .added, title: "Claude Code",
                 detail: toolDetail(access.claude),
                 button: toolButton(access.claude, add: access.addToClaude),
                 copy: access.claude == .disabled ? nil : "/plugin install \(AgentAccess.plugin)")
            step(done: access.codex == .added, title: "Codex",
                 detail: toolDetail(access.codex),
                 button: toolButton(access.codex, add: access.addToCodex),
                 copy: access.codex == .disabled ? nil : "codex plugin add \(AgentAccess.plugin)")
            step(done: nil, title: tr("Any other agent"), detail: tr("Links the CLI. For other agents, copy the complete skills/thermo-use folder, including references, from leeguooooo/thermo-use."), button: nil, copy: AgentAccess.curl)
            step(done: nil, title: tr("The whole *-use family"), detail: tr("Browser, mail, messages, passwords, notes … and thermo-use, in one install"),
                 button: nil, copy: "/plugin install \(AgentAccess.family)")

            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Try asking your agent")).font(Theme.rowTitle)
                ForEach([tr("“Why is my Mac so slow right now?”"), tr("“Which old AI sessions take the most space?”"),
                         tr("“Is anything wrong with my MCP servers or hooks?”"), tr("“Turn the fans to max.”")], id: \.self) {
                    Text($0).font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                }
            }

            if let m = access.message { Text(m).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
            HStack {
                if let b = access.busy { ProgressView().controlSize(.small); Text(tr("Adding to %1$@…", b)).font(Theme.caption) }
                else if access.checking { ProgressView().controlSize(.small); Text(tr("Checking installation…")).font(Theme.caption) }
                Spacer()
                Button(tr("Done"), action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { access.refresh() }
    }

    private func toolDetail(_ tool: AgentAccess.Tool) -> String {
        switch tool {
        case .checking: return tr("Checking installation…")
        case .unavailable: return tr("Could not check installation. Retry before adding the plugin.")
        case .missing: return tr("Not installed on this Mac")
        case .added: return tr("thermo-use is installed")
        case .disabled: return tr("thermo-use is installed, but disabled in the agent’s plugin settings.")
        case .notAdded: return tr("Adds the thermo-use plugin")
        }
    }

    private func toolButton(_ tool: AgentAccess.Tool, add: @escaping () -> Void) -> (String, () -> Void)? {
        switch tool {
        case .unavailable: return (tr("Retry"), access.refresh)
        case .notAdded: return (tr("Add"), add)
        default: return nil
        }
    }

    func step(done: Bool?, title: String, detail: String, button: (String, () -> Void)?, copy: String? = nil,
              allowWhileChecking: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done == true ? "checkmark.circle.fill" : done == false ? "circle" : "arrow.right.circle")
                .foregroundStyle(done == true ? Color.green : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                if let copy {
                    HStack(spacing: 6) {
                        Text(copy).font(Theme.mono).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copy, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help(tr("Copy"))
                    }
                }
            }
            Spacer()
            if let button { Button(button.0, action: button.1).disabled(access.busy != nil || (access.checking && !allowWhileChecking)) }
        }
    }
}
