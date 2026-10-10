import AppKit
import SwiftUI
import ThermoL10n
import AgentCore

/// Sets up thermo-use: the `thermo` CLI on PATH for AI agents, and the thermo-use skill in Claude
/// Code and Codex (it is part of the *-use family in leeguooooo/plugins).
final class AgentAccess: ObservableObject {
    enum Tool: Equatable { case missing, notAdded, added }

    @Published private(set) var cliLinked = false
    @Published private(set) var linkProblem: String?
    @Published private(set) var claude: Tool = .missing
    @Published private(set) var codex: Tool = .missing
    @Published private(set) var busy: String?
    @Published var message: String?

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

    var ready: Bool { cliLinked && (claude == .added || codex == .added || (claude == .missing && codex == .missing)) }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let linked = ["thermo", "thermo-use"].allSatisfy {
                (try? fm.destinationOfSymbolicLink(atPath: self.binDir + "/" + $0)) == self.cli
            }
            var claude: Tool = .missing
            if Self.find("claude") != nil {
                let installed = (try? String(contentsOfFile: self.home + "/.claude/plugins/installed_plugins.json", encoding: .utf8)) ?? ""
                claude = installed.contains(Self.plugin) ? .added : .notAdded
            }
            var codex: Tool = .missing
            if let c = Self.find("codex") {
                let list = Self.run(c, ["plugin", "list"], timeout: 15) ?? ""
                codex = list.contains("thermo-use") && list.lowercased().contains("installed") ? .added : .notAdded
            }
            DispatchQueue.main.async { self.cliLinked = linked; self.claude = claude; self.codex = codex }
        }
    }

    /// `~/.local/bin/thermo` and `thermo-use` → this app's CLI. Only symlinks are replaced.
    func linkCLI() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            for name in ["thermo", "thermo-use"] {
                let p = binDir + "/" + name
                if (try? fm.destinationOfSymbolicLink(atPath: p)) != nil { try fm.removeItem(atPath: p) }
                else if fm.fileExists(atPath: p) {
                    linkProblem = tr("%1$@ already exists and is not a link; remove it first", FS_tilde(p))
                    return
                }
                try fm.createSymbolicLink(atPath: p, withDestinationPath: cli)
            }
            linkProblem = nil
        } catch {
            linkProblem = error.localizedDescription
        }
        refresh()
    }

    func addToClaude() { install(tool: "claude", label: "Claude Code", steps: [["plugin", "marketplace", "add", Self.marketplace], ["plugin", "install", Self.plugin]]) }
    func addToCodex() { install(tool: "codex", label: "Codex", steps: [["plugin", "marketplace", "add", Self.marketplace], ["plugin", "add", Self.plugin]]) }

    private func install(tool: String, label: String, steps: [[String]]) {
        guard let bin = Self.find(tool) else { return }
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
                self.message = ok ? tr("Added to %1$@. New sessions can use it.", label)
                                  : tr("%1$@ could not add it; copy the command below instead.", label)
                if !self.cliLinked { self.linkCLI() } else { self.refresh() }
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
    static func run(_ bin: String, _ args: [String], timeout: TimeInterval) -> String? {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        let result = CommandRunner.run(bin, arguments: args, environment: env, timeout: timeout)
        guard result.status == 0, !result.timedOut, !result.cancelled, !result.truncated else { return nil }
        return result.output
    }
}

private func FS_tilde(_ p: String) -> String {
    let h = NSHomeDirectory()
    return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p
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
                Text(access.ready ? tr("Agents can check this Mac") : tr("Let Claude Code, Codex and other agents check this Mac"))
                    .font(.caption).foregroundStyle(access.ready ? Color.green : .secondary)
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
                    Text(tr("Let AI agents check this Mac")).font(.headline)
                    Text(tr("thermo-use gives Claude Code, Codex and other agents the thermo command: why the Mac is slow, temperatures and fans, disk cleanup that knows AI tools, and AI agent diagnostics. It is part of the *-use family. Agents look freely; they only clean, change fans or quit programs when you ask."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            step(done: access.cliLinked, title: tr("Command line"),
                 detail: access.linkProblem ?? (access.cliLinked ? tr("thermo and thermo-use are in ~/.local/bin") : tr("Puts thermo and thermo-use in ~/.local/bin, pointing at this app (they update with it)")),
                 button: access.cliLinked ? nil : (tr("Set Up"), access.linkCLI))
            step(done: access.claude == .added, title: "Claude Code",
                 detail: access.claude == .missing ? tr("Not installed on this Mac") : access.claude == .added ? tr("thermo-use is installed") : tr("Adds the thermo-use plugin"),
                 button: access.claude == .notAdded ? (tr("Add"), access.addToClaude) : nil,
                 copy: "/plugin install \(AgentAccess.plugin)")
            step(done: access.codex == .added, title: "Codex",
                 detail: access.codex == .missing ? tr("Not installed on this Mac") : access.codex == .added ? tr("thermo-use is installed") : tr("Adds the thermo-use plugin"),
                 button: access.codex == .notAdded ? (tr("Add"), access.addToCodex) : nil,
                 copy: "codex plugin add \(AgentAccess.plugin)")
            step(done: nil, title: tr("Any other agent"), detail: tr("Run this in its terminal; the skill is SKILL.md in leeguooooo/thermo-use"), button: nil, copy: AgentAccess.curl)
            step(done: nil, title: tr("The whole *-use family"), detail: tr("Browser, mail, messages, passwords, notes … and thermo-use, in one install"),
                 button: nil, copy: "/plugin install \(AgentAccess.family)")

            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Try asking your agent")).font(.subheadline.weight(.semibold))
                ForEach([tr("“Why is my Mac so slow right now?”"), tr("“Which old AI sessions take the most space?”"),
                         tr("“Is anything wrong with my MCP servers or hooks?”"), tr("“Turn the fans to max.”")], id: \.self) {
                    Text($0).font(.callout).foregroundStyle(.secondary)
                }
            }

            if let m = access.message { Text(m).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if let b = access.busy { ProgressView().controlSize(.small); Text(tr("Adding to %1$@…", b)).font(.caption) }
                Spacer()
                Button(tr("Done"), action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { access.refresh() }
    }

    func step(done: Bool?, title: String, detail: String, button: (String, () -> Void)?, copy: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done == true ? "checkmark.circle.fill" : done == false ? "circle" : "arrow.right.circle")
                .foregroundStyle(done == true ? Color.green : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let copy {
                    HStack(spacing: 6) {
                        Text(copy).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copy, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help(tr("Copy"))
                    }
                }
            }
            Spacer()
            if let button { Button(button.0, action: button.1).disabled(access.busy != nil) }
        }
    }
}
