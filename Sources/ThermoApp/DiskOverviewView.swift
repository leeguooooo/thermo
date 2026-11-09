import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

/// Measures "where the space is" in the background, streaming each place as it finishes, and keeps
/// the last result so the window opens with numbers instead of a long wait.
@MainActor
final class SpaceOverviewModel: ObservableObject {
    static let shared = SpaceOverviewModel()

    @Published private(set) var diskSpace: DiskSpaceSnapshot?
    @Published private(set) var overview: SpaceOverview?
    @Published private(set) var measuredAt: Date?
    /// Places finished in the current measurement, shown before the whole thing is done.
    @Published private(set) var partial: [SpaceOverview.Entry] = []
    @Published private(set) var measuring = false
    @Published private(set) var stopping = false
    @Published private(set) var stopped = false
    private var cancellation: ScanCancellation?
    private var measurementLanguage: String?
    private var restartAfterCurrent = false
    private var generation = UUID()
    private var inFlight = false
    private var invalidatedDuringMeasurement = false
    private let read: @Sendable (ScanCancellation, ((SpaceOverview.Entry) -> Void)?) -> SpaceOverview
    private let save: @Sendable (SpaceOverview) -> Void
    private let readDiskSpace: @Sendable () -> DiskSpaceSnapshot?

    init(cached: (SpaceOverview, Date)? = SpaceOverview.cached(localize: true), diskSpace: DiskSpaceSnapshot? = .measure(),
         read: @escaping @Sendable (ScanCancellation, ((SpaceOverview.Entry) -> Void)?) -> SpaceOverview = { var o = SpaceOverview.measure(onEntry: $1, cancellation: $0, lowPriority: true); o.noteGrowth(); return o },
         save: @escaping @Sendable (SpaceOverview) -> Void = { $0.save() },
         readDiskSpace: @escaping @Sendable () -> DiskSpaceSnapshot? = { .measure() }) {
        self.read = read; self.save = save; self.readDiskSpace = readDiskSpace
        self.diskSpace = diskSpace
        if let (o, at) = cached { overview = o; measuredAt = at }
    }

    /// Entries to show: the finished measurement, or what has come in so far.
    var entries: [SpaceOverview.Entry] {
        (measuring || stopped) ? Self.merging(overview?.entries ?? [], updates: partial) : overview?.entries ?? []
    }

    static func merging(_ previous: [SpaceOverview.Entry], updates: [SpaceOverview.Entry]) -> [SpaceOverview.Entry] {
        var entries = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for entry in updates { entries[entry.id] = entry }
        return entries.values.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }

    func acceptEntry(_ entry: SpaceOverview.Entry) {
        if let index = partial.firstIndex(where: { $0.id == entry.id }) {
            let previous = partial[index]
            guard !(previous.complete == true && entry.complete == false),
                  (entry.attemptedLocations ?? entry.measuredLocations ?? 0) >= (previous.attemptedLocations ?? previous.measuredLocations ?? 0) else { return }
            partial[index] = entry
        } else { partial.append(entry) }
    }

    func measure() {
        guard !inFlight else {
            if invalidatedDuringMeasurement { restartAfterCurrent = true }
            return
        }
        diskSpace = readDiskSpace()
        let generation = UUID()
        self.generation = generation
        measuring = true
        inFlight = true
        invalidatedDuringMeasurement = false
        measurementLanguage = L10n.current.rawValue
        restartAfterCurrent = false
        stopping = false
        stopped = false
        partial = []
        let cancellation = ScanCancellation()
        self.cancellation = cancellation
        let read = self.read, save = self.save
        Task.detached(priority: .utility) {
            let o = read(cancellation, { e in
                Task { @MainActor in
                    guard self.generation == generation, self.cancellation === cancellation, !cancellation.isCancelled else { return }
                    self.acceptEntry(e)
                }
            })
            await MainActor.run {
                guard self.cancellation === cancellation else { return }
                self.inFlight = false
                self.measuring = false
                self.stopping = false
                self.cancellation = nil
                let restart = self.restartAfterCurrent
                self.restartAfterCurrent = false
                guard self.generation == generation else {
                    if restart { self.measure() }
                    return
                }
                save(o)
                if o.language != L10n.current.rawValue {
                    self.partial = []
                    self.stopped = !restart
                } else if o.cancelled == true {
                    self.partial = o.entries
                    self.stopped = true
                } else {
                    self.overview = o
                    self.diskSpace = self.readDiskSpace()
                    self.measuredAt = o.measuredAt
                }
                if restart { self.measure() }
            }
        }
    }

    /// A cleanup invalidates cached breakdowns. Late callbacks from an old measurement
    /// must neither restore stale folders nor write their old overview back to disk.
    func invalidateAfterCleanup() {
        generation = UUID()
        cancellation?.cancel()
        if !inFlight { cancellation = nil }
        invalidatedDuringMeasurement = inFlight
        restartAfterCurrent = false
        measurementLanguage = nil
        measuring = inFlight
        stopping = inFlight
        stopped = false
        overview = nil
        measuredAt = nil
        partial = []
        diskSpace = readDiskSpace()
    }

    func stop() {
        restartAfterCurrent = false
        guard measuring else { return }
        stopping = true
        cancellation?.cancel()
    }

    /// Measures on first open, or when the saved numbers are over an hour old.
    func discardIncompatibleResults() {
        if let overview, overview.language != L10n.current.rawValue {
            if let localized = overview.localizedForCurrentLanguage() {
                self.overview = localized
            } else {
                self.overview = nil
                measuredAt = nil
            }
            partial = []
            stopped = false
        }
    }

    func measureIfStale() {
        diskSpace = readDiskSpace()
        if overview != nil, !SpaceOverview.isCurrent(measuredAt: measuredAt) { invalidateAfterCleanup() }
        discardIncompatibleResults()
        if measuring {
            if invalidatedDuringMeasurement { restartAfterCurrent = true }
            if measurementLanguage != L10n.current.rawValue {
                restartAfterCurrent = true
                cancellation?.cancel()
            }
            return
        }
        guard !stopped else { return }
        if measuredAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true { measure() }
    }
}

/// The volume's used space, by place, with each place's biggest folders.
struct DiskOverviewView: View {
    @ObservedObject var model = SpaceOverviewModel.shared
    var openCleanup: (CleanCategory?) -> Void = { _ in }
    var cleanupDisabled = false
    /// Opens a folder in Space Lens, where it can be picked and moved to the Trash.
    var openInSpaceLens: (String) -> Void = { _ in }
    @State private var detail: SpaceOverview.Entry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                if let live = model.diskSpace {
                    capacityBar(capacity: live.capacityBytes, free: live.availableBytes, purgeable: live.purgeableBytes ?? 0)
                } else if let o = model.overview {
                    capacityBar(capacity: o.capacity, free: o.free, purgeable: o.purgeable)
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if let unreadable = model.overview?.unreadable, !unreadable.isEmpty {
                        HStack(spacing: Theme.Space.m) {
                            Label(tr("%1$@ locations could not be read. Results may be incomplete.", String(unreadable.count)), systemImage: "lock.shield")
                                .font(Theme.body).foregroundStyle(Theme.caution)
                            Spacer(minLength: Theme.Space.s)
                            Button(tr("Open Full Disk Access")) { AppModels.shared.disk.openFullDiskAccess() }
                                .buttonStyle(PillButtonStyle()).controlSize(.small)
                        }
                        .padding(Theme.Space.m + 2).glass()
                    }
                    if model.entries.contains(where: { $0.effectiveSizeState != .complete }) {
                        Label(tr("Some categories could not be fully measured. Known bytes are lower bounds; the unattributed residual is not a measured folder size."), systemImage: "exclamationmark.triangle")
                            .font(Theme.secondary).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.stopped {
                        Label(model.overview == nil ? tr("Measurement stopped. Only completed folders are counted; unfinished categories show a lower bound.") : tr("Measurement stopped. Unchanged categories keep previous results; updated categories count only completed folders."), systemImage: "pause.circle")
                            .font(Theme.secondary).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !model.measuring, let growth = model.overview?.growth { growthSection(growth) }
                if model.entries.isEmpty {
                    if model.stopped {
                        EmptyState(symbol: "pause.circle", title: tr("No folders finished before stopping. Measure again to continue."))
                    } else {
                        SkeletonList(rows: 6)
                    }
                } else {
                    let groups = SpaceStyle.split(model.entries)
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionHeader(title: tr("Your data")) {
                            if model.measuring, model.overview != nil {
                                InfoButton(text: tr("Categories update as folders finish; unfinished totals are lower bounds."))
                            }
                            if !model.measuring, let over = model.overview?.overcounted {
                                InfoButton(text: tr("The headings add up to %1$@ more than the disk uses: hard links (pnpm), APFS clones and files written while measuring count in each place.", ByteFormat.string(over)))
                            }
                        }
                        InspectorPanel {
                            ForEach(Array(groups.yours.enumerated()), id: \.element.id) { i, e in
                                if i > 0 { InspectorDivider(inset: 54) }
                                row(e)
                            }
                        }
                    }
                    if !groups.system.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionHeader(title: tr("Managed by macOS"))
                            InspectorPanel {
                                ForEach(Array(groups.system.enumerated()), id: \.element.id) { i, e in
                                    if i > 0 { InspectorDivider(inset: 54) }
                                    row(e)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: Theme.pageWidth, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pageTop).padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: .infinity)
        }
        .onAppear { model.measureIfStale() }
        .onDisappear { model.stop() }
        .sheet(item: $detail) { e in
            SpaceDetailSheet(entry: e, route: Self.cleanupRoute(for: e.id), cleanupDisabled: cleanupDisabled,
                             openCleanup: openCleanup, openInSpaceLens: openInSpaceLens) { detail = nil }
        }
    }

    var header: some View {
        PageHeader(title: tr("Where your disk space is"), subtitle: subtitle) {
            if model.measuring {
                ProgressView().controlSize(.small)
                Button(model.stopping ? tr("Stopping…") : tr("Stop")) { model.stop() }
                    .buttonStyle(PillButtonStyle()).disabled(model.stopping)
            } else {
                Button { model.measure() } label: { Label(tr("Measure again"), systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle())
            }
        }
    }

    var subtitle: String {
        if model.measuring { return tr("measuring… %1$@ places so far", String(model.partial.reduce(0) { $0 + ($1.measuredLocations ?? 1) })) }
        guard let at = model.measuredAt else { return "" }
        return tr("measured %1$@", at.text(date: .abbreviated, time: .shortened))
    }

    /// The page's hero: how full the disk is, and what fills it, as one figure and one bar.
    func capacityBar(capacity: Int64, free: Int64, purgeable: Int64 = 0) -> some View {
        let usedBytes = max(0, capacity - free)
        let used = capacity > 0 ? min(1, max(0, Double(usedBytes) / Double(capacity))) : 0
        let tone = used > 0.95 ? Theme.danger : used > 0.85 ? Theme.caution : Theme.textSecondary
        // Before any place is measured the bar still shows how full the disk is.
        let measured = SpaceStyle.segments(model.entries, used: usedBytes)
        let segments = measured.isEmpty && usedBytes > 0 ? [SpaceStyle.Segment(id: "used", title: tr("Used"), color: tone, bytes: usedBytes)] : measured
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(ByteFormat.string(free)).font(Theme.figure(.hero)).foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text(tr("free")).font(Theme.body).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(tr("%1$@ of %2$@ used", ByteFormat.string(usedBytes), ByteFormat.string(capacity)))
                    .font(Theme.secondary.monospacedDigit()).foregroundStyle(tone)
            }
            GeometryReader { g in
                HStack(spacing: 1.5) {
                    ForEach(segments) { seg in
                        Rectangle().fill(seg.color)
                            .frame(width: max(2, (g.size.width - CGFloat(segments.count) * 1.5) * CGFloat(Double(seg.bytes) / Double(max(1, capacity)))))
                            .help(seg.title + " · " + ByteFormat.string(seg.bytes))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .animation(Theme.gentle.unlessReduced(reduceMotion), value: segments.map(\.bytes))
            }
            .frame(height: 22)
            // The legend names what the colours are, like the bar in System Settings.
            FlowLayout(spacing: Theme.Space.m) {
                ForEach(segments) { seg in
                    HStack(spacing: 5) {
                        Circle().fill(seg.color).frame(width: 8, height: 8)
                        Text(seg.title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            if purgeable > 1_000_000_000 {
                Text(tr("%1$@ more can be freed by macOS on demand", ByteFormat.string(purgeable)))
                    .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Theme.Space.l + 2).glass()
    }

    /// A command reads as one (monospaced, selectable so it can be copied); a sentence as text.
    func actionLine(_ action: String) -> some View {
        let command = action.hasPrefix("xcrun ") || action.hasPrefix("brew ") || action.hasPrefix("thermo ")
        return Text("→ " + action)
            .font(command ? Theme.mono : Theme.caption)
            .foregroundStyle(Theme.caution)
            .textSelection(.enabled)
            .lineLimit(1).truncationMode(.middle)
    }

    static func cleanupRoute(for id: String) -> (label: String, category: CleanCategory?)? {
        switch id {
        case "projects": return (tr("Scan build artifacts"), .projects)
        case "developer", "simulator-runtimes": return (tr("Review Xcode cleanup"), .xcode)
        case "homebrew": return (tr("Scan developer caches"), .devCaches)
        case "temp": return (tr("Scan temporary files and leftovers"), .system)
        // Tool folders mix AI sessions, models, tool and package caches: one category would show only a slice
        // (often 0 B when sessions are all kept), so these open the full scan.
        case "home-tools", "caches", "other": return (tr("Find cleanup candidates"), nil)
        default: return nil
        }
    }

    /// Clicking the row opens its details; a place that can be cleaned gets its own button, so
    /// "can be cleaned" is something to press, not only a caption.
    func row(_ e: SpaceOverview.Entry) -> some View {
        let style = SpaceStyle.of(e.id)
        // Unattributed space has no folder to clean; its sheet still points to a scan.
        let route = e.id == "other" ? nil : Self.cleanupRoute(for: e.id)
        let title = style.title ?? e.title
        return HStack(spacing: Theme.Space.m) {
            Button { detail = e } label: {
                HStack(spacing: Theme.Space.m) {
                    SpaceTile(style: style)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if e.complete == false, let measured = e.measuredLocations, let total = e.totalLocations {
                            Text(tr("%1$@ of %2$@ locations measured", String(measured), String(total))).font(Theme.caption).foregroundStyle(Theme.caution)
                        }
                    }
                    Spacer(minLength: Theme.Space.s)
                    Text(e.sizeText).font(Theme.figure(.row, weight: .medium))
                        .foregroundStyle(e.effectiveSizeState == .complete ? Theme.textSecondary : Theme.caution)
                        .contentTransition(.numericText())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Details for %1$@", title))
            .accessibilityValue(e.sizeText)
            if let route {
                Button(tr("Clean…")) { openCleanup(route.category) }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
                    .disabled(cleanupDisabled)
                    .help(route.label)
                    .accessibilityLabel(route.label)
            }
            Button { detail = e } label: {
                Image(systemName: "info.circle").font(.system(size: 15)).foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain).help(tr("Details"))
            .accessibilityLabel(tr("Details for %1$@", title))
        }
        .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.s + 1)
        .hoverHighlight()
    }
}

/// One place's story: what it is, what to do about it, and its biggest folders.
extension DiskOverviewView {
    /// A folder's title is usually its own path; show the folder name over its parent so the row doesn't say the path twice.
    static func growthLabel(_ item: SpaceGrowth.Item, home: String = NSHomeDirectory()) -> (title: String, caption: String?) {
        guard let path = item.path else { return (item.title, nil) }
        let tilde = FS.tilde(path, home: home)
        guard item.title == path || item.title == tilde else { return (item.title, tilde) }
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        // A lone "~" reads as a stray character; name the home folder instead.
        return (ns.lastPathComponent, parent == home ? tr("Home folder") : FS.tilde(parent, home: home))
    }

    /// Which folders grew since an earlier full measurement: when the disk fills up, the first question is "what is eating it".
    func growthSection(_ growth: SpaceGrowth) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: tr("Grew the most")) {
                InfoButton(text: tr("Compared with the full measurement from %1$@. Only folders that grew by 1 GB or more are listed.",
                                    growth.since.formatted(.relative(presentation: .named))))
            }
            if growth.freeDropBytes > 0 {
                Text(tr("Free space dropped by %1$@ since then.", ByteFormat.string(growth.freeDropBytes)))
                    .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            }
            InspectorPanel {
                ForEach(Array(growth.items.enumerated()), id: \.offset) { i, item in
                    if i > 0 { InspectorDivider(inset: Theme.Space.m) }
                    HStack(spacing: Theme.Space.m) {
                        let label = Self.growthLabel(item)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label.title).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            if let caption = label.caption {
                                Text(caption).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: Theme.Space.s)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("+" + ByteFormat.string(item.changeBytes)).font(Theme.body.monospacedDigit()).foregroundStyle(Theme.caution)
                            Text(tr("now %1$@", ByteFormat.string(item.currentBytes))).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        }
                        if let path = item.path {
                            Button(tr("Review…")) { openInSpaceLens(path) }
                                .buttonStyle(PillButtonStyle()).controlSize(.small)
                                .help(tr("Open in Space Lens to pick what to move to the Trash"))
                                .accessibilityLabel(tr("Review %1$@ in Space Lens", FSPath.tilde(path)))
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("Show in Finder"))
                                .accessibilityLabel(tr("Show %1$@ in Finder", FSPath.tilde(path)))
                        }
                    }
                    .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                }
            }
        }
    }
}

struct SpaceDetailSheet: View {
    let entry: SpaceOverview.Entry
    var route: (label: String, category: CleanCategory?)?
    var cleanupDisabled = false
    var openCleanup: (CleanCategory?) -> Void = { _ in }
    var openInSpaceLens: (String) -> Void = { _ in }
    let close: () -> Void

    var body: some View {
        let style = SpaceStyle.of(entry.id)
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                SpaceTile(style: style, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.title ?? entry.title).font(Theme.heading).foregroundStyle(Theme.textPrimary)
                    if style.title != nil { Text(entry.title).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                }
                Spacer()
                Text(entry.sizeText).font(Theme.figure(.metric)).foregroundStyle(entry.effectiveSizeState == .complete ? Theme.textPrimary : Theme.caution)
            }
            if let note = entry.note {
                Text(note).font(Theme.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if route != nil || entry.action != nil {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(tr("What you can do")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary)
                    if let a = entry.action {
                        let command = a.hasPrefix("xcrun ") || a.hasPrefix("brew ") || a.hasPrefix("thermo ")
                        HStack {
                            Text(a).font(command ? Theme.mono : Theme.secondary).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                            Spacer()
                            if command {
                                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a, forType: .string) } label: {
                                    Image(systemName: "doc.on.doc")
                                }.buttonStyle(.borderless).help(tr("Copy"))
                            }
                        }
                    }
                    if let route {
                        Button(route.label) { close(); openCleanup(route.category) }
                            .buttonStyle(PillButtonStyle(prominent: true)).disabled(cleanupDisabled)
                    }
                }
                .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.surface))
            }
            AskAIPanel {
                LocalAIQuestion(title: SpaceStyle.of(entry.id).title ?? entry.title, path: entry.path, bytes: entry.bytes,
                                note: [entry.note, entry.action].compactMap { $0 }.joined(separator: " "),
                                children: entry.children.map { "\($0.title) (\($0.sizeText))" })
            }
            if !entry.children.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(tr("Biggest inside")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary)
                    ScrollView {
                        InspectorPanel {
                            ForEach(Array(entry.children.enumerated()), id: \.element.id) { i, c in
                                if i > 0 { InspectorDivider(inset: Theme.Space.m) }
                                child(c)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
            }
            HStack {
                Spacer()
                Button(tr("Done"), action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
    }

    func child(_ c: SpaceOverview.Entry) -> some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 4) {
                Text(c.title).font(Theme.mono).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                GeometryReader { g in
                    Capsule().fill(SpaceStyle.of(entry.id).color.opacity(0.8))
                        .frame(width: max(2, g.size.width * CGFloat(Double(c.bytes) / Double(max(1, entry.bytes)))))
                }.frame(height: 3)
                if let a = c.action { Text(a).font(Theme.caption).foregroundStyle(Theme.caution).lineLimit(2) }
            }
            Spacer(minLength: Theme.Space.s)
            Text(c.sizeText).font(Theme.secondary.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            if let p = c.path {
                Button(tr("Review…")) { close(); openInSpaceLens(p) }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
                    .help(tr("Open in Space Lens to pick what to move to the Trash"))
                    .accessibilityLabel(tr("Review %1$@ in Space Lens", FSPath.tilde(p)))
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.textTertiary).help(tr("Reveal in Finder"))
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
    }
}

/// The coloured rounded square in front of each place, the way System Settings marks categories.
struct SpaceTile: View {
    let style: SpaceStyle
    var size: CGFloat = 28
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [style.color.opacity(0.95), style.color.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: style.symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

/// How each overview place looks: a short name, a symbol and a colour. Places macOS manages share
/// grey, so the coloured part of the bar is what you can do something about.
struct SpaceStyle {
    var title: String?
    var symbol: String
    var color: Color

    static let systemIDs: Set<String> = ["macos", "swap", "apple-assets", "system-data", "other", "volumes"]
    static let systemGrey = Color(white: 0.55)

    static func of(_ id: String) -> SpaceStyle {
        switch id {
        case "apps": return .init(title: tr("Applications"), symbol: "square.grid.2x2.fill", color: Color(red: 0.25, green: 0.52, blue: 0.98))
        case "app-data": return .init(title: tr("App data"), symbol: "tray.full.fill", color: Color(red: 0.42, green: 0.40, blue: 0.95))
        case "projects": return .init(title: tr("Projects"), symbol: "hammer.fill", color: Color(red: 0.98, green: 0.55, blue: 0.20))
        case "home-tools": return .init(title: tr("Tool and agent folders"), symbol: "terminal.fill", color: Color(red: 0.18, green: 0.72, blue: 0.70))
        case "home-other": return .init(title: tr("Other home folders"), symbol: "folder.fill", color: Color(red: 0.36, green: 0.62, blue: 0.86))
        case "documents": return .init(title: tr("Documents"), symbol: "doc.fill", color: Color(red: 0.95, green: 0.75, blue: 0.20))
        case "downloads": return .init(title: tr("Downloads"), symbol: "arrow.down.circle.fill", color: Color(red: 0.30, green: 0.78, blue: 0.45))
        case "library-other": return .init(title: tr("Mail, Messages and more"), symbol: "envelope.fill", color: Color(red: 0.30, green: 0.70, blue: 0.95))
        case "caches": return .init(title: tr("Caches"), symbol: "shippingbox.fill", color: Color(red: 0.70, green: 0.52, blue: 0.36))
        case "developer": return .init(title: tr("Xcode and simulators"), symbol: "chevron.left.forwardslash.chevron.right", color: Color(red: 0.62, green: 0.42, blue: 0.95))
        case "simulator-runtimes": return .init(title: tr("Simulator runtimes"), symbol: "iphone", color: Color(red: 0.78, green: 0.40, blue: 0.90))
        case "homebrew": return .init(title: "Homebrew", symbol: "mug.fill", color: Color(red: 0.90, green: 0.62, blue: 0.30))
        case "trash": return .init(title: tr("Trash"), symbol: "trash.fill", color: Color(red: 0.55, green: 0.58, blue: 0.62))
        case "temp": return .init(title: tr("Temporary files"), symbol: "clock.arrow.circlepath", color: Color(red: 0.92, green: 0.40, blue: 0.45))
        case "apple-assets": return .init(title: tr("Apple downloads"), symbol: "apple.logo", color: systemGrey)
        case "system-data": return .init(title: tr("System-wide data"), symbol: "gearshape.2.fill", color: systemGrey)
        case "macos": return .init(title: "macOS", symbol: "laptopcomputer", color: systemGrey)
        case "swap": return .init(title: tr("Swap"), symbol: "memorychip.fill", color: systemGrey)
        case "volumes": return .init(title: tr("Other volumes"), symbol: "externaldrive.fill", color: systemGrey)
        case "other": return .init(title: tr("Not attributed"), symbol: "questionmark.folder.fill", color: Color(white: 0.42))
        default: return .init(title: nil, symbol: "folder.fill", color: Color(white: 0.5))
        }
    }

    static func split(_ entries: [SpaceOverview.Entry]) -> (yours: [SpaceOverview.Entry], system: [SpaceOverview.Entry]) {
        (entries.filter { !systemIDs.contains($0.id) }, entries.filter { systemIDs.contains($0.id) })
    }

    struct Segment: Identifiable {
        var id: String
        var title: String
        var color: Color
        var bytes: Int64
    }

    /// The bar: the biggest of your places in their colours, the rest of yours as one, and macOS's
    /// share in grey. Scaled down when hard links make the headings add up to more than is used.
    static func segments(_ entries: [SpaceOverview.Entry], used: Int64, shown: Int = 6) -> [Segment] {
        let (yours, system) = split(entries)
        let sorted = yours.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        var out = sorted.prefix(shown).map { e in
            let s = of(e.id)
            return Segment(id: e.id, title: s.title ?? e.title, color: s.color, bytes: e.bytes)
        }
        let rest = sorted.dropFirst(shown).reduce(Int64(0)) { $0 + $1.bytes }
        if rest > 0 { out.append(Segment(id: "rest", title: tr("Other"), color: Color(white: 0.7), bytes: rest)) }
        let sys = system.reduce(Int64(0)) { $0 + $1.bytes }
        if sys > 0 { out.append(Segment(id: "system", title: tr("Managed by macOS"), color: systemGrey.opacity(0.6), bytes: sys)) }
        let total = out.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > used, total > 0 else { return out }
        let scale = Double(used) / Double(total)
        return out.map { var s = $0; s.bytes = Int64(Double(s.bytes) * scale); return s }
    }
}

