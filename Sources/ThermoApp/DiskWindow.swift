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
            let how = !(i.commands ?? []).isEmpty ? tr("permanent tool removal") : i.safety == .safe ? tr("delete") : tr("trash")
            let paths = trCount(i.paths.count, "%1$@ path", "%1$@ paths")
            return ["\(how) · \(ByteFormat.string(i.bytes)) · \(i.title) (\(paths))"]
                + i.paths.map { "    " + FSPath.tilde($0) }
                + (i.commands ?? []).map { "    " + $0.joined(separator: " ") }
        }
    }

    var confirmSummary: String {
        let items = selectedItems
        let trash = items.filter { $0.safety != .safe && ($0.commands ?? []).isEmpty }
        let toolItems = items.filter { !($0.commands ?? []).isEmpty }
        var parts = [trCount(items.count, "%1$@ item.", "%1$@ items.")]
        if items.contains(where: { $0.safety == .safe && !($0.paths).isEmpty }) { parts.append(tr("Caches and build output are deleted.")) }
        if !trash.isEmpty {
            parts.append(trCount(trash.count, "%1$@ item with your data (sessions, models, worktrees) goes to the Trash.",
                                 "%1$@ items with your data (sessions, models, worktrees) go to the Trash."))
        }
        if !toolItems.isEmpty { parts.append(tr("Tool-managed items are removed permanently; they do not go to the Trash.")) }
        return parts.joined(separator: " ")
    }

    var safeItems: [CleanItem] { (report?.items ?? []).filter { $0.cleanable && $0.safety == .safe } }
    var safeBytes: Int64 { safeItems.reduce(0) { $0 + $1.bytes } }

    func selectSafe() { selected = Set(safeItems.map(\.id)) }
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
        if info { return (tr("info"), .cyan) }
        switch s {
        case .safe: return (tr("safe"), .green)
        case .review: return (tr("review"), .orange)
        case .risky: return (tr("risky"), .red)
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
            VStack(spacing: 26) {
                hero.padding(.top, 54)
                if let r = model.report, !r.items.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        ForEach(CleanCategory.allCases, id: \.self) { c in
                            let inCat = r.items.filter { $0.category == c && $0.cleanable }
                            let waiting = r.blockedBytes(in: c)
                            // A category whose items all wait for an app to quit still shows, with that said.
                            if !inCat.isEmpty || waiting > 0 {
                                CategoryCard(symbol: DiskStyle.icon(c), color: DiskStyle.tint(c), title: c.title,
                                             status: DiskStyle.categoryStatus(r, c), statusColor: .white.opacity(0.7),
                                             count: inCat.count) { open(c) }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                }
                if model.report?.cancelled == true {
                    Label(tr("Scan stopped. These are partial results."), systemImage: "pause.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let denied = model.report?.denied, !denied.isEmpty {
                    VStack(spacing: 8) {
                        Text(tr("%1$@ locations could not be read. Results may be incomplete.", String(denied.count)))
                            .font(.callout).foregroundStyle(.orange)
                        Button(tr("Open Full Disk Access")) { model.openFullDiskAccess() }.buttonStyle(PillButtonStyle())
                    }
                }
                if let res = model.lastResult {
                    Text(res).font(.callout).foregroundStyle(.white.opacity(0.7)).onTapGesture { model.openLog() }
                }
                if let days = model.report?.claudeCleanupDays {
                    Text(tr("Claude Code deletes its own sessions after %1$@ days (cleanupPeriodDays).", String(days)))
                        .font(.caption).foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder var hero: some View {
        if model.cleaning {
            HeroStatus(symbol: "trash.fill", color: .orange, title: tr("Cleaning…"),
                       subtitle: model.cleaningStep,
                       progress: Double(model.cleaningDone) / Double(max(1, model.cleaningTotal)))
        } else if model.scanning {
            VStack(spacing: 18) {
                HeroStatus(symbol: "magnifyingglass", color: Color(red: 0.4, green: 0.5, blue: 1.0),
                           title: model.report.map { tr("%1$@ found so far", ByteFormat.string($0.totalBytes)) } ?? tr("Looking for space you can free…"),
                           subtitle: model.progress, spinning: true)
                Button(tr("Stop")) { model.stop() }.buttonStyle(PillButtonStyle()).disabled(model.stopping)
            }
        } else if let r = model.report {
            VStack(spacing: 18) {
                HeroStatus(symbol: r.totalBytes > 0 ? "internaldrive.fill" : "checkmark", color: r.totalBytes > 0 ? .pink : .green,
                           title: r.totalBytes > 0 ? tr("%1$@ can be freed", ByteFormat.string(r.totalBytes)) : tr("Nothing to clean."),
                           subtitle: tr("%1$@ is safe to remove now (caches, build output); the rest is yours to review.", ByteFormat.string(model.safeBytes)))
                HStack(spacing: 20) {
                    BigRoundButton(title: tr("Clean"), color: .pink, busy: model.cleaning) {
                        model.selectSafe()
                        clean()
                    }
                    .disabled(model.safeItems.isEmpty)
                    VStack(alignment: .leading, spacing: 8) {
                        Button(tr("Scan again")) { model.scan() }.buttonStyle(PillButtonStyle())
                        Picker("", selection: $model.scope) { ForEach(DiskModel.Scope.allCases) { Text($0.label).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                    }
                }
            }
        } else {
            VStack(spacing: 18) {
                HeroStatus(symbol: "internaldrive.fill", color: Color(red: 0.4, green: 0.5, blue: 1.0),
                           title: tr("Find space you can free"),
                           subtitle: tr("Old AI sessions, model downloads, agent leftovers, build output and caches. Nothing is removed until you choose."))
                BigRoundButton(title: tr("Scan"), color: Color(red: 0.35, green: 0.5, blue: 1.0)) { model.scan() }
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
    @FocusState private var searchFocused: Bool
    @State private var open: Set<String> = []

    var items: [CleanItem] {
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
            header.padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 14)
            if model.report?.cancelled == true {
                Label(tr("Scan stopped. These are partial results."), systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28).padding(.bottom, 10)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    let list = items
                    let groups = Dictionary(grouping: list, by: { $0.group ?? "" })
                    if category == .projects && groups.count > 1 {
                        // One block per project folder: its build outputs together, last use shown once.
                        ForEach(groups.keys.sorted { (groups[$0] ?? []).reduce(0) { $0 + $1.bytes } > (groups[$1] ?? []).reduce(0) { $0 + $1.bytes } }, id: \.self) { g in
                            let rows = groups[g] ?? []
                            HStack {
                                Text(FSPath.tilde(g)).font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                                if let used = rows.compactMap(\.lastUsed).max() {
                                    Text(tr("last used %1$@", AgeFormat.string(used))).font(.caption).foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer()
                                Text(ByteFormat.string(rows.reduce(0) { $0 + $1.bytes })).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(.top, 8)
                            ForEach(rows) { card($0) }
                        }
                    } else {
                        ForEach(list) { card($0) }
                    }
                    if list.isEmpty {
                        if model.scanning {
                            Label(tr("Looking…"), systemImage: "hourglass")
                                .foregroundStyle(.secondary).padding(.top, 30)
                        } else if model.report == nil || model.report?.categories?.contains(category) == false {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(tr("Find space you can free"), systemImage: "magnifyingglass")
                                Button(tr("Scan")) {
                                    model.scan(category: category)
                                }.buttonStyle(PillButtonStyle())
                            }
                            .foregroundStyle(.secondary).padding(.top, 30)
                        } else if model.report?.cancelled == true {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(tr("Scan stopped. These are partial results."), systemImage: "pause.circle")
                                Button(tr("Scan again")) { model.scan(category: category) }.buttonStyle(PillButtonStyle())
                            }
                            .foregroundStyle(.secondary).padding(.top, 30)
                        } else {
                            Text(!search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tr("No matching items") : tr("Nothing here."))
                                .foregroundStyle(.secondary).padding(.top, 30)
                        }
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
            }
            footer
        }
        .onAppear { model.loadSaved(category: category) }
    }

    var header: some View {
        let selected = model.selectedItems.filter { $0.category == category }
        return HStack(spacing: 14) {
            IconTile(symbol: DiskStyle.icon(category), color: DiskStyle.tint(category), size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(category.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                Text(tr("%1$@ · %2$@ selected", model.report.map { DiskStyle.categoryStatus($0, category) } ?? ByteFormat.string(0),
                        ByteFormat.string(selected.reduce(0) { $0 + $1.bytes })))
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            HStack(spacing: 6) {
                TextField(tr("Search"), text: $search).textFieldStyle(.roundedBorder)
                    .focused($searchFocused).accessibilityLabel(tr("Search"))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel(tr("Clear search")).help(tr("Clear search"))
                }
            }
            .frame(width: 180)
            .background(Button("") {
                guard MainWindow.window?.attachedSheet == nil else { return }
                searchFocused = true
            }.keyboardShortcut("f", modifiers: .command).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true))
        }
    }

    func card(_ i: CleanItem) -> some View {
        let ticked = model.selected.contains(i.id)
        let expanded = open.contains(i.id)
        let (tag, tagColor) = DiskStyle.safety(i.safety, info: i.paths.isEmpty)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { model.toggle(i) } label: {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle").font(.title3)
                        .foregroundStyle(i.cleanable ? (ticked ? Color.pink : .white.opacity(0.5)) : .white.opacity(0.2))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!i.cleanable || model.cleaning)
                .accessibilityLabel(tr("Select %1$@", i.title))
                .accessibilityValue(ticked ? tr("Selected") : tr("Not selected"))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(i.title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(1).help(i.title)
                        Text(tag).font(.system(size: 10, weight: .semibold)).foregroundStyle(tagColor)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(tagColor.opacity(0.18)))
                    }
                    Text(i.blocked ?? [i.detail, i.lastUsed.map { AgeFormat.string($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(i.blocked != nil ? Color.orange : .white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(ByteFormat.string(model.selectedItems.first { $0.id == i.id }?.bytes ?? i.bytes))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                Button { if expanded { open.remove(i.id) } else { open.insert(i.id) } } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).accessibilityLabel(tr("Details for %1$@", i.title))
                .accessibilityValue(expanded ? tr("Expanded") : tr("Collapsed"))
            }
            .contentShape(Rectangle())
            .onTapGesture { if expanded { open.remove(i.id) } else { open.insert(i.id) } }
            if expanded { DiskItemDetail(model: model, item: i) }
        }
        .padding(14)
        .glass(radius: 14, highlighted: ticked)
        .contextMenu {
            Button(tr("Show in Finder")) { model.reveal(i) }.disabled(i.paths.isEmpty)
            Button(tr("Copy ID")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(i.id, forType: .string) }
        }
    }

    var footer: some View {
        Group {
            if model.scanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.progress).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button(model.stopping ? tr("stopping…") : tr("Stop")) { model.stop() }
                        .buttonStyle(PillButtonStyle()).disabled(model.stopping)
                }
            } else {
                selectionFooter
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(Color.black.opacity(0.18))
    }

    var selectionFooter: some View {
        HStack(spacing: 10) {
            Button(tr("Safe")) {
                let ids = (model.report?.items ?? []).filter { $0.category == category && $0.cleanable && $0.safety == .safe }.map(\.id)
                model.selected.formUnion(ids)
            }.buttonStyle(PillButtonStyle()).disabled(model.report == nil || model.scanning || model.cleaning)
            Button(tr("None")) {
                model.selected.subtract((model.report?.items ?? []).filter { $0.category == category }.map(\.id))
            }.buttonStyle(PillButtonStyle()).disabled(model.report == nil || model.scanning || model.cleaning)
            Spacer()
            Text(trCount(model.selectedItems.count, "%1$@ item selected", "%1$@ items selected")).foregroundStyle(.white.opacity(0.6))
            Button(tr("Clean %1$@", ByteFormat.string(model.selectedBytes)), action: clean)
                .buttonStyle(PillButtonStyle(prominent: true, color: .pink))
                .disabled(model.selectedItems.isEmpty || model.cleaning || model.scanning)
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
        VStack(alignment: .leading, spacing: 8) {
            if let n = item.note { Text(n).font(.callout).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true) }
            if let h = item.hint { Text(tr("Run: %1$@", h)).font(.callout.monospaced()).foregroundStyle(.white.opacity(0.8)).textSelection(.enabled) }
            Text(safetyText).font(.caption).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            if let parts = item.parts, parts.count > 1 {
                HStack {
                    Text(trCount(parts.count, "%1$@ session", "%1$@ sessions")).font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Button(tr("All")) { model.excluded[item.id] = nil; if !model.selected.contains(item.id) { model.toggle(item) } }
                        .buttonStyle(PillButtonStyle())
                    Button(tr("None")) { model.selected.remove(item.id); model.excluded[item.id] = nil }.buttonStyle(PillButtonStyle())
                }
                // Long lists (a project with 1 600 sessions) stay scrollable inside the card.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(parts) { p in
                            let on = model.isTicked(p, of: item)
                            HStack(spacing: 8) {
                                Button { model.toggle(p, of: item) } label: {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(on ? Color.pink : .white.opacity(0.45))
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain).disabled(model.cleaning || !item.cleanable)
                                .accessibilityLabel(tr("Select %1$@", p.title))
                                .accessibilityValue(on ? tr("Selected") : tr("Not selected"))
                                Text(p.title).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                                Spacer()
                                if let d = p.lastUsed { Text(AgeFormat.string(d)).font(.caption).foregroundStyle(.white.opacity(0.45)) }
                                Text(ByteFormat.string(p.bytes)).font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                    }
                }
                .frame(maxHeight: 260)
            } else if !item.paths.isEmpty {
                ForEach(item.paths.prefix(12), id: \.self) { p in
                    HStack {
                        Text(FSPath.tilde(p)).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } label: {
                            Image(systemName: "magnifyingglass")
                        }.buttonStyle(.borderless).foregroundStyle(.white.opacity(0.6)).help(tr("Show in Finder"))
                    }
                }
                if item.paths.count > 12 {
                    Text(tr("… and %1$@ more", String(item.paths.count - 12))).font(.caption).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(.leading, 34)
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
