import Charts
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var title: String { gpu ? tr("GPU usage") : tr("CPU usage") }
    func value(_ p: ComputeProgram) -> Double? { gpu ? p.observedGPU : p.cpu }
    var programs: [ComputeProgram] {
        (model.current?.programs ?? []).filter { p in
            (search.isEmpty || (p.name + " " + p.contexts.joined(separator: " ") + " " + p.processes.map { String($0.pid) + " " + $0.name }.joined(separator: " ")).localizedCaseInsensitiveContains(search))
        }.sorted { a, b in
            let x = value(a) ?? -1, y = value(b) ?? -1
            return x == y ? a.id < b.id : x > y
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
        Chart(model.history) { p in
            if gpu {
                ForEach(p.devices) { d in
                    if let v = d.percent {
                        LineMark(x: .value("Time", p.time), y: .value("Usage", v))
                            .foregroundStyle(by: .value("Device", d.name + " · GPU " + String((model.current?.devices.firstIndex(where: { $0.id == d.id }) ?? 0) + 1)))
                            .interpolationMethod(.monotone)
                    }
                }
            } else if let v = p.cpu {
                AreaMark(x: .value("Time", p.time), y: .value("Usage", v))
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.30), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.time), y: .value("Usage", v)).foregroundStyle(accent).interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%").font(Theme.caption).foregroundStyle(Theme.textTertiary) } }
        } }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in
            AxisValueLabel(format: .dateTime.hour().minute().second()).font(Theme.caption).foregroundStyle(Theme.textTertiary)
        } }
        .frame(height: 120)
    }

    // MARK: Programs

    var programsSection: some View {
        let list = showAll || !search.isEmpty ? programs : Array(programs.prefix(30))
        let top = max(100, programs.compactMap(value).max() ?? 100)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: tr("Usage by program")) {
                HStack(spacing: Theme.Space.s) {
                    if let date = model.current?.sampled {
                        Text(date, style: .time).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                    InfoButton(text: gpu ? tr("GPU time rate covers reporting clients only. Parallel GPU work can exceed 100%; it is not a share of the device gauge. Missing counters show —.")
                               : tr("Program CPU: 100% equals one logical core, so multi-core programs can exceed 100%. Protected or unreadable processes show —."))
                }
            }
            SearchField(text: $search, prompt: tr("Search program, project or PID"))
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
        let open = expanded.contains(program.id)
        let v = value(program)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                DisclosureChevron(expanded: open)
                HStack(spacing: Theme.Space.xs) {
                    Text(program.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text("×\(program.processes.count)").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if gpu {
                    Text(tr("%1$@ reporting processes", String(program.gpuReportingProcesses)))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surfaceRaised)
                        Capsule().fill(accent.opacity(0.85)).frame(width: g.size.width * CGFloat(min(1, max(0, (v ?? 0) / top))))
                    }
                }
                .frame(width: 64, height: 4).accessibilityHidden(true)
                Text(percent(v)).font(Theme.figure(.row)).foregroundStyle(v == nil ? Theme.textTertiary : Theme.textPrimary)
                    .frame(width: 64, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(program.id) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(open ? tr("Expanded") : tr("Collapsed"))
            if open {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(program.processes.sorted { ((gpu ? $0.gpu : $0.cpu) ?? -1) > ((gpu ? $1.gpu : $1.cpu) ?? -1) }) { process in
                        HStack {
                            Text("PID \(process.pid) · \(process.name)").font(Theme.caption).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                            Spacer()
                            Text(percent(gpu ? process.gpu : process.cpu)).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    ForEach(Array(Set(program.contexts)).sorted(), id: \.self) { context in
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
}
