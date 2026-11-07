import Charts
import AgentCore
import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

/// The unchecked boundary owns a serial queue; the mutable sampler never leaves it.
private final class ComputeWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let sampler = ComputeSampler()
    private let includeGPU: Bool
    private let readSample: (@Sendable (ScanCancellation) -> ComputeActivity)?
    init(includeGPU: Bool, readSample: (@Sendable (ScanCancellation) -> ComputeActivity)?, queue: DispatchQueue?) {
        self.includeGPU = includeGPU
        self.readSample = readSample
        self.queue = queue ?? DispatchQueue(label: "dev.thermo.compute", qos: .userInitiated)
    }
    func sample(reset: Bool, cancellation: ScanCancellation,
                receive: @escaping @Sendable (ComputeActivity?) -> Void) {
        queue.async {
            guard !cancellation.isCancelled else { receive(nil); return }
            if reset { self.sampler.reset() }
            let previousCancellation = ScanCancellation.current
            ScanCancellation.current = cancellation
            defer { ScanCancellation.current = previousCancellation }
            let reading = self.readSample?(cancellation) ?? self.sampler.sample(includeGPU: self.includeGPU, cancelled: { cancellation.isCancelled })
            receive(cancellation.isCancelled ? nil : reading)
        }
    }
}

@MainActor
final class ComputeModel: ObservableObject {
    static let shared = ComputeModel()
    static let cpu = ComputeModel(includeGPU: false)
    struct Point: Identifiable {
        let id = UUID()
        let time: Date
        let cpu: Double?
        let devices: [GPUDeviceActivity]
    }
    @Published private(set) var current: ComputeActivity?
    @Published private(set) var history: [Point] = []
    private let worker: ComputeWorker
    private let refreshInterval: TimeInterval
    private var timer: Timer?
    private var sampling = false
    private var generation = UUID()
    private var cancellation: ScanCancellation?
    private var resetNextReading = true
    private var visibility = SamplingLeases()
    init(includeGPU: Bool = true, readSample: (@Sendable (ScanCancellation) -> ComputeActivity)? = nil,
         samplingQueue: DispatchQueue? = nil, refreshInterval: TimeInterval = 2) {
        precondition(refreshInterval.isFinite && refreshInterval > 0)
        self.refreshInterval = refreshInterval
        worker = ComputeWorker(includeGPU: includeGPU, readSample: readSample, queue: samplingQueue)
    }
    var samplingActive: Bool { timer != nil }
    var sampleInFlight: Bool { sampling }
    func setVisible(_ active: Bool, owner: UUID) {
        visibility.set(owner, active: active)
        if visibility.active { start() } else { stop() }
    }
    func releaseReadingsIfIdle() {
        guard timer == nil else { return }
        if current != nil { current = nil }
        if !history.isEmpty { history = [] }
    }
    func start() {
        guard timer == nil else { return }
        generation = UUID()
        current = nil; history = []
        resetNextReading = true
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        sample()
    }
    func stop() {
        timer?.invalidate(); timer = nil; generation = UUID(); cancellation?.cancel()
    }
    private func sample() {
        guard timer != nil, !sampling else { return }
        sampling = true
        let token = generation, cancellation = ScanCancellation()
        self.cancellation = cancellation
        let reset = resetNextReading
        resetNextReading = false
        worker.sample(reset: reset, cancellation: cancellation) { reading in
            DispatchQueue.main.async {
                self.sampling = false
                self.cancellation = nil
                guard self.generation == token, !cancellation.isCancelled, let reading else {
                    // A reopened page waits for physical completion, then refreshes immediately.
                    if self.timer != nil { self.sample() }
                    return
                }
                self.current = reading
                guard self.generation == token, self.timer != nil else { return }
                self.history.append(Point(time: reading.sampled, cpu: reading.cpu, devices: reading.devices))
                self.history.removeAll { reading.sampled.timeIntervalSince($0.time) > 900 }
            }
        }
    }
}

struct ComputePage: View {
    let gpu: Bool
    @ObservedObject private var model: ComputeModel
    init(gpu: Bool) {
        self.gpu = gpu
        _model = ObservedObject(wrappedValue: gpu ? .shared : .cpu)
    }
    @State private var search = ""
    @State private var expanded = Set<String>()
    @State private var showAll = false
    @AppStorage("computePage.sort") private var sort = ComputeSort.usage
    @State private var hovered: String?
    @State private var allProcesses = Set<String>()
    @State private var stopping: ComputeStopTarget?
    @State private var stopProblem: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var title: String { gpu ? tr("GPU usage") : tr("CPU usage") }
    func value(_ p: ComputeProgram) -> Double? { gpu ? p.observedGPU : p.cpu }
    var programs: [ComputeProgram] {
        (model.current?.programs ?? []).filter { p in
            (search.isEmpty || (p.name + " " + p.contexts.joined(separator: " ") + " " + p.processes.map { String($0.pid) + " " + $0.name }.joined(separator: " ")).localizedCaseInsensitiveContains(search))
        }.sorted { a, b in
            switch sort {
            case .name:
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            case .processes where a.processes.count != b.processes.count:
                return a.processes.count > b.processes.count
            default:
                let x = value(a) ?? -1, y = value(b) ?? -1
                return x == y ? a.id < b.id : x > y
            }
        }
    }
    func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
    var accent: Color { gpu ? Color(red: 0.70, green: 0.52, blue: 1.0) : Theme.accent }

    var body: some View {
        WindowPage(title: title, subtitle: tr("Live readings every 2 seconds while this page is open.")) {
            if gpu, let current = model.current, current.devices.isEmpty {
                NoticeBanner(text: tr("This GPU driver does not expose utilization counters."))
            }
            hero
            programsSection
        }
        .sheet(item: $stopping) { target in
            ConfirmSheet(title: target.title, summary: target.summary, destructive: target.app == nil,
                         heading: tr("What will run"), lines: target.lines,
                         footnote: tr("Thermo never stops system processes, AI agent sessions or itself."),
                         confirmTitle: target.app != nil ? tr("Quit") : tr("End"),
                         confirm: { stopping = nil; stop(target) }, cancel: { stopping = nil })
        }
        .samplingWhileVisible { owner, active in model.setVisible(active, owner: owner) }
        .onDisappear { DispatchQueue.main.async { model.releaseReadingsIfIdle() } }
    }

    // MARK: Hero

    /// The gauge (one per GPU) with what it measures, and the curve since the page opened.
    var hero: some View {
        InspectorPanel {
            HStack(alignment: .center, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if gpu {
                        ForEach(model.current?.devices ?? []) { device in
                            gauge(device.name, value: device.percent, detail: tr("Whole-device utilization"))
                        }
                        if model.current?.devices.isEmpty ?? true { gauge(tr("GPU usage"), value: nil, detail: nil) }
                    } else {
                        gauge(tr("Whole-machine CPU"), value: model.current?.cpu,
                              detail: tr("%1$@ logical cores · 100%% means the whole machine is busy", String(model.current?.cores ?? ProcessInfo.processInfo.activeProcessorCount)))
                    }
                }
                .frame(width: 280, alignment: .leading)
                Rectangle().fill(Theme.hairline).frame(width: 1).padding(.vertical, Theme.Space.xs)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(tr("Usage since opening this page (up to 15 minutes)")).font(Theme.label).foregroundStyle(Theme.textTertiary)
                    if model.history.count > 1 { chart } else {
                        Label(tr("Waiting for two samples…"), systemImage: "clock").font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(Theme.Space.l)
        }
    }

    func gauge(_ name: String, value: Double?, detail: String?) -> some View {
        HStack(spacing: Theme.Space.l) {
            RingGauge(value: value.map { $0 / 100 }, text: percent(value), caption: gpu ? "GPU" : "CPU", size: 104)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    var chart: some View {
        let singleGPU = (model.current?.devices.count ?? 0) <= 1
        return Chart(model.history) { p in
            if gpu && !singleGPU {
                ForEach(p.devices) { d in
                    if let v = d.percent {
                        LineMark(x: .value("Time", p.time), y: .value("Usage", v))
                            .foregroundStyle(by: .value("Device", d.name + " · GPU " + String((model.current?.devices.firstIndex(where: { $0.id == d.id }) ?? 0) + 1)))
                            .interpolationMethod(.monotone)
                    }
                }
            } else if let v = gpu ? p.devices.first?.percent : p.cpu {
                // One CPU and one GPU draw the same way, so the two pages read alike.
                AreaMark(x: .value("Time", p.time), y: .value("Usage", v))
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.30), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.time), y: .value("Usage", v)).foregroundStyle(accent).interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...100)
        // The first minute keeps a one-minute axis, so a freshly opened page has no per-second
        // ticks and the newest label is not clipped at the right edge.
        .chartXScale(domain: chartDomain)
        // One GPU needs no legend; the name is already beside the gauge.
        .chartLegend((model.current?.devices.count ?? 0) > 1 ? .visible : .hidden)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%").font(Theme.caption).foregroundStyle(Theme.textTertiary) } }
        } }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in
            AxisValueLabel(format: .dateTime.hour().minute().second()).font(Theme.caption).foregroundStyle(Theme.textTertiary)
        } }
        .frame(height: 120)
    }

    var chartDomain: ClosedRange<Date> {
        let last = model.history.last?.time ?? Date()
        let first = model.history.first?.time ?? last
        return min(first, last.addingTimeInterval(-60))...last
    }

    // MARK: Programs

    var programsSection: some View {
        let list = showAll || !search.isEmpty ? programs : Array(programs.prefix(30))
        let top = max(100, programs.compactMap(value).max() ?? 100)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: tr("Usage by program")) {
                HStack(spacing: Theme.Space.s) {
                    Picker(tr("Sort"), selection: $sort) {
                        ForEach(ComputeSort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                    .help(tr("Sort programs"))
                    if let date = model.current?.sampled {
                        Text(date, style: .time).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                    InfoButton(text: gpu ? tr("GPU time rate covers reporting clients only. Parallel GPU work can exceed 100%; it is not a share of the device gauge. Missing counters show —.")
                               : tr("Program CPU: 100% equals one logical core, so multi-core programs can exceed 100%. Protected or unreadable processes show —."))
                }
            }
            SearchField(text: $search, prompt: tr("Search program, project or PID"))
            if let stopProblem { NoticeBanner(text: stopProblem, dismiss: { self.stopProblem = nil }) }
            if gpu, !programs.isEmpty, programs.allSatisfy({ $0.observedGPU == nil }) {
                NoticeBanner(text: tr("No program GPU rates available yet. New clients need two samples; this driver may not expose program counters."))
            }
            if model.current == nil {
                SkeletonList(rows: 6)
            } else if list.isEmpty {
                InspectorPanel { EmptyState(symbol: "magnifyingglass", title: tr("No matching items")) }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, program in
                        if i > 0 { InspectorDivider(inset: Theme.Space.l) }
                        programRow(program, top: top)
                    }
                    if !showAll && search.isEmpty && programs.count > 30 {
                        InspectorDivider(inset: 0)
                        Button(tr("Show all programs")) {
                            withAnimation(Theme.standard.unlessReduced(reduceMotion)) { showAll = true }
                        }
                        .buttonStyle(.plain).font(Theme.secondary.weight(.medium)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.s).contentShape(Rectangle()).hoverHighlight()
                    }
                }
                .glass()
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
        }
    }

    func toggle(_ id: String) {
        withAnimation(Theme.standard.unlessReduced(reduceMotion)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    func programRow(_ program: ComputeProgram, top: Double) -> some View {
        let open = expanded.contains(program.id) || snapshotOpen.contains(program.id)
        let v = value(program)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                DisclosureChevron(expanded: open)
                // The same icon the Memory page shows, so one program looks the same on both pages.
                if let app = program.app {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
                } else {
                    Image(systemName: "terminal").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.07)))
                        .accessibilityHidden(true)
                }
                HStack(spacing: Theme.Space.xs) {
                    Text(program.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text("×\(program.processes.count)").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surfaceRaised)
                        Capsule().fill(accent.opacity(0.85)).frame(width: g.size.width * CGFloat(min(1, max(0, (v ?? 0) / top))))
                    }
                }
                .frame(width: 64, height: 4).accessibilityHidden(true)
                // Idle programs (0.0%) step back, so the ones doing work stand out in a long list.
                Text(percent(v)).font(Theme.figure(.row)).foregroundStyle(v == nil || v == 0 ? Theme.textTertiary : Theme.textPrimary)
                    // Which processes the figure covers is a detail; on every row it was noise.
                    .help(gpu ? tr("%1$@ reporting processes", String(program.gpuReportingProcesses)) : "")
                    .frame(width: 64, alignment: .trailing)
                stopButton(program.quittable ? ComputeStopTarget(program) : nil, visible: hovered == program.id || snapshotOpen.first == program.id)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(program.id) }
            .onHover { inside in if inside { hovered = program.id } else if hovered == program.id { hovered = nil } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(open ? tr("Expanded") : tr("Collapsed"))
            .contextMenu {
                if program.quittable { Button(program.app != nil ? tr("Quit %1$@…", program.name) : tr("End %1$@…", program.name)) { stopping = ComputeStopTarget(program) } }
                Button(tr("Copy PIDs")) { copy(program.processes.map { String($0.pid) }.joined(separator: " ")) }
            }
            if open {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if !program.quittable {
                        Label(tr("System processes, AI agent sessions and Thermo itself cannot be stopped here."), systemImage: "lock")
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary).padding(.bottom, 2)
                    }
                    let sortedProcesses = program.processes.sorted { ((gpu ? $0.gpu : $0.cpu) ?? -1) > ((gpu ? $1.gpu : $1.cpu) ?? -1) }
                    let shown = allProcesses.contains(program.id) || sortedProcesses.count <= 10 ? sortedProcesses : Array(sortedProcesses.prefix(8))
                    ForEach(shown) { process in
                        let key = program.id + "#" + String(process.pid)
                        HStack(spacing: Theme.Space.m) {
                            // Verbatim: a PID is an identifier, not a quantity, so no thousands separator.
                            Text(verbatim: "PID \(process.pid) · \(process.label)").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                                .lineLimit(1).textSelection(.enabled).layoutPriority(1)
                            if let folder = process.folder, !program.contexts.isEmpty || program.processes.count > 1 {
                                Text(folder).font(Theme.mono).foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                            Spacer(minLength: Theme.Space.s)
                            Text(percent(gpu ? process.gpu : process.cpu)).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                            stopButton(program.processes.count > 1 && process.quittable == true ? ComputeStopTarget(process, in: program) : nil,
                                       visible: hovered == key || snapshotOpen.first == program.id, small: true)
                        }
                        .frame(minHeight: 20)
                        .contentShape(Rectangle())
                        .onHover { inside in if inside { hovered = key } else if hovered == key { hovered = nil } }
                        .contextMenu {
                            if process.quittable == true { Button(tr("End %1$@…", process.label)) { stopping = ComputeStopTarget(process, in: program) } }
                            Button(tr("Copy PID")) { copy(String(process.pid)) }
                        }
                    }

                    if shown.count < sortedProcesses.count {
                        Button(tr("Show the other %1$@", String(sortedProcesses.count - shown.count))) {
                            withAnimation(Theme.standard.unlessReduced(reduceMotion)) { _ = allProcesses.insert(program.id) }
                        }
                        .buttonStyle(.borderless).font(Theme.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    }
                    // Folders already shown beside their processes are not listed again.
                    ForEach(Array(Set(program.contexts).subtracting(program.processes.compactMap(\.folder))).sorted(), id: \.self) { context in
                        Text(context).font(Theme.mono).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
                    }
                }
                .padding(.leading, 36).padding(.trailing, Theme.Space.xs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        .hoverHighlight()
    }


    /// Fixed width either way, so percentages stay aligned whether or not a row can be stopped.
    func stopButton(_ target: ComputeStopTarget?, visible: Bool, small: Bool = false) -> some View {
        Group {
            if let target {
                Button(target.app != nil ? tr("Quit") : tr("End")) { stopping = target }
                    .buttonStyle(.borderless).font((small ? Theme.caption : Theme.secondary).weight(.medium))
                    .foregroundStyle(target.app != nil ? Theme.accent : Theme.danger)
                    .opacity(visible ? 1 : 0).allowsHitTesting(visible)
                    .accessibilityHidden(!visible)
            } else { Color.clear }
        }
        .frame(width: 40, alignment: .trailing)
    }

    /// `--expand-rows N` (offscreen snapshots only): open the first N multi-process programs and show the
    /// first one's stop buttons as if hovered. Computed, because snapshots render without lifecycle events.
    var snapshotOpen: [String] {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--expand-rows"), i + 1 < args.count, let n = Int(args[i + 1]) else { return [] }
        return programs.filter { $0.processes.count > 1 }.prefix(n).map(\.id)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Re-checks each process is the one that was read (same PID, owner and start time) before signalling it.
    func stop(_ target: ComputeStopTarget) {
        stopProblem = nil
        if let path = target.app {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleURL?.standardizedFileURL.path == path && target.pids.contains($0.processIdentifier)
            }) else { stopProblem = tr("%1$@ changed or exited since the reading. Check again before stopping it.", target.name); return }
            if !app.terminate() { stopProblem = tr("%1$@ did not accept the quit request. Check its dialogs.", target.name) }
            return
        }
        var skipped = false
        for (pid, started) in target.processes {
            guard pid > 1, pid != getpid(), let now = ProcessTable.identity(pid), now.uid == getuid(),
                  started == nil || now.started == started else { skipped = true; continue }
            if kill(pid, SIGTERM) != 0 { skipped = true }
        }
        if skipped { stopProblem = tr("%1$@ changed or exited since the reading. Check again before stopping it.", target.name) }
    }
}

enum ComputeSort: String, CaseIterable, Identifiable {
    case usage, name, processes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .usage: tr("Usage")
        case .name: tr("Name")
        case .processes: tr("Processes")
        }
    }
}

/// What a Quit/End confirmation is about: a whole program or one of its processes.
struct ComputeStopTarget: Identifiable {
    let id: String
    let name: String
    let app: String?
    let processes: [(pid: pid_t, started: Date?)]
    var pids: [pid_t] { processes.map(\.pid) }
    init(_ program: ComputeProgram) {
        id = program.id; name = program.name; app = program.app
        processes = program.processes.map { ($0.pid, $0.started) }
    }
    init(_ process: ComputeProcess, in program: ComputeProgram) {
        id = program.id + "#" + String(process.pid); name = process.label; app = nil
        processes = [(process.pid, process.started)]
    }
    var title: String { app != nil ? tr("Quit %1$@?", name) : tr("End %1$@?", name) }
    var summary: String {
        app != nil ? tr("The app is asked to quit, the same as ⌘Q; it can save your work first.")
                   : tr("The process is asked to stop (SIGTERM). Unsaved work in it may be lost.")
    }
    var lines: [String] { app != nil ? [tr("quit %1$@", app!)] : pids.map { "kill -TERM \($0)" } }
}
