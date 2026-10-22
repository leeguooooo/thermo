import AppKit
import Charts
import CleanKit
import SwiftUI
import ThermoL10n

/// The Memory page's readings: the breakdown, every program by memory, and the ones that look
/// like they leak. Sampled every 5 s while the page is open; nothing runs otherwise.
@MainActor
final class MemoryModel: ObservableObject {
    static let shared = MemoryModel()

    @Published private(set) var activity: MemoryActivity?
    @Published private(set) var breakdown: MemoryBreakdown?
    @Published private(set) var programs: [MemoryProgram] = []
    @Published private(set) var unreadableCount = 0
    @Published private(set) var inventoryAvailable = false
    @Published private(set) var sampled: Date?
    @Published private(set) var suspects: [MemorySuspect] = []
    @Published private(set) var day: [PulseRecord] = []
    @Published private(set) var programReadings: [ProgramMemoryRecord] = []
    private var liveReadings: [ProgramMemoryRecord] = []
    private var historyReadings: [ProgramMemoryRecord] = []
    private var timer: Timer?
    private var sampling = false
    private var dayLoaded = Date.distantPast
    private var generation = UUID()
    private var cancellation: ScanCancellation?
    private var visibility = SamplingLeases()
    struct Reading: Sendable {
        var breakdown: MemoryBreakdown?
        var inventory: MemoryInventory
        var history: [ProgramMemoryRecord]
    }
    private let read: @Sendable (ScanCancellation) -> Reading
    private let readDay: @Sendable () -> [PulseRecord]
    private let readHistory: @Sendable (ScanCancellation) -> [ProgramMemoryRecord]
    init(read: @escaping @Sendable (ScanCancellation) -> Reading = { MemoryModel.readLive($0) },
         readHistory: @escaping @Sendable (ScanCancellation) -> [ProgramMemoryRecord] = { token in
             token.isCancelled ? [] : PulseRecorder.shared.programHistory.records(since: Date().addingTimeInterval(-PulseHistory.keep))
         },
         readDay: @escaping @Sendable () -> [PulseRecord] = { PulseRecorder.shared.history.records(since: Date().addingTimeInterval(-PulseHistory.keep)) }) {
        self.read = read; self.readHistory = readHistory; self.readDay = readDay
    }
    nonisolated private static func readLive(_ cancellation: ScanCancellation) -> Reading {
        let b = MemoryBreakdown.read()
        let inventory = MemoryInventory.collect(cancelled: { cancellation.isCancelled })
        return Reading(breakdown: b, inventory: inventory, history: [])
    }
    var samplingActive: Bool { timer != nil }
    var sampleInFlight: Bool { sampling }
    func setVisible(_ active: Bool, owner: UUID) {
        visibility.set(owner, active: active)
        if visibility.active { start() } else { stop() }
    }

    func start() {
        guard timer == nil else { return }
        generation = UUID()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        sample()
    }

    func stop() { timer?.invalidate(); timer = nil; generation = UUID(); cancellation?.cancel() }

    func sample() {
        guard timer != nil, !sampling else { return }
        sampling = true
        let token = generation
        let cancellation = ScanCancellation()
        self.cancellation = cancellation
        let read = self.read, readHistory = self.readHistory
        if Date().timeIntervalSince(dayLoaded) >= 60 { loadDay() }
        Task.detached(priority: .userInitiated) {
            let reading = read(cancellation)
            let b = reading.breakdown, inventory = reading.inventory
            // Current readings must not wait behind historical file I/O or JSON decoding.
            let published = await MainActor.run {
                guard self.generation == token, !cancellation.isCancelled else { return false }
                // App action identity is captured for each original context, never for merged groups.
                let applications = NSWorkspace.shared.runningApplications
                let programs = inventory.programs.map { program in
                    let contexts = program.contexts.map { h -> MachinePulse.Hog in
                        var h = h
                        if let path = h.app, let app = applications.first(where: { $0.bundleURL?.standardizedFileURL.path == path }) {
                            h.applicationIdentity = ProcessTable.identity(app.processIdentifier)
                        }
                        return h
                    }
                    return MemoryProgram(id: program.id, name: program.name, contexts: contexts)
                }
                self.programs = programs
                self.unreadableCount = inventory.unreadableCount
                self.inventoryAvailable = inventory.available
                self.sampled = inventory.sampled
                let entries = programs.map(\.historyEntry)
                let now = inventory.sampled
                if inventory.available {
                    self.liveReadings.append(ProgramMemoryRecord(entries, at: now))
                    self.liveReadings.removeAll { now.timeIntervalSince($0.t) > 3600 }
                }
                if !reading.history.isEmpty { self.historyReadings = reading.history }
                self.updateHistory(programs: entries, now: now)
                self.activity = b.flatMap { MemoryActivity(previous: self.breakdown, current: $0) }
                self.breakdown = b
                return true
            }
            let history = published && !cancellation.isCancelled ? readHistory(cancellation) : nil
            await MainActor.run {
                self.sampling = false
                self.cancellation = nil
                guard self.generation == token, !cancellation.isCancelled else {
                    // Both inventory and history drain before a reopened page starts another read.
                    if self.timer != nil { self.sample() }
                    return
                }
                if let history {
                    self.historyReadings = reading.history + history
                    self.updateHistory(programs: self.programs.map(\.historyEntry), now: inventory.sampled)
                }
            }
        }
    }

    private func updateHistory(programs: [MachinePulse.Hog], now: Date) {
        historyReadings.removeAll { now.timeIntervalSince($0.t) > PulseHistory.keep }
        programReadings = (historyReadings + liveReadings).sorted { $0.t < $1.t }
        suspects = MemorySuspects.find(programs: programs, history: programReadings, now: now)
    }

    func loadDay() {
        dayLoaded = Date()
        let token = generation
        let readDay = self.readDay
        Task.detached(priority: .utility) {
            let records = readDay()
            await MainActor.run { if self.generation == token { self.day = records } }
        }
    }
}

struct MemoryPage: View {
    @ObservedObject var model: MemoryModel
    @ObservedObject private var pulse = SystemPulse.shared
    let open: (MainPage) -> Void
    @State private var hours = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Set<String> = {
        // Offscreen review can open a named program without invoking any process action.
        let args = CommandLine.arguments
        guard args.contains("--main"), let i = args.firstIndex(of: "--inspect-memory"), i + 1 < args.count else { return [] }
        let name = args[i + 1].lowercased()
        return ["program:cmd:" + name, "program:app:" + name]
    }()
    @State private var confirming: MachinePulse.Hog?
    @State private var restartTarget: MachinePulse.Hog?
    @State private var showAll = false
    @State private var search = ""
    @State private var expandedContexts: Set<String> = []
    @State private var sortByResident = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let b = model.breakdown {
                    if b.swapBlocked { swapBlockedBanner(b) }
                    breakdownCard(b)
                    if !model.suspects.isEmpty { suspectsCard }
                    programsCard
                    trendCard
                } else {
                    SkeletonList(rows: 3)
                    SkeletonList(rows: 6)
                }
            }
            .frame(maxWidth: Theme.pageWidth, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pageTop).padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .samplingWhileVisible { owner, active in
            model.setVisible(active, owner: owner)
            if active { pulse.hold() } else { pulse.release() }
        }
        .sheet(item: $confirming) { h in
            ConfirmSheet(title: h.app != nil ? tr("Quit %1$@?", h.name) : tr("End %1$@?", h.name),
                         summary: h.app != nil ? tr("The app is asked to quit, the same as ⌘Q; it can save your work first.")
                                                     : tr("The process is asked to stop (SIGTERM). Unsaved work in it may be lost."),
                         destructive: h.app == nil, heading: tr("What will run"),
                         lines: h.app != nil ? [tr("quit %1$@", h.app!)] : h.pids.map { "kill -TERM \($0)" },
                         footnote: tr("Thermo never stops system processes, AI agent sessions or itself."),
                         confirmTitle: h.app != nil ? tr("Quit") : tr("End"),
                         confirm: { confirming = nil; pulse.quit(h); resample() }, cancel: { confirming = nil })
        }
        .sheet(item: $restartTarget) { h in
            ConfirmSheet(title: tr("Restart %1$@?", h.name),
                         summary: MachinePulse.sentences(tr("It is asked to quit, the same as ⌘Q (it can save first), then opened again. Thermo then checks whether its memory use decreased."),
                                                         MachinePulse.restartNote(BrowserSession.windows(for: h.name))),
                         destructive: BrowserSession.windows(for: h.name) == .unknown, heading: tr("What will run"),
                         lines: [tr("quit %1$@", h.app ?? h.name), tr("open %1$@", h.app ?? h.name)]
                            + (BrowserSession.windows(for: h.name) == .thermoReopensTabs ? [tr("save its tabs, then open them again")] : []),
                         footnote: tr("If it is still running after a minute (for example asking to save), Thermo stops and does not reopen it."),
                         confirmTitle: tr("Restart"),
                         confirm: { restartTarget = nil; pulse.restart(h); resample() }, cancel: { restartTarget = nil })
        }
    }

    func resample() {
        for delay in [2.0, 8.0, 20.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { model.sample() } }
    }

    // MARK: Header

    var header: some View {
        PageHeader(title: tr("Memory"), subtitle: model.breakdown?.summary ?? tr("Reading memory…"))
    }

    func swapBlockedBanner(_ b: MemoryBreakdown) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "externaldrive.fill.badge.exclamationmark").foregroundStyle(Theme.danger).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Limited disk space for swap")).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Text(tr("Only %1$@ of disk capacity is available to swap. This may restrict memory management; free space, then check again.",
                        ByteFormat.string(b.diskAvailable ?? b.diskFree ?? 0)))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(tr("Free disk space")) { open(.disk(.home)) }.buttonStyle(PillButtonStyle(prominent: true, color: Theme.danger))
        }
        .padding(14).glass()
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.danger.opacity(0.45)))
    }

    // MARK: Breakdown

    struct Slice: Identifiable { let id: String; let title: String; let bytes: UInt64; let color: Color; let help: String }

    func slices(_ b: MemoryBreakdown) -> [Slice] {
        [Slice(id: "app", title: tr("Apps"), bytes: b.app, color: Theme.accent, help: tr("Memory programs asked for and still hold.")),
         Slice(id: "wired", title: tr("Wired"), bytes: b.wired, color: Color(red: 1.0, green: 0.62, blue: 0.32), help: tr("macOS itself and drivers; never compressed or moved to the disk.")),
         Slice(id: "compressed", title: tr("Compressed"), bytes: b.compressed, color: Color(red: 0.70, green: 0.52, blue: 1.0),
               help: tr("%1$@ of memory squeezed into this space, instead of going to the disk.", MemoryFormat.string(bytes: b.compressedHolds))),
         Slice(id: "cached", title: tr("Cached files"), bytes: b.cached, color: Color(red: 0.35, green: 0.80, blue: 0.78), help: tr("Copies of files kept in spare memory; handed back the moment a program needs it.")),
         Slice(id: "free", title: tr("Free"), bytes: b.free, color: Color.white.opacity(0.28), help: tr("Not used at all."))]
    }

    func breakdownCard(_ b: MemoryBreakdown) -> some View {
        let parts = slices(b)
        let sum = Double(max(1, parts.reduce(0) { $0 + $1.bytes }))
        let pressureColor = b.pressure == .unknown ? Theme.textSecondary : b.pressure == .normal ? Theme.good : b.pressure == .warning ? Theme.caution : Theme.danger
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MemoryFormat.string(bytes: b.used)).font(Theme.figure(.hero)).foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text(tr("used of %1$@", MemoryFormat.string(bytes: b.total))).font(Theme.body).foregroundStyle(Theme.textSecondary)
                Spacer()
                StatusTag(text: tr("Pressure: %1$@", MachinePulse.memoryName(b.pressure)), color: pressureColor)
            }
            // The segments slide to their new widths as memory moves between kinds.
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(parts) { s in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(s.color)
                            .frame(width: max(0, (g.size.width - 8) * CGFloat(Double(s.bytes) / sum)))
                            .help("\(s.title) \(MemoryFormat.string(bytes: s.bytes)): \(s.help)")
                    }
                }
                .animation(Theme.gentle.unlessReduced(reduceMotion), value: parts.map(\.bytes))
            }
            .frame(height: 10).clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous)).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(parts) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 8, height: 8)
                            Text(s.title).font(Theme.label).foregroundStyle(Theme.textTertiary)
                        }
                        Text(MemoryFormat.string(bytes: s.bytes)).font(Theme.figure(.row, weight: .medium)).foregroundStyle(Theme.textPrimary)
                            .contentTransition(.numericText())
                    }
                    .help(s.help)
                    .accessibilityElement(children: .combine)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: "externaldrive").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.caution)
                        Text(tr("Swap on the disk")).font(Theme.label).foregroundStyle(Theme.textTertiary)
                        InfoButton(text: swapExplanation(b), title: tr("What swap is"))
                    }
                    Text(b.swapReadable == false ? "—" : b.swapFiles > 0 ? tr("%1$@ of %2$@", MemoryFormat.string(bytes: b.swapUsed), MemoryFormat.string(bytes: b.swapFiles)) : tr("none"))
                        .font(Theme.figure(.row, weight: .medium)).foregroundStyle(b.swapUsed >= 4 << 30 ? Theme.caution : Theme.textPrimary)
                }
                .accessibilityElement(children: .combine)
            }
            Group {
                if let activity = model.activity {
                    Text(tr("Current swap activity: read %1$@/s · write %2$@/s",
                            MemoryFormat.string(mebibytes: activity.swapReadBytesPerSecond / 1_048_576),
                            MemoryFormat.string(mebibytes: activity.swapWriteBytesPerSecond / 1_048_576)))
                } else {
                    Text(tr("Current swap activity: waiting for comparable readings"))
                }
            }
            .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
            .padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .padding(18).glass()
    }

    // MARK: Trend

    var trendRecords: [PulseRecord] {
        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        return model.day.filter { $0.t >= since }
    }

    var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("Memory and swap")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary)
                InfoButton(text: tr("Shaded: memory pressure was high. Dashed line: installed memory."))
                Spacer()
                ThermoTabs(selection: $hours, options: [(1, "1h"), (6, "6h"), (24, "24h")], size: .small, label: tr("Time span"))
            }
            let records = trendRecords
            if records.count >= 2 {
                Chart {
                    ForEach(records, id: \.t) { r in
                        if let used = r.usedMB {
                            AreaMark(x: .value("t", r.t), y: .value("GiB", Double(used) / 1024), series: .value("k", "used"))
                                .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0)],
                                                                startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("t", r.t), y: .value("GiB", Double(used) / 1024), series: .value("k", "used"))
                                .foregroundStyle(by: .value("k", tr("Memory used")))
                                .interpolationMethod(.monotone)
                        }
                        LineMark(x: .value("t", r.t), y: .value("GiB", Double(r.swapUsedMB) / 1024), series: .value("k", "swap"))
                            .foregroundStyle(by: .value("k", tr("Swap")))
                            .interpolationMethod(.monotone)
                        if r.memory.isHigh {
                            RuleMark(x: .value("t", r.t)).foregroundStyle(r.memory == .critical ? Color.red.opacity(0.25) : Color.orange.opacity(0.18))
                        }
                    }
                    if let b = model.breakdown {
                        RuleMark(y: .value("GiB", Double(b.total) / 1_073_741_824)).foregroundStyle(Theme.textTertiary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartForegroundStyleScale([tr("Memory used"): Theme.accent, tr("Swap"): Theme.caution])
                .chartLegend(position: .top, alignment: .trailing)
                .chartYAxis { AxisMarks { v in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) GiB").foregroundStyle(Theme.textTertiary) } }
                } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Theme.textTertiary)
                } }
                .frame(height: 160)
            } else {
                EmptyState(symbol: "chart.xyaxis.line", title: tr("Thermo records memory once a minute; the chart fills in as it does."))
                    .padding(.vertical, -24)
            }
        }
        .padding(16).glass()
    }

    // MARK: Suspects

    var suspectsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tr("Programs growing in memory"), systemImage: "chart.line.uptrend.xyaxis")
                .font(Theme.sectionTitle).foregroundStyle(Theme.caution)
            ForEach(model.suspects) { s in
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                        Text(s.text).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(MemoryFormat.string(kibibytes: s.memoryKB)).font(Theme.figure(.row)).foregroundStyle(Theme.textPrimary)
                    Button(tr("Inspect")) { expanded.insert(s.id); search = s.name }.buttonStyle(PillButtonStyle()).controlSize(.small)
                }
            }
        }
        .padding(16).glass()
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.caution.opacity(0.3)))
    }

    // MARK: Programs

    var visiblePrograms: [MemoryProgram] {
        let filtered = model.programs.filter { p in
            search.isEmpty || p.name.localizedCaseInsensitiveContains(search)
                || p.projects.contains { $0.localizedCaseInsensitiveContains(search) }
                || p.contexts.contains { h in h.pids.contains { String($0).contains(search) } }
        }
        return filtered.sorted { a, b in
            let av = sortByResident ? a.residentKB ?? -1 : (a.memoryMetric == .unavailable || a.memoryMetric == .mixed ? -1 : a.memoryKB)
            let bv = sortByResident ? b.residentKB ?? -1 : (b.memoryMetric == .unavailable || b.memoryMetric == .mixed ? -1 : b.memoryKB)
            return av == bv ? a.id < b.id : av > bv
        }
    }

    var programsCard: some View {
        let visible = visiblePrograms
        let list = showAll ? visible : Array(visible.prefix(15))
        let top = Double(max(1, visible.map { sortByResident ? $0.residentKB ?? 0 : ($0.memoryMetric == .mixed || $0.memoryMetric == .unavailable ? 0 : $0.memoryKB) }.max() ?? 1))
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: tr("Programs by memory")) {
                HStack(spacing: Theme.Space.xs) {
                    if let sampled = model.sampled {
                        Text(sampled, style: .time).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                    // The column is easy to read as RAM or swap; what it is stays one click away.
                    InfoButton(text: tr("Memory footprint is Activity Monitor's Memory column: what a program is charged for, compressed memory included, some of which may be in swap. Adding programs up gives neither the used memory above nor the swap size; resident memory counts shared pages and cannot be subtracted from footprint to get swap."),
                               title: tr("Memory footprint"))
                }
            }
            HStack(spacing: 10) {
                SearchField(text: $search, prompt: tr("Search programs, projects or PID"))
                ThermoTabs(selection: $sortByResident, options: [(false, tr("Memory footprint")), (true, tr("Resident memory"))],
                           size: .small, label: tr("Sort by"))
            }
            if !model.inventoryAvailable {
                Text(tr("Process readings unavailable. Try refreshing.")).font(Theme.caption).foregroundStyle(Theme.caution)
            }
            VStack(alignment: .leading, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(tr("Program / project / process")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(tr("Memory footprint")).frame(width: 84, alignment: .trailing)
                        Text(tr("Resident memory")).frame(width: 84, alignment: .trailing)
                        Spacer().frame(width: 190)
                    }.frame(minWidth: 640)
                    Text(tr("Memory footprint") + " · " + tr("Resident memory"))
                }
                .font(Theme.label).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                ForEach(list) { p in
                    InspectorDivider(inset: 14)
                    programRow(p, top: top)
                }
                if visible.count > 15 {
                    InspectorDivider(inset: 0)
                    Button(showAll ? tr("Show fewer") : tr("Show all %1$@", String(visible.count))) {
                        withAnimation(Theme.standard.unlessReduced(reduceMotion)) { showAll.toggle() }
                    }
                    .buttonStyle(.plain).font(Theme.secondary.weight(.medium)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 9).contentShape(Rectangle()).hoverHighlight()
                }
            }
            .glass()
            if model.unreadableCount > 0 {
                Text(tr("%1$@ processes have no footprint reading; resident estimates and missing values are marked.", String(model.unreadableCount)))
                    .font(Theme.caption).foregroundStyle(Theme.caution)
            }
            ForEach([pulse.quitProblem, pulse.restartProblem, pulse.actionFeedback].compactMap { $0 }, id: \.self) { t in
                NoticeBanner(text: t)
            }
        }
    }

    func metric(_ memory: Int, _ kind: MachinePulse.MemoryMetric?) -> String {
        if kind == .unavailable || kind == .mixed { return "—" }
        return (kind == .residentEstimate ? "≈ " : "") + MemoryFormat.string(kibibytes: memory)
    }

    func toggleProgram(_ id: String) {
        withAnimation(Theme.standard.unlessReduced(reduceMotion)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    func programRow(_ program: MemoryProgram, top: Double) -> some View {
        let isOpen = expanded.contains(program.id)
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Button { toggleProgram(program.id) } label: { DisclosureChevron(expanded: isOpen) }
                    .buttonStyle(.plain).accessibilityLabel(tr("Inspect %1$@", program.name))
                if let app = program.contexts.first?.app {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable().frame(width: 22, height: 22)
                } else {
                    Image(systemName: "terminal").font(Theme.label).foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.07)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(program.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text("×\(program.processCount)").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                    Text(program.contexts.first?.app != nil ? tr("App · expand for processes") : tr("%1$@ projects · expand for processes", String(program.projects.count)))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule().fill(Theme.accent.opacity(0.8)).frame(width: g.size.width * CGFloat(min(1, max(0, Double(sortByResident ? program.residentKB ?? 0 : (program.memoryMetric == .mixed || program.memoryMetric == .unavailable ? 0 : program.memoryKB)) / top))))
                    }
                }.frame(width: 56, height: 4).accessibilityHidden(true)
                    .animation(Theme.gentle.unlessReduced(reduceMotion), value: program.memoryKB)
                Text(metric(program.memoryKB, program.memoryMetric)).foregroundStyle(Theme.textPrimary).frame(width: 84, alignment: .trailing)
                    .contentTransition(.numericText())
                Text(program.residentKB.map { MemoryFormat.string(kibibytes: $0) } ?? "—").foregroundStyle(Theme.textTertiary).frame(width: 84, alignment: .trailing)
                Group {
                    if let target = program.actionTarget { actions(target, emphasizeRestart: false) } else { Color.clear.frame(height: 1) }
                }.frame(width: 190, alignment: .trailing)
            }.frame(minWidth: 640)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button { if isOpen { expanded.remove(program.id) } else { expanded.insert(program.id) } } label: {
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        }.buttonStyle(.plain).accessibilityLabel(tr("Inspect %1$@", program.name))
                        Text(program.name).font(Theme.rowTitle).lineLimit(1).truncationMode(.middle)
                        Text("×\(program.processCount)").foregroundStyle(Theme.textSecondary).fixedSize()
                        Spacer(minLength: 0)
                        Text(metric(program.memoryKB, program.memoryMetric)).fixedSize()
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(program.contexts.first?.app != nil ? tr("App · expand for processes") : tr("%1$@ projects · expand for processes", String(program.projects.count)))
                                .lineLimit(1)
                            Text(tr("Resident memory") + ": " + (program.residentKB.map { MemoryFormat.string(kibibytes: $0) } ?? "—"))
                        }.font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 4)
                        if let target = program.actionTarget { actions(target, emphasizeRestart: false) }
                    }
                }
            }.font(Theme.secondary.monospacedDigit())
            .contentShape(Rectangle())
            .onTapGesture { toggleProgram(program.id) }
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    programTrend(program)
                    ForEach(program.contexts) { h in contextRow(h, showActions: program.actionTarget == nil) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .hoverHighlight()
    }

    @ViewBuilder func programTrend(_ program: MemoryProgram) -> some View {
        let points = MemoryTrends.points(for: program.id, records: model.programReadings)
        if let first = points.first, let last = points.last, points.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Program footprint: %1$@ → %2$@ over %3$@",
                        MemoryFormat.string(kibibytes: first.memoryKB), MemoryFormat.string(kibibytes: last.memoryKB),
                        MemorySuspects.duration(last.sampled.timeIntervalSince(first.sampled))))
                Chart(points) { p in
                    LineMark(x: .value("t", p.sampled), y: .value("GiB", Double(p.memoryKB) / 1_048_576))
                        .foregroundStyle(Theme.accent).interpolationMethod(.monotone)
                }.frame(height: 65).chartXAxis(.hidden)
                    .chartYAxis { AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.1f GiB", d)) } }
                    } }
                Text(tr("Program totals include changing workloads; growth alone does not prove a leak."))
                    .foregroundStyle(Theme.textSecondary)
            }.font(Theme.caption).padding(.leading, 32).padding(.trailing, 16)
        } else {
            Text(tr("Program trend appears after comparable samples are collected."))
                .font(Theme.caption).foregroundStyle(Theme.textSecondary).padding(.leading, 32)
        }
    }

    func contextRow(_ h: MachinePulse.Hog, showActions: Bool) -> some View {
        let isOpen = expandedContexts.contains(h.id)
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Button { if isOpen { expandedContexts.remove(h.id) } else { expandedContexts.insert(h.id) } } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").frame(width: 10)
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.project ?? h.app ?? tr("Unknown project")).lineLimit(1).truncationMode(.middle).help(h.project ?? h.app ?? "")
                    Text(detail(h)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(metric(h.memoryKB, h.memoryMetric)).frame(width: 84, alignment: .trailing)
                Text(h.residentKB.map { MemoryFormat.string(kibibytes: $0) } ?? "—").foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .trailing)
                Group { if showActions { actions(h, emphasizeRestart: false) } else { Color.clear.frame(height: 1) } }
                    .frame(width: 190, alignment: .trailing)
            }
                .frame(minWidth: 600)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button { if isOpen { expandedContexts.remove(h.id) } else { expandedContexts.insert(h.id) } } label: {
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        }.buttonStyle(.plain)
                        Text(h.project ?? h.app ?? tr("Unknown project")).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(metric(h.memoryKB, h.memoryMetric)).fixedSize()
                    }
                    Text(detail(h)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    HStack {
                        Text(tr("Resident memory") + ": " + (h.residentKB.map { MemoryFormat.string(kibibytes: $0) } ?? "—"))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 4)
                        if showActions { actions(h, emphasizeRestart: false) }
                    }
                }
            }
            if isOpen, let parts = h.parts {
                ForEach(parts, id: \.pid) { p in
                    ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("\(MachinePulse.roleName(p.role)) · PID \(p.pid)").frame(maxWidth: .infinity, alignment: .leading)
                        Text(metric(p.memoryKB, p.memoryMetric)).frame(width: 84, alignment: .trailing)
                        Text(p.residentKB.map { MemoryFormat.string(kibibytes: $0) } ?? "—").frame(width: 84, alignment: .trailing)
                        Spacer().frame(width: 190)
                    }.frame(minWidth: 600)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(MachinePulse.roleName(p.role)) · PID \(p.pid)")
                            let footprint = metric(p.memoryKB, p.memoryMetric)
                            let resident = p.residentKB.map { MemoryFormat.string(kibibytes: $0) } ?? "—"
                            let detail = "\(tr("Memory footprint")): \(footprint) · \(tr("Resident memory")): \(resident)"
                            Text(detail)
                        }
                    }.foregroundStyle(Theme.textSecondary).padding(.leading, 20)
                }
            }
        }.font(Theme.caption.monospacedDigit()).padding(.leading, 32)
    }

    func detail(_ h: MachinePulse.Hog) -> String {
        var parts = [tr("%1$@ processes", String(h.pids.count))]
        if let o = h.owner { parts.append(tr("started by %1$@", o)) }
        if let up = h.uptime { parts.append(tr("oldest process: %1$@", MemorySuspects.duration(up))) }
        if !h.quittable { parts.append(tr("Protected from stop actions")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder func actions(_ h: MachinePulse.Hog, emphasizeRestart: Bool) -> some View {
        HStack(spacing: 6) {
            if ChromeInspector.isBrowser(h.name) {
                Button(tr("Pages")) {
                    _ = AppModels.shared.browser(h.name, memoryKB: h.memoryKB, gpuKB: h.parts?.first { $0.role == "GPU" }?.memoryKB)
                    open(.browser(h.name))
                }
                .buttonStyle(PillButtonStyle()).controlSize(.small).help(tr("Which of its pages use the memory"))
            }
            if h.quittable && h.app != nil {
                Button(pulse.restarting == h.name ? tr("Restarting…") : tr("Restart")) { restartTarget = h }
                    .buttonStyle(PillButtonStyle(prominent: emphasizeRestart, color: Theme.caution)).controlSize(.small)
                    .disabled(pulse.restarting != nil || pulse.quitting.contains(h.id))
            }
            if h.quittable {
                Button(pulse.quitting.contains(h.id) ? tr("Stopping…") : h.app != nil ? tr("Quit") : tr("End")) { confirming = h }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
                    .disabled(pulse.quitting.contains(h.id) || pulse.restarting == h.name)
            }
        }
    }

    // MARK: Swap

    func swapExplanation(_ b: MemoryBreakdown) -> String {
        [tr("When programs need more memory than the Mac has, macOS first compresses memory that is not being used, then writes some of it to swap files on the disk. Reading it back from the disk is far slower than memory, which is when the Mac feels slow."),
         tr("Swap files stay until memory frees up and macOS removes them by itself; there is nothing to delete by hand. Restarting the program that holds the memory, or the Mac, gives it back."),
         tr("Swap needs free disk space. With less than about 5 GB free, macOS cannot grow it and asks you to force quit apps."),
         tr("Since startup %1$@ was written to swap and %2$@ read back.",
            MemoryFormat.string(bytes: b.swapOuts * UInt64(vm_kernel_page_size)), MemoryFormat.string(bytes: b.swapIns * UInt64(vm_kernel_page_size)))]
            .joined(separator: "\n\n")
    }
}
