import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

enum DiskPage: Hashable {
    case home, overview
    case category(CleanCategory)

    /// `--page` values for `Thermo --disk`: home, overview, or a category id (ai-sessions, projects…).
    init?(argument: String) {
        switch argument {
        case "home": self = .home
        case "overview": self = .overview
        default:
            guard let c = CleanCategory(rawValue: argument) else { return nil }
            self = .category(c)
        }
    }
}

extension DiskModel {
    /// One line per item for the confirmation: how it goes, size, name, paths.
    var planLines: [String] {
        selectedItems.flatMap { i -> [String] in
            let native=i.runsNativeClean(.auto) ? i.native : nil
            let deleted=i.paths.filter { native?.owns($0) != true }
            let how=native != nil ? tr("tool clean") : !(i.commands ?? []).isEmpty ? tr("permanent tool removal") : !RemovalMode.auto.trashes(i) ? tr("delete") : tr("trash")
            let paths=trCount(deleted.count,"%1$@ path","%1$@ paths")
            var lines=["\(how) · \(ByteFormat.string(i.bytes)) · \(i.title)" + (!deleted.isEmpty ? " (\(paths))" : "")]
            if let native {
                for run in native.runs {
                    lines.append("    " + tr("Tool-managed locations") + ": " + FSPath.tilde(run.folder))
                    lines.append("    " + tr("runs `%1$@`", run.commandLine))
                }
            } else if let fallback=i.native?.fallback { lines.append("    " + fallback) }
            lines += deleted.map { "    " + FSPath.tilde($0) }
            lines += (i.commandScope ?? []).map { "    " + tr("Tool-managed locations") + ": " + FSPath.tilde($0) }
            lines += (i.commands ?? []).map { "    " + $0.joined(separator: " ") }
            return lines
        }
    }

    var confirmSummary: String {
        let items = selectedItems
        let trash = items.filter { RemovalMode.auto.trashes($0) && ($0.commands ?? []).isEmpty }
        let toolItems = items.filter { !($0.commands ?? []).isEmpty }
        var parts = [trCount(items.count, "%1$@ item.", "%1$@ items.")]
        let deletesPaths=items.contains { item in
            guard !RemovalMode.auto.trashes(item) else { return false }
            let native=item.runsNativeClean(.auto) ? item.native : nil
            return item.paths.contains { native?.owns($0) != true }
        }
        if deletesPaths { parts.append(tr("Caches and build output are deleted.")) }
        if !trash.isEmpty {
            parts.append(trCount(trash.count, "%1$@ item with your data (sessions, models, worktrees) goes to the Trash.",
                                 "%1$@ items with your data (sessions, models, worktrees) go to the Trash."))
        }
        if !toolItems.isEmpty { parts.append(tr("Tool-managed items are removed permanently; they do not go to the Trash.")) }
        if items.contains(where: { $0.runsNativeClean(.auto) }) {
            parts.append(tr("Tool cache cleanup is permanent and does not use the Trash. Required files may remain."))
        }
        return parts.joined(separator: " ")
    }

    var confirmationIsDestructive: Bool {
        selectedItems.contains { !($0.commands ?? []).isEmpty || (!RemovalMode.auto.trashes($0) && !$0.paths.isEmpty) }
    }

    var safeItems: [CleanItem] { (report?.items ?? []).filter(\.automaticallySelected) }
    var safeBytes: Int64 { safeItems.reduce(0) { $0 + $1.bytes } }

    func selectSafe() { selected = Set(safeItems.map(\.id)) }
}

/// Shared by the main window and the opt-in native UI acceptance harness.
struct DiskCleanConfirmation: View {
    let review: DiskCleanupReview
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        ConfirmSheet(title: tr("Clean %1$@?", ByteFormat.string(review.bytes)), summary: review.summary,
                     destructive: review.destructive, heading: tr("What will be removed"),
                     lines: review.lines,
                     footnote: tr("Removed items are listed in ~/Library/Logs/Thermo/clean.log. Targets are checked again before each operation; checks do not seal all folder contents."),
                     confirmTitle: tr("Clean"), confirm: confirm, cancel: cancel)
    }
}

struct DiskProtectionNotice: View {
    @ObservedObject var model: DiskModel
    var body: some View {
        if let notice = model.protectionNotice {
            HStack(alignment: .top) {
                Label(notice, systemImage: "shield.checkered").fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.protectionUndo != nil {
                    Button(tr("Undo")) { model.undoProtection() }
                        .disabled(model.cleaning || model.scanning).buttonStyle(PillButtonStyle())
                }
            }.font(Theme.body).foregroundStyle(Theme.textPrimary).padding(Theme.Space.m + 2).glass()
        }
    }
}

/// Keep execution feedback visible on the page from which cleanup was started.
struct DiskCleanupResult: View {
    @ObservedObject var model: DiskModel
    var body: some View {
        if let result = model.lastResult {
            VStack(alignment: .leading, spacing: 8) {
                Text(result).font(Theme.body).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Button(tr("Show log")) { model.openLog() }.buttonStyle(PillButtonStyle()).controlSize(.small)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.m + 2)
                .glass()
        }
    }
}

enum DiskStyle {
    /// "1.2 GB" or "4 KB · 1.5 GB waiting for apps to quit": what is held back is said, not hidden.
    static func categoryStatus(_ r: ScanReport, _ c: CleanCategory) -> String {
        let waiting = r.blockedBytes(in: c)
        let ready = ByteFormat.string(r.bytes(in: c))
        return waiting > 0 ? tr("%1$@ · %2$@ held back", ready, ByteFormat.string(waiting)) : ready
    }

    static func icon(_ c: CleanCategory) -> String {
        switch c {
        case .aiSessions: return "bubble.left.and.text.bubble.right.fill"
        case .agentWorktrees: return "arrow.triangle.branch"
        case .aiModels: return "cpu.fill"
        case .aiCaches: return "sparkles"
        case .devCaches: return "hammer.fill"
        case .xcode: return "swift"
        case .projects: return "folder.fill"
        case .browsers: return "globe"
        case .system: return "gearshape.fill"
        }
    }

    static func tint(_ c: CleanCategory) -> Color {
        switch c {
        case .aiSessions: return Color(red: 0.62, green: 0.42, blue: 1.0)
        case .agentWorktrees: return Color(red: 0.45, green: 0.72, blue: 1.0)
        case .aiModels: return Color(red: 0.95, green: 0.42, blue: 0.75)
        case .aiCaches: return Color(red: 0.45, green: 0.5, blue: 1.0)
        case .devCaches: return Color(red: 1.0, green: 0.62, blue: 0.25)
        case .xcode: return Color(red: 0.25, green: 0.62, blue: 1.0)
        case .projects: return Color(red: 0.3, green: 0.8, blue: 0.6)
        case .browsers: return Color(red: 0.25, green: 0.78, blue: 0.9)
        case .system: return Color(red: 0.6, green: 0.65, blue: 0.75)
        }
    }

    static func safety(_ s: Safety, info: Bool) -> (String, Color) {
        if info { return (tr("info"), Theme.accent) }
        switch s {
        case .safe: return (tr("safe"), Theme.good)
        case .review: return (tr("review"), Theme.caution)
        case .risky: return (tr("risky"), Theme.danger)
        }
    }
}

// MARK: - Home

struct DiskHome: View {
    @ObservedObject var model: DiskModel
    let open: (CleanCategory) -> Void
    let clean: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                hero.padding(.top, 48)
                CleanupProtectionsButton(disk: model)
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let r = model.report, !r.items.isEmpty {
                        SectionHeader(title: tr("Disk Cleanup")) {
                            if let days = r.claudeCleanupDays {
                                InfoButton(text: tr("Claude Code deletes its own sessions after %1$@ days (cleanupPeriodDays).", String(days)))
                            }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                            ForEach(CleanCategory.allCases, id: \.self) { c in
                                let inCat = r.items.filter { $0.category == c && $0.cleanable }
                                let waiting = r.blockedBytes(in: c)
                                // A category whose items all wait for an app to quit still shows, with that said.
                                if !inCat.isEmpty || waiting > 0 {
                                    CategoryCard(symbol: DiskStyle.icon(c), color: DiskStyle.tint(c), title: c.title,
                                                 status: DiskStyle.categoryStatus(r, c), statusColor: Theme.textSecondary,
                                                 count: inCat.count) { open(c) }
                                }
                            }
                        }
                    }
                    if model.report?.cancelled == true {
                        Label(tr("Scan stopped. These are partial results."), systemImage: "pause.circle")
                            .font(Theme.body).foregroundStyle(Theme.caution)
                    }
                    if model.loadingSaved {
                        NoticeBanner(text: tr("Loading saved results…"), busy: true)
                    }
                    if let why = model.error ?? model.report?.whitelistError {
                        Label(why, systemImage: "exclamationmark.triangle").font(Theme.body).foregroundStyle(Theme.danger)
                    }
                    if let denied = model.report?.denied, !denied.isEmpty {
                        HStack(spacing: Theme.Space.m) {
                            Label(tr("%1$@ locations could not be read. Results may be incomplete.", String(denied.count)), systemImage: "lock.shield")
                                .font(Theme.body).foregroundStyle(Theme.caution)
                            Spacer(minLength: Theme.Space.s)
                            Button(tr("Open Full Disk Access")) { model.openFullDiskAccess() }.buttonStyle(PillButtonStyle()).controlSize(.small)
                        }
                        .padding(Theme.Space.m + 2).glass()
                    }
                    DiskProtectionNotice(model: model)
                    DiskCleanupResult(model: model)
                    if let report = model.report { scanInsights(report) }
                }
                .frame(maxWidth: Theme.pageWidth)
                .padding(.horizontal, Theme.pagePadding)
            }
            .padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: .infinity)
        }
    }

    /// Context next to the scan: what sits outside folder totals, and what grew since last time.
    @ViewBuilder func scanInsights(_ report: ScanReport) -> some View {
        if report.spaceContext != nil || report.changesSince != nil {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                if let c = report.spaceContext {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack(spacing: Theme.Space.xs) {
                            Text(tr("Outside folder totals")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary)
                            InfoButton(text: tr("These share the APFS container and must not be added to folder totals. No process attribution is inferred."))
                        }
                        Text(tr("Swap files: %1$@ · runtime images: %2$@ · purgeable estimate: %3$@",
                                c.swapFiles.map(ByteFormat.string) ?? "—", c.simulatorRuntimes.map(ByteFormat.string) ?? "—",
                                c.purgeable.map(ByteFormat.string) ?? "—"))
                            .font(Theme.secondary.monospacedDigit()).foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(Theme.Space.m + 2).glass()
                }
                if let since = report.changesSince, let growth = report.growth {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(tr("Changes since %1$@ (same scan scope)", AgeFormat.string(since))).font(Theme.sectionTitle)
                            .foregroundStyle(Theme.textSecondary)
                        ForEach(Array(growth.prefix(5)), id: \.id) { change in
                            HStack(spacing: Theme.Space.s) {
                                Text(change.title).font(Theme.secondary).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer(minLength: Theme.Space.s)
                                Text((change.changeBytes > 0 ? "+" : "−") + ByteFormat.string(abs(change.changeBytes)))
                                    .font(Theme.secondary.monospacedDigit())
                                    .foregroundStyle(change.changeBytes > 0 ? Theme.caution : Theme.good)
                            }
                        }
                        if growth.isEmpty { Text(tr("No measured size changes")).font(Theme.secondary).foregroundStyle(Theme.textTertiary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(Theme.Space.m + 2).glass()
                }
            }
        }
    }

    /// The page's one figure: how much can be freed, in a ring that becomes progress while working.
    @ViewBuilder var hero: some View {
        if model.cleaning {
            HeroStatus(symbol: "trash", color: Theme.caution, title: tr("Cleaning…"),
                       subtitle: model.cleaningStep,
                       progress: Double(model.cleaningDone) / Double(max(1, model.cleaningTotal)))
        } else if model.scanning {
            VStack(spacing: Theme.Space.l) {
                HeroStatus(symbol: "magnifyingglass", color: Theme.accent,
                           title: model.report.map { tr("%1$@ found so far", ByteFormat.string($0.totalBytes)) } ?? tr("Looking for space you can free…"),
                           subtitle: model.progress, spinning: true)
                Button(tr("Stop")) { model.stop() }.buttonStyle(PillButtonStyle()).disabled(model.stopping)
            }
        } else if let r = model.report {
            let summary = DiskScanSummary(r, safeBytes: model.safeBytes)
            VStack(spacing: Theme.Space.l) {
                HeroStatus(symbol: summary.symbol, color: summary.color,
                           title: summary.title, subtitle: summary.subtitle)
                BigRoundButton(title: tr("Clean"), color: Theme.accent, busy: model.cleaning) {
                    model.selectSafe()
                    clean()
                }
                .disabled(model.safeItems.isEmpty)
                HStack(spacing: Theme.Space.m) {
                    ThermoTabs(selection: $model.scope, options: DiskModel.Scope.allCases.map { ($0, $0.label) }, size: .small,
                               label: tr("Scan scope"))
                    Button(tr("Scan again")) { model.scan() }.buttonStyle(PillButtonStyle()).controlSize(.small)
                }
            }
        } else {
            VStack(spacing: Theme.Space.l) {
                HeroStatus(symbol: "internaldrive", color: Theme.accent,
                           title: tr("Find space you can free"),
                           subtitle: model.loadingSaved ? tr("Loading saved results…") : tr("Old AI sessions, model downloads, agent leftovers, build output and caches. Nothing is removed until you choose."), spinning: model.loadingSaved)
                BigRoundButton(title: tr("Scan"), color: Theme.accent) { model.scan() }
            }
        }
    }
}

// MARK: - Category page

struct DiskCategoryPage: View {
    @ObservedObject var model: DiskModel
    let category: CleanCategory
    let clean: () -> Void
    @State private var search = ""
    @State private var open: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var items: [CleanItem] {
        if category == .aiSessions && model.sessionRetentionDays == nil { return [] }
        if category == .aiSessions && model.scopeNeedsRefresh(category: category) { return [] }
        var list = (model.report?.items ?? []).filter { $0.category == category }
        if !search.isEmpty {
            let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
            list = list.filter { ($0.title + " " + $0.detail + " " + ($0.note ?? "") + " " + $0.paths.joined(separator: " "))
                .localizedCaseInsensitiveContains(q) }
        }
        return list.sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pageTop).padding(.bottom, Theme.Space.l)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if category == .aiSessions {
                    HStack(spacing: Theme.Space.s) {
                        Text(tr("Conversation retention")).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                        Picker(tr("Conversation retention"), selection: Binding(get: { model.sessionRetentionDays ?? -1 }, set: { model.setSessionRetentionDays($0 < 0 ? nil : $0) })) {
                            Text(tr("Keep all conversations")).tag(-1)
                            ForEach(ConversationRetentionPreferences.choices, id: \.self) { days in
                                Text(tr("List conversations older than %1$@ days", String(days))).tag(days)
                            }
                        }.labelsHidden().frame(maxWidth: 280).controlSize(.small)
                        if model.remembersSessionRetention {
                            InfoButton(text: tr("This choice is remembered on this Mac. Conversations are never selected automatically."))
                        }
                        Spacer()
                    }
                    .disabled(model.scanning || model.cleaning)
                }
                if model.loadingSaved { NoticeBanner(text: tr("Loading saved results…"), busy: true) }
                if let why = model.error ?? model.report?.whitelistError {
                    Label(why, systemImage: "exclamationmark.triangle").font(Theme.body).foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.report?.cancelled == true {
                    Label(tr("Scan stopped. These are partial results."), systemImage: "pause.circle")
                        .font(Theme.body).foregroundStyle(Theme.caution).frame(maxWidth: .infinity, alignment: .leading)
                } else if model.report?.resultState == .incomplete {
                    Label(tr("Scan incomplete"), systemImage: "exclamationmark.triangle")
                        .font(Theme.body).foregroundStyle(Theme.caution).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, category == .aiSessions || model.loadingSaved || model.error != nil || model.report?.whitelistError != nil
                     || model.report?.cancelled == true || model.report?.resultState == .incomplete ? Theme.Space.m : 0)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    DiskProtectionNotice(model: model)
                    DiskCleanupResult(model: model)
                    let list = items
                    let groups = Dictionary(grouping: list, by: { $0.group ?? "" })
                    if category == .projects && groups.count > 1 {
                        // One block per project folder: its build outputs together, last use shown once.
                        ForEach(groups.keys.sorted { (groups[$0] ?? []).reduce(0) { $0 + $1.bytes } > (groups[$1] ?? []).reduce(0) { $0 + $1.bytes } }, id: \.self) { g in
                            let rows = groups[g] ?? []
                            VStack(alignment: .leading, spacing: Theme.Space.s) {
                                HStack(spacing: Theme.Space.s) {
                                    selectAll(rows, title: FSPath.tilde(g))
                                    if let used = rows.compactMap(\.lastUsed).max() {
                                        Text(tr("last used %1$@", AgeFormat.string(used))).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                    }
                                    Spacer()
                                    Text(ByteFormat.string(rows.reduce(0) { $0 + $1.bytes })).font(Theme.figure(.row, weight: .medium))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .padding(.horizontal, 2).padding(.top, Theme.Space.xs)
                                RowList(items: rows, inset: 50) { card($0) }
                            }
                        }
                    } else if !list.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            HStack {
                                selectAll(list, title: category.title)
                                Spacer()
                                Text(trCount(list.count, "%1$@ item", "%1$@ items")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 2)
                            RowList(items: list, inset: 50) { card($0) }
                        }
                    }
                    if list.isEmpty { emptyState }
                }
                .padding(.horizontal, Theme.pagePadding).padding(.bottom, Theme.Space.xl)
            }
            footer
        }
        .onAppear { model.loadSaved(category: category) }
    }

    /// What the list area says when there is nothing to tick.
    @ViewBuilder var emptyState: some View {
        if category == .aiSessions && model.sessionRetentionDays == nil {
            EmptyState(symbol: "bubble.left.and.text.bubble.right", title: tr("All conversations are kept. Choose an age, then scan to review old sessions."))
        } else if model.scanning {
            SkeletonList(rows: 5)
        } else if model.report == nil || model.scopeNeedsRefresh(category: category) {
            VStack(spacing: Theme.Space.m) {
                EmptyState(symbol: "magnifyingglass", title: tr("Find space you can free")).padding(.bottom, -36)
                Button(tr("Scan")) { model.scan(category: category) }.buttonStyle(PillButtonStyle(prominent: true))
            }.frame(maxWidth: .infinity)
        } else if model.report?.cancelled == true {
            VStack(spacing: Theme.Space.m) {
                EmptyState(symbol: "pause.circle", title: tr("Scan stopped. These are partial results.")).padding(.bottom, -36)
                Button(tr("Scan again")) { model.scan(category: category) }.buttonStyle(PillButtonStyle())
            }.frame(maxWidth: .infinity)
        } else if model.report?.resultState == .incomplete {
            VStack(spacing: Theme.Space.m) {
                EmptyState(symbol: "exclamationmark.triangle", title: tr("Scan incomplete"),
                           detail: tr("Some locations or sizes could not be checked. Review the available results or scan again.")).padding(.bottom, -36)
                Button(tr("Scan again")) { model.scan(category: category) }.buttonStyle(PillButtonStyle())
            }.frame(maxWidth: .infinity)
        } else {
            EmptyState(symbol: "checkmark.circle",
                       title: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tr("No matching items") : category == .aiSessions ? tr("No conversations are eligible. Recent, active or unverified data are kept.") : tr("Nothing here."))
        }
    }

    /// Ticks every item of `rows` that can be cleaned, or clears them all when they already are.
    func selectAll(_ rows: [CleanItem], title: String? = nil) -> some View {
        let pickable = rows.filter(\.cleanable)
        return SelectAllButton(title: title, available: pickable.count,
                               selected: pickable.filter { model.selected.contains($0.id) }.count,
                               selectAll: {
                                   for i in pickable where !model.selected.contains(i.id) { model.selected.insert(i.id) }
                                   for i in pickable { model.excluded[i.id] = nil }
                               },
                               clear: { model.selected.subtract(pickable.map(\.id)) })
            .disabled(model.cleaning || model.scanning)
    }

    var header: some View {
        let selected = model.selectedItems.filter { $0.category == category }
        return PageHeader(title: category.title,
                          subtitle: tr("%1$@ · %2$@ selected", model.report.map { DiskStyle.categoryStatus($0, category) } ?? ByteFormat.string(0),
                                       ByteFormat.string(selected.reduce(0) { $0 + $1.bytes }))) {
            HStack(spacing: Theme.Space.s) {
                CleanupProtectionsButton(disk: model, compact: true)
                SearchField(text: $search, width: 200)
            }
        }
    }

    func toggleOpen(_ id: String) {
        withAnimation(Theme.standard.unlessReduced(reduceMotion)) {
            if open.contains(id) { open.remove(id) } else { open.insert(id) }
        }
    }

    func card(_ i: CleanItem) -> some View {
        let ticked = model.selected.contains(i.id)
        let expanded = open.contains(i.id)
        let (tag, tagColor) = DiskStyle.safety(i.safety, info: i.paths.isEmpty && (i.commands ?? []).isEmpty)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                SelectToggle(selected: ticked, locked: !i.cleanable, label: tr("Select %1$@", i.title)) { model.toggle(i) }
                    .disabled(model.cleaning)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(i.title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1).help(i.title)
                        StatusTag(text: tag, color: tagColor)
                    }
                    Text(i.blocked ?? [i.detail, i.lastUsed.map { AgeFormat.string($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.caption).foregroundStyle(i.blocked != nil ? Theme.caution : Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: Theme.Space.m)
                Text(ByteFormat.string(model.selectedItems.first { $0.id == i.id }?.bytes ?? i.bytes))
                    .font(Theme.figure(.row)).foregroundStyle(Theme.textPrimary).contentTransition(.numericText())
                Button { toggleOpen(i.id) } label: { DisclosureChevron(expanded: expanded) }
                    .buttonStyle(.plain).accessibilityLabel(tr("Details for %1$@", i.title))
                    .accessibilityValue(expanded ? tr("Expanded") : tr("Collapsed"))
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleOpen(i.id) }
            if expanded {
                DiskItemDetail(model: model, item: i)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.s + 2)
        .background(ticked ? Theme.accent.opacity(0.07) : .clear)
        .hoverHighlight()
        .animation(Theme.quick.unlessReduced(reduceMotion), value: ticked)
        .contextMenu {
            Button(tr("Show in Finder")) { model.reveal(i) }.disabled(i.paths.isEmpty)
            Button(tr("Always keep")) { model.alwaysKeep(i) }
                .disabled((i.paths.isEmpty && (i.commandScope ?? []).isEmpty) || i.blocked == tr(Whitelist.reason) || model.cleaning || model.scanning)
            Button(tr("Copy ID")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(i.id, forType: .string) }
        }
    }

    var footer: some View {
        ActionBar {
            if model.scanning {
                ProgressView().controlSize(.small)
                Text(model.progress).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                Button(model.stopping ? tr("stopping…") : tr("Stop")) { model.stop() }
                    .buttonStyle(PillButtonStyle()).disabled(model.stopping)
            } else {
                selectAll(items)
                Button(tr("Safe")) {
                    let ids = (model.report?.items ?? []).filter { $0.category == category && $0.automaticallySelected }.map(\.id)
                    model.selected.formUnion(ids)
                }
                .buttonStyle(PillButtonStyle()).controlSize(.small)
                .help(tr("Safe: this is regenerated automatically (caches, logs, build output). It is deleted, not moved to the Trash."))
                .disabled(model.report == nil || model.scanning || model.cleaning)
                Spacer()
                Text(trCount(model.selectedItems.count, "%1$@ item selected", "%1$@ items selected"))
                    .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                Button(tr("Clean %1$@", ByteFormat.string(model.selectedBytes)), action: clean)
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(model.selectedItems.isEmpty || model.cleaning || model.scanning)
            }
        }
    }
}

enum FSPath {
    static func tilde(_ p: String) -> String {
        let h = NSHomeDirectory()
        return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p
    }
}

/// Inside an expanded card: why it can go, and every session or path.
struct DiskItemDetail: View {
    @ObservedObject var model: DiskModel
    let item: CleanItem

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if item.sizeIncomplete == true {
                Text(tr("Size is a lower bound; the large-tree scan was limited. Use an exact scan for a complete measurement."))
                    .font(Theme.caption).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
            } else if item.estimatedSize == true {
                Text(tr("Allocated size estimate; shared blocks may not be reclaimed."))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            if let kept = item.whitelisted {
                Text(tr("%1$@ whitelisted paths kept", String(kept.count))).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            if let n = item.note { Text(n).font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
            if item.developmentDependency {
                Text(tr("Kept by default: development may need these files again. Archive them only when the environment or project is inactive."))
                    .font(Theme.secondary).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
            }
            if let scope = item.commandScope, !scope.isEmpty {
                Text(tr("Tool-managed locations")).font(Theme.label).foregroundStyle(Theme.textTertiary)
                ForEach(scope, id: \.self) { path in
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        Text(FSPath.tilde(path)).font(Theme.mono).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.alwaysKeep(item, paths: [path]) } label: { Image(systemName: "shield.lefthalf.filled") }
                            .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help(tr("Always keep"))
                            .accessibilityLabel(tr("Always keep %1$@", FSPath.tilde(path)))
                            .disabled(model.cleaning || model.scanning || item.whitelisted?.contains(path) == true)
                    }
                }
            }
            if let h = item.hint { Text(tr("Run: %1$@", h)).font(Theme.mono).foregroundStyle(Theme.textPrimary).textSelection(.enabled) }
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "info.circle").font(.system(size: 10)).accessibilityHidden(true)
                Text(safetyText).fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            if let parts = item.parts, parts.count > 1 {
                let ticked = parts.filter { model.isTicked($0, of: item) }.count
                HStack {
                    SelectAllButton(title: trCount(parts.count, "%1$@ session", "%1$@ sessions"), available: parts.count, selected: ticked,
                                    selectAll: { model.excluded[item.id] = nil; if !model.selected.contains(item.id) { model.toggle(item) } },
                                    clear: { model.selected.remove(item.id); model.excluded[item.id] = nil })
                        .disabled(model.cleaning || !item.cleanable)
                    Spacer()
                }
                .padding(.top, Theme.Space.xs)
                // Long lists (a project with 1 600 sessions) stay scrollable inside the card.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(parts) { p in
                            let on = model.isTicked(p, of: item)
                            HStack(spacing: Theme.Space.s) {
                                SelectToggle(selected: on, label: tr("Select %1$@", p.title)) { model.toggle(p, of: item) }
                                    .disabled(model.cleaning || !item.cleanable)
                                Text(p.title).font(Theme.secondary).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer()
                                if let d = p.lastUsed { Text(AgeFormat.string(d)).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                                Text(ByteFormat.string(p.bytes)).font(Theme.secondary.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .padding(.vertical, 2)
                            .contextMenu { Button(tr("Always keep")) { model.alwaysKeep(item, paths: p.paths) }.disabled(model.cleaning || model.scanning) }
                        }
                    }
                }
                .frame(maxHeight: 260)
            } else if !item.paths.isEmpty {
                ForEach(item.paths.prefix(12), id: \.self) { p in
                    HStack {
                        Text(FSPath.tilde(p)).font(Theme.mono).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } label: {
                            Image(systemName: "magnifyingglass")
                        }.buttonStyle(.borderless).foregroundStyle(Theme.textTertiary).help(tr("Show in Finder"))
                    }
                    .contextMenu { Button(tr("Always keep")) { model.alwaysKeep(item, paths: [p]) }.disabled(model.cleaning || model.scanning) }
                }
                if item.paths.count > 12 {
                    Text(tr("… and %1$@ more", String(item.paths.count - 12))).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.leading, 36)
    }

    var safetyText: String {
        if !(item.commands ?? []).isEmpty { return tr("Tool-managed items are removed permanently; they do not go to the Trash.") }
        switch item.safety {
        case .safe: return tr("Safe: this is regenerated automatically (caches, logs, build output). It is deleted, not moved to the Trash.")
        case .review: return tr("Your data, probably no longer needed. It goes to the Trash, so you can still get it back.")
        case .risky: return tr("Could lose work (for example uncommitted changes). Only removed when you tick it yourself.")
        }
    }
}
