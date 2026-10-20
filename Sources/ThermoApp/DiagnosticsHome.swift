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
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: tr("Smart Check"),
                           subtitle: tr("Claude Code, Codex, Cursor and Gemini: hooks, tools, plugins, skills and what runs in the background."))
                hero
                DiagnosticScanControl(scanner: scanner)
                if let r = scanner.report, scanner.batch.map({ $0.finished }) ?? true { cards(r) }
                if !scanner.history.isEmpty { AgentActivity(scanner: scanner) }
            }
            .frame(maxWidth: Theme.pageWidth, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pageTop).padding(.bottom, Theme.Space.xxl)
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

    /// The page's one focal point: a status ring, the verdict, and the action it calls for.
    @ViewBuilder var hero: some View {
        let problems = scanner.report?.problemCount ?? 0
        let fixable = scanner.bulkFixes.count
        if let b = scanner.batch, !b.finished {
            DiagnosticsHero(symbol: b.verifying ? "stethoscope" : "wrench.and.screwdriver", color: Theme.accent,
                            title: b.verifying ? tr("Checking repair results…") : tr("Fixing %1$@ of %2$@", String(min(b.done + 1, b.total)), String(b.total)),
                            subtitle: b.verifying ? tr("Reading the current configuration again.") : b.current,
                            progress: b.verifying ? nil : Double(b.done) / Double(max(1, b.total)), spinning: b.verifying) { EmptyView() }
        } else if scanner.stopped {
            DiagnosticsHero(symbol: "pause", color: Theme.textSecondary, title: tr("Check stopped"),
                            subtitle: tr("Restart the read-only check when ready.")) { EmptyView() }
        } else if scanner.report == nil {
            DiagnosticsHero(symbol: "stethoscope", color: Theme.accent, title: tr("Checking your AI agents…"),
                            subtitle: nil, spinning: true) { EmptyView() }
        } else if scanner.report?.hasResults == false {
            DiagnosticsHero(symbol: "magnifyingglass", color: Theme.textSecondary, title: tr("No agent items found"),
                            subtitle: tr("Nothing to inspect yet. Configure your AI agent, then check again."),
                            spinning: scanner.scanning) {
                checkAgain(prominent: true)
            }
        } else if problems == 0 {
            DiagnosticsHero(symbol: "checkmark", color: Theme.good, title: tr("No configuration or process problems found"),
                            subtitle: tr("No problems in %1$@ items your AI agents use.", String(scanner.report?.items.count ?? 0)),
                            spinning: scanner.scanning) {
                checkAgain(prominent: false)
            }
        } else {
            DiagnosticsHero(symbol: "exclamationmark", color: scanner.report!.count(.error) > 0 ? Theme.danger : Theme.caution,
                            title: problems == 1 ? tr("1 problem found") : tr("%1$@ problems found", String(problems)),
                            subtitle: fixable == 0 ? tr("Each one needs a decision from you; open its category to see why and what to do.")
                                : fixable == problems ? tr("All of them can be fixed with one click.")
                                : tr("%1$@ can be fixed with one click; the others need a decision from you.", String(fixable)),
                            spinning: scanner.scanning) {
                HStack(spacing: Theme.Space.s) {
                    checkAgain(prominent: false)
                    if fixable > 0 {
                        Button(tr("Fix %1$@", String(fixable))) { confirming = true }
                            .buttonStyle(PillButtonStyle(prominent: true)).disabled(scanner.busy)
                    }
                }
            }
        }
    }

    func checkAgain(prominent: Bool) -> some View {
        Button { scanner.scan() } label: { Label(tr("Check Again"), systemImage: "arrow.clockwise") }
            .buttonStyle(PillButtonStyle(prominent: prominent)).disabled(scanner.busy)
    }

    func cards(_ r: DoctorReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
            ForEach(Area.allCases, id: \.self) { a in
                let items = r.items.filter { $0.area == a }
                let bad = items.filter(\.isProblem)
                let problems = r.problemCount(in: a)
                let general = r.general(a)
                let empty = items.isEmpty && general.isEmpty
                let worst = (bad.compactMap(\.severity) + general.map(\.severity)).min()
                let fixable = bad.filter { i in i.actions.contains { $0.kind == .fix && $0.bulk } }.count
                let updates = items.filter { $0.update != nil }.count
                CategoryCard(symbol: AgentStyle.icon(a), color: AgentStyle.tint(a), title: AgentStyle.title(a),
                             status: empty ? tr("No items to check") : problems == 0 && updates > 0 ? tr("%1$@ updates available", String(updates)) : problems == 0 && items.isEmpty ? tr("Notes available") : problems == 0 && a == .mcp ? tr("%1$@ configuration entries; connection unchecked", String(items.count)) : problems == 0 ? tr("%1$@ checked, all fine", String(items.count))
                                 : fixable > 0 ? tr("%1$@ fixable in one click", String(fixable)) : tr("needs your decision"),
                             statusColor: empty || (problems == 0 && (items.isEmpty || a == .mcp)) ? Theme.textSecondary : problems == 0 && updates > 0 ? Theme.accent : problems == 0 ? Theme.good : (worst == .error ? Theme.danger : Theme.caution),
                             count: problems) { open(a) }
            }
        }
    }
}

/// A status ring with a symbol, the verdict beside it and the page's actions on the right: one
/// panel instead of a centered poster, so the cards below stay in view.
private struct DiagnosticsHero<Actions: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String?
    var progress: Double? = nil
    var spinning = false
    @ViewBuilder let actions: () -> Actions
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            ZStack {
                Circle().fill(color.opacity(0.12))
                Circle().stroke(Color.white.opacity(0.07), lineWidth: 3)
                if let progress {
                    Circle().trim(from: 0, to: max(0.02, progress))
                        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                        .animation(Theme.standard.unlessReduced(reduceMotion), value: progress)
                } else if spinning {
                    Circle().trim(from: 0, to: 0.25)
                        .stroke(AngularGradient(colors: [color.opacity(0), color], center: .center), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(turning ? 360 : 0))
                        .animation(reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false), value: turning)
                } else {
                    Circle().stroke(color.opacity(0.8), lineWidth: 3)
                }
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(color)
            }
            .frame(width: 60, height: 60)
            .onAppear { DispatchQueue.main.async { turning = true } }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).font(Theme.pageTitle).foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText()).fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.m)
            actions()
        }
        .padding(Theme.Space.l + 4)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(color.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(color.opacity(0.2)))
        .animation(Theme.gentle.unlessReduced(reduceMotion), value: title)
        .accessibilityElement(children: .contain)
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
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header(problems)
                DiagnosticScanControl(scanner: scanner)
                if problems.isEmpty && !notes.contains(where: { $0.severity == .error || $0.severity == .warning }) {
                    let checking = scanner.scanning && scanner.report == nil
                    let empty = items.isEmpty
                    if checking {
                        SkeletonList(rows: 4)
                    } else {
                        HStack(spacing: Theme.Space.m) {
                            Image(systemName: empty ? "magnifyingglass" : area == .mcp ? "info.circle" : "checkmark.seal.fill")
                                .font(.system(size: 18)).foregroundStyle(empty || area == .mcp ? Theme.textTertiary : Theme.good)
                            Text(scanner.stopped && scanner.report == nil ? tr("Check stopped") : empty && !query.isEmpty ? tr("No matching items") : empty ? tr("No items to check") : area == .mcp ? tr("No configuration problems detected. Connection and tool behavior are not verified by this scan.") : tr("Nothing to fix here."))
                                .font(Theme.rowTitle).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(Theme.Space.l).frame(maxWidth: .infinity, alignment: .leading).glass()
                    }
                }
                ForEach(Array(notes.enumerated()), id: \.offset) { _, finding in
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Image(systemName: finding.severity == .error ? "xmark.octagon" : finding.severity == .warning ? "exclamationmark.triangle" : "info.circle")
                            .font(.system(size: 14)).foregroundStyle(severityColor(finding.severity)).frame(width: 18)
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(finding.subject).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                            Text(finding.message).font(Theme.secondary).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let fix = finding.fix { Text(fix).font(Theme.secondary).foregroundStyle(Theme.textTertiary).textSelection(.enabled) }
                            if let source = finding.source { Text(source).font(Theme.mono).foregroundStyle(Theme.textTertiary).textSelection(.enabled) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.l).glass()
                }
                if !problems.isEmpty {
                    SectionHeader(title: problems.count == 1 ? tr("1 problem found") : tr("%1$@ problems", String(problems.count)))
                    VStack(spacing: Theme.Space.s) { ForEach(problems) { ProblemCard(scanner: scanner, item: $0) } }
                }
                if !rest.isEmpty { healthy(rest) }
                if area == .skills || area == .mcp {
                    // Measurements come after what needs fixing: they explain, they do not ask for action.
                    SectionHeader(title: tr("Analysis")).padding(.top, Theme.Space.s)
                    if area == .skills || area == .mcp { tools }
                    if area == .skills, let report = scanner.report { SkillContextCard(items: report.items.filter { $0.area == .skills }) }
                    if area == .mcp {
                        MCPDefinitionSummaryPanel(store: scanner.mcpDefinitions, items: scanner.report?.items ?? [], encoding: scanner.tokenEncoding, busy: scanner.mcpBatchRunning)
                    }
                    if area == .mcp || area == .skills { ToolUsagePanel(model: scanner.toolUsage, kind: area == .mcp ? "mcp" : "skill", encoding: scanner.tokenEncoding) }
                    if area == .mcp || area == .skills { TaskComparisonPanel(model: scanner.taskComparison, kind: area == .mcp ? "mcp" : "skill") }
                }
                if !scanner.history.isEmpty { AgentActivity(scanner: scanner) }
            }
            .frame(maxWidth: Theme.pageWidth, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pageTop).padding(.bottom, Theme.Space.xxl)
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

    /// Token encoding, the Skill project and the MCP batch check: one toolbar panel.
    var tools: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text(tr("Text encoding")).font(Theme.label).foregroundStyle(Theme.textTertiary)
                ThermoTabs(selection: Binding(get: { scanner.tokenEncoding }, set: { scanner.selectEncoding($0) }),
                           options: [(TextEncoding.heuristic, tr("Heuristic")), (.cl100k, "cl100k_base"), (.o200k, "o200k_base")],
                           size: .small, label: tr("Text encoding"))
                    .disabled(scanner.busy)
                InfoButton(text: tr("Reference encodings count ordinary text locally, not a model’s full prompt or invoice. No model name is inferred."))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
            if area == .skills {
                InspectorDivider(inset: 0)
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Text(scanner.project?.path ?? tr("User Skill context only")).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    if scanner.project != nil {
                        Button(tr("User scope")) { scanner.selectProject(nil) }.buttonStyle(PillButtonStyle()).controlSize(.small).disabled(scanner.busy)
                    }
                    Button(tr("Choose Skill project…")) { chooseProject() }.buttonStyle(PillButtonStyle()).controlSize(.small).disabled(scanner.busy)
                }
                .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
            }
            if area == .mcp {
                InspectorDivider(inset: 0)
                MCPBatchInspectButton(model: scanner.mcpBatch, store: scanner.mcpDefinitions, items: scanner.report?.items ?? [], encoding: scanner.tokenEncoding, busy: scanner.busy)
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
            }
        }
        .glass()
    }

    func healthy(_ rest: [AgentItem]) -> some View {
        let open = showHealthy || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Theme.standard.unlessReduced(reduceMotion)) { showHealthy.toggle() } } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: area == .mcp ? "list.bullet" : "checkmark.circle.fill")
                        .foregroundStyle(area == .mcp ? Theme.textTertiary : Theme.good)
                    Text(area == .mcp ? tr("%1$@ configuration entries", String(rest.count)) : tr("%1$@ without detected problems", String(rest.count)))
                        .font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    DisclosureChevron(expanded: open)
                }
                .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m).contentShape(Rectangle())
                .hoverHighlight()
            }
            .buttonStyle(.plain)
            if open {
                ForEach(rest) { i in
                    InspectorDivider(inset: 44)
                    HealthyRow(scanner: scanner, item: i).padding(.horizontal, Theme.Space.l)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glass()
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    @MainActor
    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = tr("Choose a project for Skill inspection")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = scanner.project ?? FileManager.default.homeDirectoryForCurrentUser
        panel.begin { response in
            if response == .OK, let url = panel.url { scanner.selectProject(url) }
        }
    }

    func header(_ problems: [AgentItem]) -> some View {
        let fixes = problems.compactMap { i in i.actions.first { $0.kind == .fix && $0.bulk }.map { (i, $0) } }
        return PageHeader(title: AgentStyle.title(area), subtitle: AgentStyle.explanation(area)) {
            HStack(spacing: Theme.Space.s) {
                SearchField(text: $search, width: 180)
                if fixes.count > 1 {
                    Button(tr("Fix %1$@", String(fixes.count))) { confirmingFixes = fixes }
                        .buttonStyle(PillButtonStyle(prominent: true)).disabled(scanner.busy)
                }
            }
        }
    }
}

func severityColor(_ s: Severity?) -> Color {
    switch s {
    case .error?: return Theme.danger
    case .warning?: return Theme.caution
    default: return Theme.textSecondary
    }
}

struct DiagnosticScanControl: View {
    @ObservedObject var scanner: AgentScanner
    var body: some View {
        if scanner.scanning {
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text(scanner.stopRequested ? tr("Stopping check…") : tr("Checking your AI agents…"))
                    .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(tr("Stop checking")) { scanner.stopScan() }.buttonStyle(PillButtonStyle()).controlSize(.small)
                    .disabled(scanner.stopRequested)
            }
        } else if scanner.stopped {
            HStack(spacing: Theme.Space.s) {
                Text(tr(scanner.report == nil ? "No complete results were produced. Check again when ready." : "Previous complete results are kept. Check again to refresh them."))
                    .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(tr("Check Again")) { scanner.scan() }.buttonStyle(PillButtonStyle()).controlSize(.small).disabled(scanner.busy)
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

    var findings: [Finding] { scanner.report?.findings(for: item) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                ZStack {
                    Circle().fill(severityColor(item.severity).opacity(0.16)).frame(width: 26, height: 26)
                    Image(systemName: item.severity == .error ? "xmark" : "exclamationmark")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(severityColor(item.severity))
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.s) {
                        Text(item.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                        if item.agent != "system" { StatusTag(text: item.agent) }
                    }
                    if let f = findings.first {
                        Text(f.message).font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                actions
            }
            if let last = scanner.lastResult, last.item == item.id {
                Label(last.result.ok ? tr("%1$@: done", last.action) : tr("%1$@: failed", last.action),
                      systemImage: last.result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(Theme.caption.weight(.medium)).foregroundStyle(last.result.ok ? Theme.good : Theme.danger).padding(.leading, 38)
            }
            Button { withAnimation(Theme.standard.unlessReduced(reduceMotion)) { details.toggle() } } label: {
                HStack(spacing: 2) {
                    Text(tr("Details")).font(Theme.caption.weight(.medium))
                    DisclosureChevron(expanded: details).scaleEffect(0.85)
                }
                .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain).padding(.leading, 38)
            if details {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(Array(findings.enumerated()), id: \.offset) { i, f in
                        if i > 0 { Text(f.message).font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
                        if let fix = f.fix {
                            Text(tr("Suggestion: %1$@", fix)).font(Theme.secondary).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let source = f.source, source != item.source {
                            Text(source).font(Theme.mono).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
                        }
                    }
                    Text(item.detail).font(Theme.mono).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                        .padding(Theme.Space.s).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Color.black.opacity(0.25)))
                    if let footprint = item.skillFootprint {
                        Text(footprint.summary).font(Theme.mono).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                    if let src = item.source {
                        HStack {
                            Text(src).font(Theme.mono).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            let path = (src as NSString).expandingTildeInPath
                            if FileManager.default.fileExists(atPath: path) {
                                Button(tr("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                    .buttonStyle(.plain).font(Theme.caption.weight(.medium)).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                .padding(.leading, 38)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(Theme.Space.l)
        .glass()
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(severityColor(item.severity).opacity(0.8)).frame(width: 3).padding(.vertical, Theme.Space.m)
        }
        .sheet(item: $confirming) { a in
            ConfirmAction(action: a, item: item) { confirming = nil; scanner.perform(a, on: item) } cancel: { confirming = nil }
        }
    }

    @ViewBuilder var actions: some View {
        let primary = item.primaryDiagnosticAction
        let others = item.actions.filter { $0.id != primary?.id }
        HStack(spacing: Theme.Space.s) {
            if item.area == .mcp { MCPInspectButton(item: item, busy: scanner.busy, encoding: scanner.tokenEncoding, store: scanner.mcpDefinitions) }
            if let p = primary {
                Button { confirming = p } label: {
                    HStack(spacing: 5) {
                        if scanner.running == p.id { ProgressView().controlSize(.mini).tint(.white) }
                        Text(p.title)
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: p.kind == .fix && p.bulk)).controlSize(.small)
                .disabled(scanner.busy)
            }
            if !others.isEmpty { MoreMenu(actions: others, disabled: scanner.busy) { confirming = $0 } }
        }
    }
}

/// The "…" next to a row's main action, for the rest of its actions.
private struct MoreMenu: View {
    let actions: [Action]
    let disabled: Bool
    let pick: (Action) -> Void
    var body: some View {
        Menu {
            ForEach(actions) { a in Button(a.title, role: a.kind == .uninstall ? .destructive : nil) { pick(a) } }
        } label: { Image(systemName: "ellipsis").foregroundStyle(Theme.textSecondary) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 26, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.075)))
            .disabled(disabled)
            .accessibilityLabel(tr("More actions"))
    }
}

/// A healthy item: name, what it is, and its actions in a menu (uninstall, disable…).
private struct HealthyRow: View {
    @ObservedObject var scanner: AgentScanner
    let item: AgentItem
    @State private var confirming: Action?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: !item.enabled ? "minus.circle" : item.area == .mcp ? "questionmark.circle" : item.severity == .info ? "info.circle" : "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(item.area == .mcp ? Theme.textTertiary : item.enabled ? Theme.good.opacity(0.85) : Theme.textTertiary)
                .frame(width: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Text(item.name).font(Theme.body).foregroundStyle(item.enabled ? Theme.textPrimary : Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                    if item.agent != "system" { StatusTag(text: item.agent) }
                    if !item.enabled { Text(tr("off")).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                }
                Text(item.detail).font(Theme.mono).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                if let footprint = item.skillFootprint {
                    Text(footprint.summary).font(Theme.mono).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
                }
                let evidence = scanner.report?.findings(for: item) ?? []
                if !evidence.isEmpty {
                    DisclosureGroup(tr("Details")) {
                        ForEach(Array(evidence.enumerated()), id: \.offset) { _, finding in
                            Text(finding.message).font(Theme.caption).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                            if let source = finding.source { Text(source).font(Theme.mono).foregroundStyle(Theme.textTertiary).textSelection(.enabled) }
                        }
                    }.font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            if item.area == .mcp { MCPInspectButton(item: item, busy: scanner.busy, encoding: scanner.tokenEncoding, store: scanner.mcpDefinitions) }
            if !item.actions.isEmpty { MoreMenu(actions: item.actions, disabled: scanner.busy) { confirming = $0 } }
        }
        .padding(.vertical, Theme.Space.s + 2)
        .sheet(item: $confirming) { a in
            ConfirmAction(action: a, item: item) { confirming = nil; scanner.perform(a, on: item) } cancel: { confirming = nil }
        }
    }
}

/// Results remain accessible even when a repaired item disappears from the inventory.
struct AgentActivity: View {
    @ObservedObject var scanner: AgentScanner
    var body: some View {
        DisclosureGroup {
            VStack(spacing: Theme.Space.s) { ForEach(scanner.history) { AgentOutcomeRow(entry: $0) } }
                .padding(.top, Theme.Space.s)
        } label: {
            Text(tr("Recent actions (this session)")).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
        }
        .padding(Theme.Space.l).glass().frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AgentOutcomeRow: View {
    let entry: AgentScanner.LastResult
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entry.result.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(Theme.mono).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(entry.result.backups, id: \.self) { path in
                    Text(tr("Backup: %1$@", path)).font(Theme.mono).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.top, 8)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: entry.result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(entry.result.ok ? Theme.good : Theme.caution)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                    Text(entry.action + " · " + (entry.result.ok ? tr("Action completed") : tr("Action failed")))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Text(entry.time, style: .time).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
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
