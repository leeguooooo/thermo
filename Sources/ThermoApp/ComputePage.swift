import Charts
import CleanKit
import SwiftUI
import ThermoL10n

/// The unchecked boundary owns a serial queue; the mutable sampler never leaves it.
private final class ComputeWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let sampler = ComputeSampler()
    private let readSample: (@Sendable (ScanCancellation) -> ComputeActivity)?
    init(readSample: (@Sendable (ScanCancellation) -> ComputeActivity)?, queue: DispatchQueue?) {
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
            let reading = self.readSample?(cancellation) ?? self.sampler.sample(cancelled: { cancellation.isCancelled })
            receive(cancellation.isCancelled ? nil : reading)
        }
    }
}

@MainActor
final class ComputeModel: ObservableObject {
    static let shared = ComputeModel()
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
    init(readSample: (@Sendable (ScanCancellation) -> ComputeActivity)? = nil,
         samplingQueue: DispatchQueue? = nil, refreshInterval: TimeInterval = 2) {
        precondition(refreshInterval.isFinite && refreshInterval > 0)
        self.refreshInterval = refreshInterval
        worker = ComputeWorker(readSample: readSample, queue: samplingQueue)
    }
    var samplingActive: Bool { timer != nil }
    var sampleInFlight: Bool { sampling }
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
                self.history.append(Point(time: reading.sampled, cpu: reading.cpu, devices: reading.devices))
                self.history.removeAll { reading.sampled.timeIntervalSince($0.time) > 900 }
            }
        }
    }
}

struct ComputePage: View {
    let gpu: Bool
    @ObservedObject private var model = ComputeModel.shared
    @State private var search = ""
    @State private var expanded = Set<String>()
    @State private var showAll = false
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
    var body: some View {
        WindowPage(title: title, subtitle: tr("Live readings every 2 seconds while this page is open.")) {
            if gpu {
                if let current = model.current, current.devices.isEmpty {
                    Label(tr("This GPU driver does not expose utilization counters."), systemImage: "info.circle").foregroundStyle(.orange)
                }
                ForEach(model.current?.devices ?? []) { device in
                    metric(device.name, value: device.percent, detail: tr("Whole-device utilization"))
                }
            } else {
                metric(tr("Whole-machine CPU"), value: model.current?.cpu,
                       detail: tr("%1$@ logical cores · 100%% means the whole machine is busy", String(model.current?.cores ?? ProcessInfo.processInfo.activeProcessorCount)))
            }
            if model.current == nil || (!gpu && model.current?.cpu == nil) {
                Label(tr("Waiting for two samples…"), systemImage: "clock").font(.callout).foregroundStyle(.secondary)
            }
            if model.history.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Usage since opening this page (up to 15 minutes)")).font(.callout.weight(.semibold))
                    Chart(model.history) { p in
                        if gpu {
                            ForEach(p.devices) { d in
                                if let v = d.percent { LineMark(x: .value("Time", p.time), y: .value("Usage", v)).foregroundStyle(by: .value("Device", d.name + " · GPU " + String((model.current?.devices.firstIndex(where: { $0.id == d.id }) ?? 0) + 1))) }
                            }
                        } else if let v = p.cpu {
                            LineMark(x: .value("Time", p.time), y: .value("Usage", v)).foregroundStyle(.cyan)
                            PointMark(x: .value("Time", p.time), y: .value("Usage", v)).symbolSize(8).foregroundStyle(.cyan)
                        }
                    }.chartYScale(domain: 0...100).frame(height: 130)
                }.padding(16).glass()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("Usage by program")).font(.headline)
                Text(gpu ? tr("GPU time rate covers reporting clients only. Parallel GPU work can exceed 100%; it is not a share of the device gauge. Missing counters show —.")
                     : tr("Program CPU: 100% equals one logical core, so multi-core programs can exceed 100%. Protected or unreadable processes show —."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField(tr("Search program, project or PID"), text: $search).textFieldStyle(.roundedBorder)
                if gpu, programs.allSatisfy({ $0.observedGPU == nil }) {
                    Text(tr("No program GPU rates available yet. New clients need two samples; this driver may not expose program counters."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(showAll || !search.isEmpty ? programs : Array(programs.prefix(30)))) { program in
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(program.id) }, set: { if $0 { expanded.insert(program.id) } else { expanded.remove(program.id) } })) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(program.processes.sorted { ((gpu ? $0.gpu : $0.cpu) ?? -1) > ((gpu ? $1.gpu : $1.cpu) ?? -1) }) { process in
                                HStack {
                                    Text("PID \(process.pid) · \(process.name)").font(.caption).textSelection(.enabled)
                                    Spacer()
                                    Text(percent(gpu ? process.gpu : process.cpu)).font(.caption.monospacedDigit())
                                }
                            }
                            ForEach(Array(Set(program.contexts)).sorted(), id: \.self) { context in
                                Text(context).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.padding(.vertical, 8)
                    } label: {
                        HStack {
                            Text(program.name).font(.callout.weight(.semibold)).lineLimit(1)
                            Text("×\(program.processes.count)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if gpu { Text(tr("%1$@ reporting processes", String(program.gpuReportingProcesses))).font(.caption).foregroundStyle(.secondary) }
                            Text(percent(value(program))).font(.callout.monospacedDigit().weight(.semibold)).frame(minWidth: 76, alignment: .trailing)
                        }
                    }.padding(12).glass(radius: 12)
                }
                if !showAll && search.isEmpty && programs.count > 30 {
                    Button(tr("Show all programs")) { showAll = true }.buttonStyle(PillButtonStyle())
                }
                if let date = model.current?.sampled { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
            }
        }.onAppear { model.start() }.onDisappear { model.stop() }
    }
    func metric(_ name: String, value: Double?, detail: String) -> some View {
        HStack(spacing: 16) {
            RingGauge(value: value.map { $0 / 100 }, text: percent(value), caption: gpu ? "GPU" : "CPU")
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }.padding(16).glass()
    }
}
