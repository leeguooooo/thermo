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
    private var timer: Timer?
    private var sampling = false
    private var dayLoaded = Date.distantPast
    private var generation = UUID()
    var samplingActive: Bool { timer != nil }
    var sampleInFlight: Bool { sampling }

    func start() {
        guard timer == nil else { return }
        generation = UUID()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil; generation = UUID() }

    func sample() {
        guard !sampling else { return }
        sampling = true
        let token = generation
        if Date().timeIntervalSince(dayLoaded) >= 60 { loadDay() }
        Task.detached(priority: .utility) {
            let b = MemoryBreakdown.read()
            let inventory = MemoryInventory.collect()
            let history = PulseRecorder.shared.programHistory.records(since: Date().addingTimeInterval(-PulseHistory.keep))
            await MainActor.run {
                self.sampling = false
                guard self.generation == token else { return }
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
                self.programReadings = (history + self.liveReadings).sorted { $0.t < $1.t }
                self.suspects = MemorySuspects.find(programs: entries, history: self.programReadings, now: now)
                self.activity = b.flatMap { MemoryActivity(previous: self.breakdown, current: $0) }
                self.breakdown = b
            }
        }
    }

    func loadDay() {
        dayLoaded = Date()
        let token = generation
        Task.detached(priority: .utility) {
            let records = PulseRecorder.shared.history.records(since: Date().addingTimeInterval(-PulseHistory.keep))
            await MainActor.run { if self.generation == token { self.day = records } }
        }
    }
}

struct MemoryPage: View {
    @ObservedObject var model: MemoryModel
    @ObservedObject private var pulse = SystemPulse.shared
    let open: (MainPage) -> Void
    @State private var hours = 6
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
                    swapExplainer(b)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 24)
        }
        .onAppear { model.start(); pulse.hold() }
        .onDisappear { model.stop(); pulse.release() }
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
        HStack(spacing: 14) {
            IconTile(symbol: "memorychip.fill", color: .green, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Memory")).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                Text(model.breakdown?.summary ?? tr("Reading memory…")).font(.callout).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    func swapBlockedBanner(_ b: MemoryBreakdown) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "externaldrive.fill.badge.exclamationmark").foregroundStyle(.red).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Limited disk space for swap")).font(.callout.weight(.semibold)).foregroundStyle(.white)
                Text(tr("Only %1$@ of disk capacity is available to swap. This may restrict memory management; free space, then check again.",
                        ByteFormat.string(b.diskAvailable ?? b.diskFree ?? 0)))
                    .font(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(tr("Free disk space")) { open(.disk(.home)) }.buttonStyle(PillButtonStyle(prominent: true, color: .red))
        }
        .padding(14).glass(radius: 14).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.5)))
    }

    // MARK: Breakdown

    struct Slice: Identifiable { let id: String; let title: String; let bytes: UInt64; let color: Color; let help: String }

    func slices(_ b: MemoryBreakdown) -> [Slice] {
        [Slice(id: "app", title: tr("Apps"), bytes: b.app, color: .green, help: tr("Memory programs asked for and still hold.")),
         Slice(id: "wired", title: tr("Wired"), bytes: b.wired, color: .orange, help: tr("macOS itself and drivers; never compressed or moved to the disk.")),
         Slice(id: "compressed", title: tr("Compressed"), bytes: b.compressed, color: .purple,
               help: tr("%1$@ of memory squeezed into this space, instead of going to the disk.", MemoryFormat.string(bytes: b.compressedHolds))),
         Slice(id: "cached", title: tr("Cached files"), bytes: b.cached, color: .blue, help: tr("Copies of files kept in spare memory; handed back the moment a program needs it.")),
         Slice(id: "free", title: tr("Free"), bytes: b.free, color: .gray, help: tr("Not used at all."))]
    }

    func breakdownCard(_ b: MemoryBreakdown) -> some View {
        let parts = slices(b)
        let sum = Double(max(1, parts.reduce(0) { $0 + $1.bytes }))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(MemoryFormat.string(bytes: b.used)).font(.system(size: 30, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                Text(tr("used of %1$@", MemoryFormat.string(bytes: b.total))).font(.callout).foregroundStyle(.white.opacity(0.6))
                Spacer()
                pill(tr("Pressure: %1$@", MachinePulse.memoryName(b.pressure)), color: b.pressure == .unknown ? .gray : b.pressure == .normal ? .green : b.pressure == .warning ? .orange : .red)
            }
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(parts) { s in
                        RoundedRectangle(cornerRadius: 3).fill(s.color.opacity(0.85))
                            .frame(width: max(0, (g.size.width - 8) * CGFloat(Double(s.bytes) / sum)))
                            .help("\(s.title) \(MemoryFormat.string(bytes: s.bytes)): \(s.help)")
                    }
                }
            }
            .frame(height: 14).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(parts) { s in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(s.color).frame(width: 8, height: 8).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.caption).foregroundStyle(.white.opacity(0.6))
                            Text(MemoryFormat.string(bytes: s.bytes)).font(.callout.monospacedDigit()).foregroundStyle(.white)
                        }
                    }
                    .help(s.help)
                    .accessibilityElement(children: .combine)
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "externaldrive").font(.caption).foregroundStyle(.yellow).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tr("Swap on the disk")).font(.caption).foregroundStyle(.white.opacity(0.6))
                        Text(b.swapReadable == false ? "—" : b.swapFiles > 0 ? tr("%1$@ of %2$@", MemoryFormat.string(bytes: b.swapUsed), MemoryFormat.string(bytes: b.swapFiles)) : tr("none"))
                            .font(.callout.monospacedDigit()).foregroundStyle(b.swapUsed >= 4 << 30 ? .orange : .white)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let activity = model.activity {
                Text(tr("Current swap activity: read %1$@/s · write %2$@/s",
                        MemoryFormat.string(mebibytes: activity.swapReadBytesPerSecond / 1_048_576),
                        MemoryFormat.string(mebibytes: activity.swapWriteBytesPerSecond / 1_048_576)))
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            } else {
                Text(tr("Current swap activity: waiting for comparable readings"))
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(16).glass(radius: 16)
    }

    func pill(_ text: String, color: Color) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(color.opacity(0.18)))
    }

    // MARK: Trend

    var trendRecords: [PulseRecord] {
        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        return model.day.filter { $0.t >= since }
    }

    var trendCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Memory and swap")).font(.callout.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Picker("", selection: $hours) { Text("1h").tag(1); Text("6h").tag(6); Text("24h").tag(24) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                    .accessibilityLabel(tr("Time span"))
            }
            let records = trendRecords
            if records.count >= 2 {
                Chart {
                    ForEach(records, id: \.t) { r in
                        if let used = r.usedMB {
                            LineMark(x: .value("t", r.t), y: .value("GiB", Double(used) / 1024), series: .value("k", "used"))
                                .foregroundStyle(by: .value("k", tr("Memory used")))
                        }
                        LineMark(x: .value("t", r.t), y: .value("GiB", Double(r.swapUsedMB) / 1024), series: .value("k", "swap"))
                            .foregroundStyle(by: .value("k", tr("Swap")))
                        if r.memory.isHigh {
                            RuleMark(x: .value("t", r.t)).foregroundStyle(r.memory == .critical ? Color.red.opacity(0.25) : Color.orange.opacity(0.18))
                        }
                    }
                    if let b = model.breakdown {
                        RuleMark(y: .value("GiB", Double(b.total) / 1_073_741_824)).foregroundStyle(.white.opacity(0.25))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartForegroundStyleScale([tr("Memory used"): Color.green, tr("Swap"): Color.yellow])
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) GiB") } } } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
                .frame(height: 150)
                Text(tr("Shaded: memory pressure was high. Dashed line: installed memory."))
                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
            } else {
                Text(tr("Thermo records memory once a minute; the chart fills in as it does."))
                    .font(.caption).foregroundStyle(.white.opacity(0.5)).padding(.vertical, 20)
            }
        }
        .padding(16).glass(radius: 16)
    }

    // MARK: Suspects

    var suspectsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tr("Programs growing in memory"), systemImage: "chart.line.uptrend.xyaxis").font(.callout.weight(.semibold)).foregroundStyle(.orange)
            ForEach(model.suspects) { s in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                        Text(s.text).font(.caption).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(MemoryFormat.string(kibibytes: s.memoryKB)).font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                    Button(tr("Inspect")) { expanded.insert(s.id); search = s.name }.buttonStyle(PillButtonStyle())
                }
            }
        }
        .padding(16).glass(radius: 16)
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
            HStack {
                Text(tr("Programs by memory")).font(.callout.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                if let sampled = model.sampled { Text(sampled, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            // Said before the numbers, not under them: the column is easy to read as RAM or swap.
            Text(tr("Memory footprint is Activity Monitor's Memory column: what a program is charged for, compressed memory included, some of which may be in swap. Adding programs up gives neither the used memory above nor the swap size; resident memory counts shared pages and cannot be subtracted from footprint to get swap."))
                .font(.caption2).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(tr("Search programs, projects or PID"), text: $search).textFieldStyle(.roundedBorder)
                Picker(tr("Sort by"), selection: $sortByResident) {
                    Text(tr("Memory footprint")).tag(false)
                    Text(tr("Resident memory")).tag(true)
                }.frame(width: 180)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                Text(tr("Program / project / process")).frame(maxWidth: .infinity, alignment: .leading)
                Text(tr("Memory footprint")).frame(width: 84, alignment: .trailing)
                Text(tr("Resident memory")).frame(width: 84, alignment: .trailing)
                Spacer().frame(width: 210)
            }.frame(minWidth: 640)
                Text(tr("Memory footprint") + " · " + tr("Resident memory"))
            }.font(.caption2).foregroundStyle(.white.opacity(0.5))
            if !model.inventoryAvailable {
                Text(tr("Process readings unavailable. Try refreshing.")).font(.caption).foregroundStyle(.orange)
            }
            ForEach(list) { programRow($0, top: top) }
            if visible.count > 15 {
                Button(showAll ? tr("Show fewer") : tr("Show all %1$@", String(visible.count))) { showAll.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
            if model.unreadableCount > 0 {
                Text(tr("%1$@ processes have no footprint reading; resident estimates and missing values are marked.", String(model.unreadableCount)))
                    .font(.caption2).foregroundStyle(.orange)
            }
            ForEach([pulse.quitProblem, pulse.restartProblem, pulse.actionFeedback].compactMap { $0 }, id: \.self) { t in
                Text(t).font(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).glass(radius: 16)
    }

    func metric(_ memory: Int, _ kind: MachinePulse.MemoryMetric?) -> String {
        if kind == .unavailable || kind == .mixed { return "—" }
        return (kind == .residentEstimate ? "≈ " : "") + MemoryFormat.string(kibibytes: memory)
    }

    func programRow(_ program: MemoryProgram, top: Double) -> some View {
        let isOpen = expanded.contains(program.id)
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Button { if isOpen { expanded.remove(program.id) } else { expanded.insert(program.id) } } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").frame(width: 10)
                }.buttonStyle(.plain).accessibilityLabel(tr("Inspect %1$@", program.name))
                if let app = program.contexts.first?.app {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable().frame(width: 22, height: 22)
                } else { Image(systemName: "terminal").frame(width: 22, height: 22).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(program.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text("×\(program.processCount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(program.contexts.first?.app != nil ? tr("App · expand for processes") : tr("%1$@ projects · expand for processes", String(program.projects.count)))
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(Color.green.opacity(0.7)).frame(width: g.size.width * CGFloat(min(1, max(0, Double(sortByResident ? program.residentKB ?? 0 : (program.memoryMetric == .mixed || program.memoryMetric == .unavailable ? 0 : program.memoryKB)) / top))))
                    }
                }.frame(width: 60, height: 5).accessibilityHidden(true)
                Text(metric(program.memoryKB, program.memoryMetric)).frame(width: 84, alignment: .trailing)
                Text(program.residentKB.map { MemoryFormat.string(kibibytes: $0) } ?? "—").foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
                Group {
                    if let target = program.actionTarget { actions(target, emphasizeRestart: false) }
                    else { Button(tr("Inspect")) { expanded.insert(program.id) }.buttonStyle(PillButtonStyle()) }
                }.frame(width: 210, alignment: .trailing)
            }.frame(minWidth: 640)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button { if isOpen { expanded.remove(program.id) } else { expanded.insert(program.id) } } label: {
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        }.buttonStyle(.plain).accessibilityLabel(tr("Inspect %1$@", program.name))
                        Text(program.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text("×\(program.processCount)").foregroundStyle(.secondary).fixedSize()
                        Spacer(minLength: 0)
                        Text(metric(program.memoryKB, program.memoryMetric)).fixedSize()
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(program.contexts.first?.app != nil ? tr("App · expand for processes") : tr("%1$@ projects · expand for processes", String(program.projects.count)))
                                .lineLimit(1)
                            Text(tr("Resident memory") + ": " + (program.residentKB.map { MemoryFormat.string(kibibytes: $0) } ?? "—"))
                        }.font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if let target = program.actionTarget { actions(target, emphasizeRestart: false) }
                        else { Button(tr("Inspect")) { expanded.insert(program.id) }.buttonStyle(PillButtonStyle()) }
                    }
                }
            }.font(.system(size: 12).monospacedDigit())
            if isOpen {
                programTrend(program)
                ForEach(program.contexts) { h in contextRow(h, showActions: program.actionTarget == nil) }
            }
        }.padding(.vertical, 6)
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
                        .foregroundStyle(.green)
                }.frame(height: 65).chartXAxis(.hidden)
                    .chartYAxis { AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.1f GiB", d)) } }
                    } }
                Text(tr("Program totals include changing workloads; growth alone does not prove a leak."))
                    .foregroundStyle(.secondary)
            }.font(.caption2).padding(.leading, 32).padding(.trailing, 16)
        } else {
            Text(tr("Program trend appears after comparable samples are collected."))
                .font(.caption2).foregroundStyle(.secondary).padding(.leading, 32)
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
                    Text(detail(h)).font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(metric(h.memoryKB, h.memoryMetric)).frame(width: 84, alignment: .trailing)
                Text(h.residentKB.map { MemoryFormat.string(kibibytes: $0) } ?? "—").foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
                Group { if showActions { actions(h, emphasizeRestart: false) } }.frame(width: 210, alignment: .trailing)
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
                    Text(detail(h)).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        Text(tr("Resident memory") + ": " + (h.residentKB.map { MemoryFormat.string(kibibytes: $0) } ?? "—"))
                            .foregroundStyle(.secondary)
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
                        Spacer().frame(width: 210)
                    }.frame(minWidth: 600)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(MachinePulse.roleName(p.role)) · PID \(p.pid)")
                            Text(tr("Memory footprint") + ": " + metric(p.memoryKB, p.memoryMetric)
                                 + " · " + tr("Resident memory") + ": " + (p.residentKB.map { MemoryFormat.string(kibibytes: $0) } ?? "—"))
                        }
                    }.foregroundStyle(.secondary).padding(.leading, 20)
                }
            }
        }.font(.caption.monospacedDigit()).padding(.leading, 32)
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
                .buttonStyle(PillButtonStyle()).help(tr("Which of its pages use the memory"))
            }
            if h.quittable && h.app != nil {
                Button(pulse.restarting == h.name ? tr("Restarting…") : tr("Restart")) { restartTarget = h }
                    .buttonStyle(PillButtonStyle(prominent: emphasizeRestart, color: .orange))
                    .disabled(pulse.restarting != nil || pulse.quitting.contains(h.id))
            }
            if h.quittable {
                Button(pulse.quitting.contains(h.id) ? tr("Stopping…") : h.app != nil ? tr("Quit") : tr("End")) { confirming = h }
                    .buttonStyle(PillButtonStyle())
                    .disabled(pulse.quitting.contains(h.id) || pulse.restarting == h.name)
            }
        }
    }

    // MARK: Swap

    func swapExplainer(_ b: MemoryBreakdown) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("When programs need more memory than the Mac has, macOS first compresses memory that is not being used, then writes some of it to swap files on the disk. Reading it back from the disk is far slower than memory, which is when the Mac feels slow."))
                Text(tr("Swap files stay until memory frees up and macOS removes them by itself; there is nothing to delete by hand. Restarting the program that holds the memory, or the Mac, gives it back."))
                Text(tr("Swap needs free disk space. With less than about 5 GB free, macOS cannot grow it and asks you to force quit apps."))
                Text(tr("Since startup %1$@ was written to swap and %2$@ read back.",
                        MemoryFormat.string(bytes: b.swapOuts * UInt64(vm_kernel_page_size)), MemoryFormat.string(bytes: b.swapIns * UInt64(vm_kernel_page_size))))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .font(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        } label: {
            Text(tr("What swap is")).font(.callout.weight(.semibold)).foregroundStyle(.white)
        }
        .padding(16).glass(radius: 16)
    }
}
