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
         read: @escaping @Sendable (ScanCancellation, ((SpaceOverview.Entry) -> Void)?) -> SpaceOverview = { SpaceOverview.measure(onEntry: $1, cancellation: $0, lowPriority: true) },
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
    @State private var open: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                if let live = model.diskSpace {
                    capacityBar(capacity: live.capacityBytes, free: live.availableBytes)
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
                if model.entries.isEmpty {
                    if model.stopped {
                        EmptyState(symbol: "pause.circle", title: tr("No folders finished before stopping. Measure again to continue."))
                    } else {
                        SkeletonList(rows: 6)
                    }
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionHeader(title: tr("Where your disk space is")) {
                            if model.measuring, model.overview != nil {
                                InfoButton(text: tr("Categories update as folders finish; unfinished totals are lower bounds."))
                            }
                            if !model.measuring, let over = model.overview?.overcounted {
                                InfoButton(text: tr("The headings add up to %1$@ more than the disk uses: hard links (pnpm), APFS clones and files written while measuring count in each place.", ByteFormat.string(over)))
                            }
                        }
                        InspectorPanel {
                            ForEach(Array(model.entries.enumerated()), id: \.element.id) { i, e in
                                if i > 0 { InspectorDivider(inset: Theme.Space.m + 2) }
                                row(e)
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
        return tr("measured %1$@", at.formatted(date: .abbreviated, time: .shortened))
    }

    /// The page's hero: how full the disk is, as one figure and one bar.
    func capacityBar(capacity: Int64, free: Int64, purgeable: Int64 = 0) -> some View {
        let usedBytes = max(0, capacity - free)
        let used = capacity > 0 ? min(1, max(0, Double(usedBytes) / Double(capacity))) : 0
        let fill = used > 0.95 ? Theme.danger : used > 0.85 ? Theme.caution : Theme.accent
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(ByteFormat.string(free)).font(Theme.figure(.hero)).foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text(tr("free")).font(Theme.body).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(String(format: "%.0f%%", used * 100)).font(Theme.figure(.large)).foregroundStyle(fill)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.white.opacity(0.07))
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(fill)
                        .frame(width: g.size.width * CGFloat(used))
                        .animation(Theme.gentle.unlessReduced(reduceMotion), value: used)
                }
            }
            .frame(height: 8)
            Text(tr("%1$@ used of %2$@ · %3$@ free", ByteFormat.string(usedBytes), ByteFormat.string(capacity), ByteFormat.string(free))
                 + (purgeable > 1_000_000_000 ? " · " + tr("%1$@ more can be freed by macOS on demand", ByteFormat.string(purgeable)) : ""))
                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.l + 2).glass()
    }

    func entryHeader(_ entry: SpaceOverview.Entry, expanded: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            if entry.children.isEmpty {
                Circle().fill(Theme.textTertiary).frame(width: 5, height: 5).frame(width: 22)
            } else {
                DisclosureChevron(expanded: expanded)
            }
            Text(entry.title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(entry.sizeText).font(Theme.figure(.row)).foregroundStyle(entry.effectiveSizeState == .complete ? Theme.textPrimary : Theme.caution)
                .contentTransition(.numericText())
        }
        .contentShape(Rectangle())
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
        case "home-tools": return (tr("Find cleanup candidates"), .aiSessions)
        case "developer", "simulator-runtimes": return (tr("Review Xcode cleanup"), .xcode)
        case "homebrew": return (tr("Scan developer caches"), .devCaches)
        case "temp": return (tr("Scan temporary files and leftovers"), .system)
        case "caches", "other": return (tr("Find cleanup candidates"), nil)
        default: return nil
        }
    }

    func row(_ e: SpaceOverview.Entry) -> some View {
        let total = max(1, model.diskSpace.map { $0.capacityBytes - $0.availableBytes } ?? model.overview?.used ?? model.entries.reduce(0) { $0 + $1.bytes })
        let expanded = open.contains(e.id)
        return VStack(alignment: .leading, spacing: Theme.Space.s - 2) {
            if e.children.isEmpty {
                entryHeader(e, expanded: expanded)
            } else {
                Button {
                    withAnimation(Theme.standard.unlessReduced(reduceMotion)) { if expanded { open.remove(e.id) } else { open.insert(e.id) } }
                } label: { entryHeader(e, expanded: expanded) }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Details for %1$@", e.title))
                .accessibilityValue(expanded ? tr("Expanded") : tr("Collapsed"))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule().fill(Theme.accent.opacity(0.75))
                        .frame(width: min(g.size.width, max(2, g.size.width * CGFloat(e.bytes) / CGFloat(total))))
                }
            }
            .frame(height: 4).padding(.leading, 30)
            if e.complete == false, let measured = e.measuredLocations, let total = e.totalLocations {
                Text(tr("%1$@ of %2$@ locations measured", String(measured), String(total)))
                    .font(Theme.caption).foregroundStyle(Theme.caution).padding(.leading, 30)
            }
            if let n = e.note { Text(n).font(Theme.caption).foregroundStyle(Theme.textTertiary).padding(.leading, 30) }
            if let a = e.action { actionLine(a).padding(.leading, 30) }
            if let route = Self.cleanupRoute(for: e.id) {
                Button(route.label) { openCleanup(route.category) }
                    .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(cleanupDisabled).padding(.leading, 30).padding(.top, 2)
            }
            if expanded {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(e.children) { c in
                        HStack(spacing: Theme.Space.s) {
                            Text(c.title).font(Theme.mono).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let a = c.action { actionLine(a) }
                            Text(c.sizeText).font(Theme.secondary.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                            if let p = c.path {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                .buttonStyle(.borderless).foregroundStyle(Theme.textTertiary).help(tr("Reveal in Finder"))
                            }
                        }
                    }
                }
                .padding(.leading, 30).padding(.top, Theme.Space.xs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.s + 2)
        .hoverHighlight()
    }
}
