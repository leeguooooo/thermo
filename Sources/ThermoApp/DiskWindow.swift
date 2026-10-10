import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

/// The place to actually clean, in the same look as AI Agent Diagnostics: a gradient window with a
/// sidebar, a Smart Scan home (how much can go, one button for the safe part, a card per category),
/// a page per category with expandable glass rows, and "Where the space is".
/// The popover's Disk tab only summarises and opens this.
enum DiskWindow {
    private(set) static var window: NSWindow?
    static let state = State()

    final class State: ObservableObject {
        @Published var page: DiskPage = .home
    }

    static var offscreen: Bool { CommandLine.arguments.contains("--offscreen") }

    static func show(_ model: DiskModel, page: DiskPage? = nil) {
        if let page { state.page = page }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // Content first, SwiftUI sets only the minimum; autosave last (it would record the shrunken size).
            let host = NSHostingController(rootView: Host(model: model, state: state)
                .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity))
            host.sizingOptions = [.minSize]
            w.contentViewController = host
            if !w.setFrameUsingName("DiskCleanup2") || w.frame.width < 960 || w.frame.height < 640 {
                w.setContentSize(NSSize(width: 1080, height: 720))
                w.center()
            }
            w.setFrameAutosaveName("DiskCleanup2")
            // Verification screenshots never appear on the user's screen.
            if offscreen {
                w.styleMask = [.borderless]
                w.setFrame(NSRect(x: -6000, y: -6000, width: 1080, height: 720), display: true)
            }
            window = w
        }
        window?.title = tr("Disk Cleanup")
        if offscreen {
            window?.orderBack(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        if model.report == nil && !model.scanning && !model.loadSaved() { model.scan() }
    }

    /// Verification: waits for the scan, lets animations settle, writes the window as a PNG, quits.
    static func snapshotWhenReady(_ model: DiskModel, to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard model.report != nil, !model.scanning else { return snapshotWhenReady(model, to: path) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
        }
    }

    struct Host: View {
        @ObservedObject var model: DiskModel
        @ObservedObject var state: State
        @AppStorage(L10n.defaultsKey) private var language = "system"
        var body: some View { DiskCleanupView(model: model, page: $state.page).id(language) }
    }
}

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
        selectedItems.map { i in
            let how = i.safety == .safe ? tr("delete") : tr("trash")
            let paths = trCount(i.paths.count, "%1$@ path", "%1$@ paths")
            return "\(how.padding(toLength: 7, withPad: " ", startingAt: 0)) \(ByteFormat.string(i.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(i.title) (\(paths))"
        }
    }

    var confirmSummary: String {
        let items = selectedItems
        let trash = items.filter { $0.safety != .safe }
        var parts = [trCount(items.count, "%1$@ item.", "%1$@ items.")]
        if trash.count < items.count { parts.append(tr("Caches and build output are deleted.")) }
        if !trash.isEmpty {
            parts.append(trCount(trash.count, "%1$@ item with your data (sessions, models, worktrees) goes to the Trash.",
                                 "%1$@ items with your data (sessions, models, worktrees) go to the Trash."))
        }
        return parts.joined(separator: " ")
    }

    var safeItems: [CleanItem] { (report?.items ?? []).filter { $0.cleanable && $0.safety == .safe } }
    var safeBytes: Int64 { safeItems.reduce(0) { $0 + $1.bytes } }

    func selectSafe() { selected = Set(safeItems.map(\.id)) }
}

enum DiskStyle {
    static func icon(_ c: CleanCategory) -> String {
        switch c {
        case .aiSessions: return "bubble.left.and.text.bubble.right.fill"
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

struct DiskCleanupView: View {
    @ObservedObject var model: DiskModel
    @Binding var page: DiskPage
    @State private var confirming = false

    var items: [CleanItem] { model.report?.items ?? [] }

    var body: some View {
        ZStack {
            WindowBackdrop(glow: page == .home, tint: Color(red: 0.36, green: 0.42, blue: 1.0))
            HStack(spacing: 0) {
                sidebar.frame(width: 236).background(Color.black.opacity(0.22))
                Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
                ZStack {
                    switch page {
                    case .home:
                        DiskHome(model: model, open: { page = .category($0) }, clean: startClean).transition(.opacity)
                    case .overview:
                        DiskOverviewView().transition(.opacity)
                    case let .category(c):
                        DiskCategoryPage(model: model, category: c, clean: startClean).id(c)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.25), value: page)
        .sheet(isPresented: $confirming) {
            ConfirmSheet(title: tr("Clean %1$@?", ByteFormat.string(model.selectedBytes)), summary: model.confirmSummary,
                         destructive: model.selectedItems.contains { $0.safety == .safe }, heading: tr("What will be removed"),
                         lines: model.planLines,
                         footnote: tr("Removed items are listed in ~/Library/Logs/Thermo/clean.log. Anything changed since the scan is skipped."),
                         confirmTitle: tr("Clean"),
                         confirm: { confirming = false; model.clean() }, cancel: { confirming = false })
        }
    }

    func startClean() { if !model.selectedItems.isEmpty { confirming = true } }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive.fill").foregroundStyle(.white.opacity(0.8))
                Text(tr("Disk Cleanup")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 16).padding(.top, 44).padding(.bottom, 18)
            row(.home, title: tr("Smart Scan"), symbol: "sparkles", color: .pink,
                trailing: model.report.map { ByteFormat.string($0.totalBytes) })
            row(.overview, title: tr("Where the space is"), symbol: "chart.pie.fill", color: .teal, trailing: nil)
            Text(tr("Categories").uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 6)
            ForEach(CleanCategory.allCases, id: \.self) { c in
                let bytes = model.report?.bytes(in: c) ?? 0
                if bytes > 0 || items.contains(where: { $0.category == c }) {
                    row(.category(c), title: c.title, symbol: DiskStyle.icon(c), color: DiskStyle.tint(c),
                        trailing: ByteFormat.string(bytes))
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.scanning ? Color.yellow : Color.green).frame(width: 6, height: 6)
                Text(model.scanning ? tr("Scanning…") : model.report.map { tr("scanned %1$@", AgeFormat.string($0.started)) } ?? tr("Not scanned yet"))
            }
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).padding(16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    func row(_ target: DiskPage, title: String, symbol: String, color: Color, trailing: String?) -> some View {
        let on = page == target
        return Button { page = target } label: {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, color: color, size: 22)
                Text(title).font(.system(size: 13)).foregroundStyle(.white.opacity(on ? 1 : 0.8)).lineLimit(1)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.5)) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(on ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 8)
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
                            if !inCat.isEmpty {
                                CategoryCard(symbol: DiskStyle.icon(c), color: DiskStyle.tint(c), title: c.title,
                                             status: ByteFormat.string(r.bytes(in: c)), statusColor: .white.opacity(0.7),
                                             count: inCat.count) { open(c) }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
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
    @State private var open: Set<String> = []

    var items: [CleanItem] {
        var list = (model.report?.items ?? []).filter { $0.category == category }
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter { ($0.title + " " + $0.detail + " " + ($0.note ?? "")).lowercased().contains(q) }
        }
        return list.sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 14)
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
                        Text(model.scanning ? tr("Looking…") : tr("Nothing here.")).foregroundStyle(.white.opacity(0.5)).padding(.top, 30)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
            }
            footer
        }
    }

    var header: some View {
        let selected = model.selectedItems.filter { $0.category == category }
        return HStack(spacing: 14) {
            IconTile(symbol: DiskStyle.icon(category), color: DiskStyle.tint(category), size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(category.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                Text(tr("%1$@ · %2$@ selected", ByteFormat.string(model.report?.bytes(in: category) ?? 0),
                        ByteFormat.string(selected.reduce(0) { $0 + $1.bytes })))
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            TextField(tr("Search"), text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
        }
    }

    func card(_ i: CleanItem) -> some View {
        let ticked = model.selected.contains(i.id)
        let expanded = open.contains(i.id)
        let (tag, tagColor) = DiskStyle.safety(i.safety, info: i.paths.isEmpty)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(i.cleanable ? (ticked ? Color.pink : .white.opacity(0.5)) : .white.opacity(0.2))
                    .onTapGesture { if i.cleanable { model.toggle(i) } }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(i.title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        Text(tag).font(.system(size: 10, weight: .semibold)).foregroundStyle(tagColor)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(tagColor.opacity(0.18)))
                    }
                    Text(i.blocked ?? [i.detail, i.lastUsed.map { AgeFormat.string($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(i.blocked != nil ? Color.orange : .white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(ByteFormat.string(model.selectedItems.first { $0.id == i.id }?.bytes ?? i.bytes))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
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
        HStack(spacing: 10) {
            Button(tr("Safe")) {
                let ids = (model.report?.items ?? []).filter { $0.category == category && $0.cleanable && $0.safety == .safe }.map(\.id)
                model.selected.formUnion(ids)
            }.buttonStyle(PillButtonStyle())
            Button(tr("None")) {
                model.selected.subtract((model.report?.items ?? []).filter { $0.category == category }.map(\.id))
            }.buttonStyle(PillButtonStyle())
            Spacer()
            Text(trCount(model.selectedItems.count, "%1$@ item selected", "%1$@ items selected")).foregroundStyle(.white.opacity(0.6))
            Button(tr("Clean %1$@", ByteFormat.string(model.selectedBytes)), action: clean)
                .buttonStyle(PillButtonStyle(prominent: true, color: .pink))
                .disabled(model.selectedItems.isEmpty || model.cleaning || model.scanning)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(Color.black.opacity(0.18))
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
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(on ? Color.pink : .white.opacity(0.45))
                                    .onTapGesture { model.toggle(p, of: item) }
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
        switch item.safety {
        case .safe: return tr("Safe: this is regenerated automatically (caches, logs, build output). It is deleted, not moved to the Trash.")
        case .review: return tr("Your data, probably no longer needed. It goes to the Trash, so you can still get it back.")
        case .risky: return tr("Could lose work (for example uncommitted changes). Only removed when you tick it yourself.")
        }
    }
}
