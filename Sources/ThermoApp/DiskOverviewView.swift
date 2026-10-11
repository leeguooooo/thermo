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

    init(cached: (SpaceOverview, Date)? = SpaceOverview.cached(), diskSpace: DiskSpaceSnapshot? = .measure()) {
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

    func measure() {
        guard !measuring else { return }
        diskSpace = .measure()
        let generation = UUID()
        self.generation = generation
        measuring = true
        measurementLanguage = L10n.current.rawValue
        restartAfterCurrent = false
        stopping = false
        stopped = false
        partial = []
        let cancellation = ScanCancellation()
        self.cancellation = cancellation
        Task.detached(priority: .utility) {
            let o = SpaceOverview.measure(onEntry: { e in
                Task { @MainActor in
                    guard self.generation == generation, self.cancellation === cancellation, !cancellation.isCancelled else { return }
                    self.partial.append(e)
                }
            }, cancellation: cancellation, lowPriority: true)
            await MainActor.run {
                guard self.generation == generation else { return }
                o.save()
                let restart = self.restartAfterCurrent
                self.restartAfterCurrent = false
                if o.language != L10n.current.rawValue {
                    self.partial = []
                    self.stopped = !restart
                } else if o.cancelled == true {
                    self.partial = o.entries
                    self.stopped = true
                } else {
                    self.overview = o
                    self.diskSpace = .measure()
                    self.measuredAt = o.measuredAt
                }
                self.measuring = false
                self.stopping = false
                self.cancellation = nil
                if restart { self.measure() }
            }
        }
    }

    /// A cleanup invalidates cached breakdowns. Late callbacks from an old measurement
    /// must neither restore stale folders nor write their old overview back to disk.
    func invalidateAfterCleanup() {
        generation = UUID()
        cancellation?.cancel()
        cancellation = nil
        restartAfterCurrent = false
        measurementLanguage = nil
        measuring = false
        stopping = false
        stopped = false
        overview = nil
        measuredAt = nil
        partial = []
        diskSpace = .measure()
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
            self.overview = nil
            measuredAt = nil
            partial = []
            stopped = false
        }
    }

    func measureIfStale() {
        diskSpace = .measure()
        if overview != nil, !SpaceOverview.isCurrent(measuredAt: measuredAt) { invalidateAfterCleanup() }
        discardIncompatibleResults()
        if measuring {
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
    @State private var open: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let live = model.diskSpace {
                    capacityBar(capacity: live.capacityBytes, free: live.availableBytes)
                } else if let o = model.overview {
                    capacityBar(capacity: o.capacity, free: o.free, purgeable: o.purgeable)
                }
                if model.measuring, model.overview != nil {
                    Text(tr("Previous results stay visible until each location is measured again."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let unreadable = model.overview?.unreadable, !unreadable.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("%1$@ locations could not be read. Results may be incomplete.", String(unreadable.count)))
                            .font(.callout).foregroundStyle(.orange)
                        Button(tr("Open Full Disk Access")) { AppModels.shared.disk.openFullDiskAccess() }
                            .buttonStyle(PillButtonStyle())
                    }
                }
                if model.stopped {
                    Text(model.overview == nil ? tr("Measurement stopped. Only locations completed before stopping are shown.") : tr("Measurement stopped. Complete previous results are kept; newly measured locations may be partial."))
                        .font(.callout).foregroundStyle(.orange)
                }
                if model.entries.isEmpty && !model.stopped {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(tr("Measuring where your disk space is…")).foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.entries) { e in
                            row(e)
                            Divider()
                        }
                    }.padding(16).glass()
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 48).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .onAppear { model.measureIfStale() }
        .onDisappear { model.stop() }
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Where your disk space is")).font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.measuring {
                ProgressView().controlSize(.small)
                Button(model.stopping ? tr("Stopping…") : tr("Stop")) { model.stop() }.disabled(model.stopping)
            } else {
                Button { model.measure() } label: { Label(tr("Measure again"), systemImage: "arrow.clockwise") }
            }
        }
    }

    var subtitle: String {
        if model.measuring { return tr("measuring… %1$@ places so far", String(model.partial.count)) }
        guard let at = model.measuredAt else { return "" }
        return tr("measured %1$@", at.formatted(date: .abbreviated, time: .shortened))
    }

    func capacityBar(capacity: Int64, free: Int64, purgeable: Int64 = 0) -> some View {
        let usedBytes = max(0, capacity - free)
        return
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                let used = capacity > 0 ? min(1, max(0, CGFloat(usedBytes) / CGFloat(capacity))) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 5).fill(used > 0.95 ? Color.red : used > 0.85 ? Color.orange : Color.accentColor)
                        .frame(width: g.size.width * used)
                }
            }
            .frame(height: 12)
            Text(tr("%1$@ used of %2$@ · %3$@ free", ByteFormat.string(usedBytes), ByteFormat.string(capacity), ByteFormat.string(free))
                 + (purgeable > 1_000_000_000 ? " · " + tr("%1$@ more can be freed by macOS on demand", ByteFormat.string(purgeable)) : ""))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    func entryHeader(_ entry: SpaceOverview.Entry, expanded: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.children.isEmpty ? "circle.fill" : expanded ? "chevron.down" : "chevron.right")
                .font(.caption2).foregroundStyle(.secondary).frame(width: 12)
            Text(entry.title).font(.body)
            Spacer()
            Text(ByteFormat.string(entry.bytes)).font(.body.monospacedDigit())
        }
        .contentShape(Rectangle())
    }

    func row(_ e: SpaceOverview.Entry) -> some View {
        let total = max(1, model.diskSpace.map { $0.capacityBytes - $0.availableBytes } ?? model.overview?.used ?? model.entries.reduce(0) { $0 + $1.bytes })
        let expanded = open.contains(e.id)
        return VStack(alignment: .leading, spacing: 6) {
            if e.children.isEmpty {
                entryHeader(e, expanded: expanded)
            } else {
                Button {
                    if expanded { open.remove(e.id) } else { open.insert(e.id) }
                } label: { entryHeader(e, expanded: expanded) }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Details for %1$@", e.title))
                .accessibilityValue(expanded ? tr("Expanded") : tr("Collapsed"))
            }
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.6))
                    .frame(width: min(g.size.width, max(2, g.size.width * CGFloat(e.bytes) / CGFloat(total))))
            }
            .frame(height: 4).padding(.leading, 20)
            if let n = e.note { Text(n).font(.caption).foregroundStyle(.secondary).padding(.leading, 20) }
            if expanded {
                ForEach(e.children) { c in
                    HStack {
                        Text(c.title).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(ByteFormat.string(c.bytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        if let p = c.path {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless).help(tr("Reveal in Finder"))
                        }
                    }
                    .padding(.leading, 20)
                }
            }
        }
        .padding(.vertical, 8)

    }
}
