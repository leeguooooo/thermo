import AgentDoctor
import AppKit
import SwiftUI
import ThermoL10n

/// Where the diagnostics window is: the overview, or one area.
enum SidebarEntry: Hashable {
    case home
    case area(Area)
}

// MARK: - Landing page

struct DiagnosticsHome: View {
    @ObservedObject var scanner: AgentScanner
    let open: (Area) -> Void
    @State private var confirming = false

    var body: some View {
        ScrollView {
            VStack(spacing: 34) {
                hero.padding(.top, 54)
                DiagnosticScanControl(scanner: scanner)
                if !scanner.history.isEmpty { AgentActivity(scanner: scanner) }
                if let r = scanner.report, scanner.batch.map({ $0.finished }) ?? true { cards(r) }
            }
            .padding(.horizontal, 40).padding(.bottom, 40)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $confirming) {
            let plans = scanner.bulkFixes
            ConfirmSheet(title: tr("Fix %1$@ problems?", String(plans.count)),
                         summary: tr("Only fixes that are safe to run without looking: broken links, leftover processes, restart loops and the like. Everything else waits for you."),
                         destructive: plans.contains { $0.1.destructive }, heading: tr("What will run"),
                         lines: plans.flatMap { item, action in ["\(item.name) — \(action.title)"] + action.steps.map { "    " + $0.display } },
                         footnote: tr("Config files are copied to ~/Library/Application Support/Thermo/Backups before they change. Each step is logged to ~/Library/Logs/Thermo/fix.log."),
                         confirmTitle: tr("Fix"),
                         confirm: { confirming = false; scanner.performAll(plans) }, cancel: { confirming = false })
        }
    }

    @ViewBuilder var hero: some View {
        let problems = scanner.report?.problemCount ?? 0
        let fixable = scanner.bulkFixes.count
        if let b = scanner.batch, !b.finished {
            HeroStatus(symbol: b.verifying ? "stethoscope" : "wrench.and.screwdriver.fill", color: .blue,
                       title: b.verifying ? tr("Checking repair results…") : tr("Fixing %1$@ of %2$@", String(min(b.done + 1, b.total)), String(b.total)),
                       subtitle: b.verifying ? tr("Reading the current configuration again.") : b.current,
                       progress: b.verifying ? nil : Double(b.done) / Double(max(1, b.total)), spinning: b.verifying)
        } else if scanner.stopped {
            HeroStatus(symbol: "pause.circle", color: .purple, title: tr("Check stopped"),
                       subtitle: tr("Restart the read-only check when ready."))
        } else if scanner.report == nil {
            HeroStatus(symbol: "stethoscope", color: Color(red: 0.45, green: 0.4, blue: 1.0), title: tr("Checking your AI agents…"),
                       subtitle: tr("Claude Code, Codex, Cursor and Gemini: hooks, tools, plugins, skills and what runs in the background."),
                       spinning: true)
        } else if scanner.report?.hasResults == false {
            VStack(spacing: 26) {
                HeroStatus(symbol: "magnifyingglass", color: .purple, title: tr("No agent items found"),
                           subtitle: tr("Nothing to inspect yet. Configure your AI agent, then check again."),
                           spinning: scanner.scanning)
                BigRoundButton(title: tr("Check Again"), color: .purple, busy: scanner.scanning) { scanner.scan() }
            }
        } else if problems == 0 {
            VStack(spacing: 26) {
                HeroStatus(symbol: "checkmark", color: .green, title: tr("No configuration or process problems found"),
                           subtitle: tr("No problems in %1$@ items your AI agents use.", String(scanner.report?.items.count ?? 0)),
                           spinning: scanner.scanning)
                BigRoundButton(title: tr("Check Again"), color: .green, busy: scanner.scanning) { scanner.scan() }
            }
        } else {
            VStack(spacing: 26) {
                HeroStatus(symbol: "exclamationmark", color: scanner.report!.count(.error) > 0 ? .red : .orange,
                           title: problems == 1 ? tr("1 problem found") : tr("%1$@ problems found", String(problems)),
                           subtitle: fixable == 0 ? tr("Each one needs a decision from you; open its category to see why and what to do.")
                               : fixable == problems ? tr("All of them can be fixed with one click.")
                               : tr("%1$@ can be fixed with one click; the others need a decision from you.", String(fixable)),
                           spinning: scanner.scanning)
                HStack(spacing: 30) {
                    if fixable > 0 { BigRoundButton(title: tr("Fix %1$@", String(fixable)), busy: scanner.busy) { confirming = true } }
                    Button { scanner.scan() } label: { Label(tr("Check Again"), systemImage: "arrow.clockwise") }
                        .buttonStyle(PillButtonStyle()).disabled(scanner.busy)
                }
            }
        }
    }

    func cards(_ r: DoctorReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
            ForEach(Area.allCases, id: \.self) { a in
                let items = r.items.filter { $0.area == a }
                let bad = items.filter(\.isProblem)
                let problems = r.problemCount(in: a)
                let general = r.general(a)
                let empty = items.isEmpty && general.isEmpty
                let worst = (bad.compactMap(\.severity) + general.map(\.severity)).min()
                let fixable = bad.filter { i in i.actions.contains { $0.kind == .fix && $0.bulk } }.count
                CategoryCard(symbol: AgentStyle.icon(a), color: AgentStyle.tint(a), title: AgentStyle.title(a),
                             status: empty ? tr("No items to check") : problems == 0 && items.isEmpty ? tr("Notes available") : problems == 0 ? tr("%1$@ checked, all fine", String(items.count))
                                 : fixable > 0 ? tr("%1$@ fixable in one click", String(fixable)) : tr("needs your decision"),
                             statusColor: empty || (problems == 0 && items.isEmpty) ? .secondary : problems == 0 ? .green : AgentStyle.color(worst),
                             count: problems) { open(a) }
            }
        }
    }
}

// MARK: - One area

struct AreaPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var scanner: AgentScanner
    let area: Area
    @State private var confirmingFixes: [(AgentItem, Action)]?
    @State private var showHealthy = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var items: [AgentItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (scanner.report?.items ?? []).filter { $0.area == area }
            .filter { query.isEmpty || ($0.name + " " + $0.detail + " " + ($0.source ?? "") + " " + $0.agent).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let problems = items.filter(\.isProblem)
        let rest = items.filter { !$0.isProblem }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = (scanner.report?.general(area) ?? []).filter {
            query.isEmpty || [$0.subject, $0.message, $0.fix ?? "", $0.source ?? "", $0.agent].joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(problems)
                if area == .skills {
                    HStack {
                        Text(scanner.project?.path ?? tr("User Skill context only")).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button(tr("Choose Skill project…")) { chooseProject() }.disabled(scanner.busy)
                        if scanner.project != nil { Button(tr("User scope")) { scanner.selectProject(nil) }.disabled(scanner.busy) }
                    }
                    if let report = scanner.report { SkillContextCard(items: report.items.filter { $0.area == .skills }) }
                }
                if area == .mcp {
                    Text(tr("This configuration scan does not connect to MCP servers. Use Connect & inspect for definitions and connection timing; actual tool usage remains unmeasured."))
                        .font(.callout).foregroundStyle(.secondary).padding(18).glass()
                }
                if area == .mcp || area == .skills { ToolUsagePanel(model: scanner.toolUsage, kind: area == .mcp ? "mcp" : "skill") }
                DiagnosticScanControl(scanner: scanner)
                if !scanner.history.isEmpty { AgentActivity(scanner: scanner) }
                if problems.isEmpty && !notes.contains(where: { $0.severity == .error || $0.severity == .warning }) {
                    HStack(spacing: 10) {
                        let checking = scanner.scanning && scanner.report == nil
                        let empty = items.isEmpty
                        Image(systemName: checking ? "hourglass" : empty ? "magnifyingglass" : "checkmark.seal.fill")
                            .font(.title2).foregroundStyle(checking || empty ? Color.secondary : Color.green)
                        Text(checking ? tr(scanner.stopRequested ? "Stopping check…" : "Checking your AI agents…") : scanner.stopped && scanner.report == nil ? tr("Check stopped") : empty && !query.isEmpty ? tr("No matching items") : empty ? tr("No items to check") : tr("Nothing to fix here.")).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading).glass()
                }
                ForEach(Array(notes.enumerated()), id: \.offset) { _, finding in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(finding.subject, systemImage: finding.severity == .error ? "xmark.octagon" : finding.severity == .warning ? "exclamationmark.triangle" : "info.circle")
                            .font(.headline).foregroundStyle(AgentStyle.color(finding.severity))
                        Text(finding.message).textSelection(.enabled)
                        if let fix = finding.fix { Text(fix).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                        if let source = finding.source { Text(source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18).glass()
                }
                ForEach(problems) { ProblemCard(scanner: scanner, item: $0) }
                if !rest.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showHealthy.toggle() } } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(tr("%1$@ without detected problems", String(rest.count))).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "chevron.down").rotationEffect(.degrees(showHealthy ? 180 : 0)).foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(16).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showHealthy || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ForEach(rest) { i in
                                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                                HealthyRow(scanner: scanner, item: i).padding(.horizontal, 16)
                            }
                        }
                    }
                    .glass()
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 36).padding(.top, 48).padding(.bottom, 36)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: Binding(get: { confirmingFixes != nil }, set: { if !$0 { confirmingFixes = nil } })) {
            let plans = confirmingFixes ?? []
            ConfirmSheet(title: tr("Fix %1$@ problems?", String(plans.count)),
                         summary: tr("Review the commands before applying these fixes."),
                         destructive: plans.contains { $0.1.destructive }, heading: tr("What will run"),
                         lines: plans.flatMap { item, action in [item.name + " · " + action.title] + action.steps.map(\.display) },
                         footnote: tr("Every step is in ~/Library/Logs/Thermo/fix.log; changed config files were backed up first."),
                         confirmTitle: tr("Fix"), confirm: { confirmingFixes = nil; scanner.performAll(plans) },
                         cancel: { confirmingFixes = nil })
        }
    }

    @MainActor
    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = tr("Choose a project for Skill inspection")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = scanner.project
        panel.begin { response in
            if response == .OK, let url = panel.url { scanner.selectProject(url) }
        }
    }

    func header(_ problems: [AgentItem]) -> some View {
        HStack(alignment: .center, spacing: 18) {
            IconTile(symbol: AgentStyle.icon(area), color: AgentStyle.tint(area), size: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(AgentStyle.title(area)).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text(AgentStyle.explanation(area)).font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                let fixes = problems.compactMap { i in i.actions.first { $0.kind == .fix && $0.bulk }.map { (i, $0) } }
                if fixes.count > 1 {
                    Button(tr("Fix %1$@", String(fixes.count))) { confirmingFixes = fixes }.buttonStyle(PillButtonStyle(prominent: true)).disabled(scanner.busy)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                    TextField(tr("Search"), text: $search).textFieldStyle(.plain).foregroundStyle(.white)
                        .focused($searchFocused).accessibilityLabel(tr("Search"))
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel(tr("Clear search")).help(tr("Clear search"))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6).frame(width: 170)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .background(Button("") {
                    guard MainWindow.window?.attachedSheet == nil else { return }
                    searchFocused = true
                }.keyboardShortcut("f", modifiers: .command).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true))
            }
        }
        .padding(.bottom, 8)
    }
}

struct DiagnosticScanControl: View {
    @ObservedObject var scanner: AgentScanner
    var body: some View {
        if scanner.scanning {
            HStack {
                if scanner.stopRequested { Text(tr("Stopping check…")) }
                Spacer()
                Button(tr("Stop checking")) { scanner.stopScan() }.disabled(scanner.stopRequested)
            }
        } else if scanner.stopped {
            HStack {
                Text(tr(scanner.report == nil ? "No complete results were produced. Check again when ready." : "Previous complete results are kept. Check again to refresh them.")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Check Again")) { scanner.scan() }.disabled(scanner.busy)
            }
        }
    }
}

/// One problem: what is wrong in plain words, the fix right there, the details on request.
private struct ProblemCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var scanner: AgentScanner
    let item: AgentItem
    @State private var details = false
    @State private var confirming: Action?
    @State private var hover = false

    var findings: [Finding] { scanner.report?.findings(for: item) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(AgentStyle.color(item.severity).opacity(0.18)).frame(width: 34, height: 34)
                    Image(systemName: item.severity == .error ? "xmark" : "exclamationmark")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(AgentStyle.color(item.severity))
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                        if item.agent != "system" {
                            Text(item.agent).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.white.opacity(0.1)))
                        }
                    }
                    if let f = findings.first {
                        Text(f.message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 10)
                actions
            }
            if let last = scanner.lastResult, last.item == item.id {
                Label(last.result.ok ? tr("%1$@: done", last.action) : tr("%1$@: failed", last.action),
                      systemImage: last.result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(last.result.ok ? .green : .red).padding(.leading, 48)
            }
            if item.area == .mcp { MCPInspectButton(item: item, busy: scanner.busy).padding(.leading, 48) }
            Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { details.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(tr("Details")).font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(details ? 180 : 0))
                }
                .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain).padding(.leading, 48)
            if details {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(findings.enumerated()), id: \.offset) { i, f in
                        if i > 0 { Text(f.message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true) }
                        if let fix = f.fix {
                            Text(tr("Suggestion: %1$@", fix)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(item.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.55)).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
                    if let footprint = item.skillFootprint {
                        Text(footprint.summary).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if let src = item.source {
                        HStack {
                            Text(src).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.4)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            let path = (src as NSString).expandingTildeInPath
                            if FileManager.default.fileExists(atPath: path) {
                                Button(tr("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                    .buttonStyle(.link).font(.system(size: 11))
                            }
                        }
                    }
                }
                .padding(.leading, 48)
                .transition(.opacity)
            }
        }
        .padding(18)
        .glass(highlighted: hover)
        .onHover { hover = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hover)
        .sheet(item: $confirming) { a in
            ConfirmAction(action: a, item: item) { confirming = nil; scanner.perform(a, on: item) } cancel: { confirming = nil }
        }
    }

    @ViewBuilder var actions: some View {
        let primary = item.actions.first { $0.kind == .fix } ?? item.actions.first
        let others = item.actions.filter { $0.id != primary?.id }
        HStack(spacing: 8) {
            if let p = primary {
                Button { confirming = p } label: {
                    HStack(spacing: 5) {
                        if scanner.running == p.id { ProgressView().controlSize(.small).tint(.white) }
                        Text(p.title)
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: p.kind == .fix && p.bulk))
                .disabled(scanner.busy)
            }
            if !others.isEmpty {
                Menu {
                    ForEach(others) { a in Button(a.title, role: a.kind == .uninstall ? .destructive : nil) { confirming = a } }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.white.opacity(0.7)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .padding(6).background(Circle().fill(Color.white.opacity(0.1))).disabled(scanner.busy)
            }
        }
    }
}

/// A healthy item: name, what it is, and its actions in a menu (uninstall, disable…).
private struct HealthyRow: View {
    @ObservedObject var scanner: AgentScanner
    let item: AgentItem
    @State private var confirming: Action?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.enabled ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(item.enabled ? Color.green.opacity(0.85) : Color.white.opacity(0.35))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 13)).foregroundStyle(.white.opacity(item.enabled ? 0.92 : 0.5)).lineLimit(1).truncationMode(.middle)
                    if item.agent != "system" {
                        Text(item.agent).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    if !item.enabled { Text(tr("off")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }
                }
                Text(item.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.4)).lineLimit(1).truncationMode(.middle)
                if let footprint = item.skillFootprint {
                    Text(footprint.summary).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            if item.area == .mcp { MCPInspectButton(item: item, busy: scanner.busy) }
            if !item.actions.isEmpty {
                Menu {
                    ForEach(item.actions) { a in Button(a.title, role: a.kind == .uninstall ? .destructive : nil) { confirming = a } }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.white.opacity(0.6)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(scanner.busy)
            }
        }
        .padding(.vertical, 10)
        .sheet(item: $confirming) { a in
            ConfirmAction(action: a, item: item) { confirming = nil; scanner.perform(a, on: item) } cancel: { confirming = nil }
        }
    }
}

/// Results remain accessible even when a repaired item disappears from the inventory.
struct AgentActivity: View {
    @ObservedObject var scanner: AgentScanner
    var body: some View {
        DisclosureGroup(tr("Recent actions (this session)")) {
            VStack(spacing: 10) { ForEach(scanner.history) { AgentOutcomeRow(entry: $0) } }
                .padding(.top, 10)
        }
        .padding(16).glass().frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AgentOutcomeRow: View {
    let entry: AgentScanner.LastResult
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entry.result.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(entry.result.backups, id: \.self) { path in
                    Text(tr("Backup: %1$@", path)).font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.top, 8)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: entry.result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(entry.result.ok ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.callout.weight(.semibold))
                    Text(entry.action + " · " + (entry.result.ok ? tr("Action completed") : tr("Action failed")))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.time, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// After a batch: commands that completed, commands that failed, and the new report's remaining problems.
struct BatchResult: View {
    @ObservedObject var scanner: AgentScanner

    var body: some View {
        let batch = scanner.batch
        let failed = batch?.failed ?? 0
        let remaining = batch?.after ?? 0
        ZStack {
            WindowBackdrop(tint: failed == 0 && remaining == 0 ? .green : .orange)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(tr("Repair run finished")).font(.title2.weight(.bold))
                        Text(tr("%1$@ actions completed, %2$@ failed", String(max(0, (batch?.done ?? 0) - failed)), String(failed)))
                            .font(.callout)
                        Text(remaining == 0 ? tr("Nothing left to fix.") : tr("%1$@ still need a decision from you.", String(remaining)))
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(batch?.results ?? []) { AgentOutcomeRow(entry: $0).padding(12).glass() }
                        Text(tr("Every step is in ~/Library/Logs/Thermo/fix.log; changed config files were backed up first."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(24)
                }
                Divider()
                HStack {
                    Button(tr("Open action log")) { NSWorkspace.shared.open(DoctorEnvironment().logFile) }
                    Spacer()
                    Button(tr("Done")) { scanner.batch = nil }.keyboardShortcut(.defaultAction)
                        .buttonStyle(PillButtonStyle(prominent: true))
                }.padding(16)
            }
        }
        .frame(width: 560, height: 520)
        .preferredColorScheme(.dark)
    }
}
