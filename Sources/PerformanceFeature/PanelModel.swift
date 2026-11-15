import ThermoUI
import AppKit
import CleanKit
import IOKit.ps
import SwiftUI
import ThermoKit
import ThermoL10n
import ModuleKit

private final class PanelReadingWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let liveSampler = MenuLiveSampler(readCPU:QuickLoad.cpuTicks,cpuPercent:QuickLoad.cpuPercent)
    private let read: (@Sendable () -> PanelModel.Reading)?

    init(queue: DispatchQueue?, read: (@Sendable () -> PanelModel.Reading)?) {
        self.queue = queue ?? DispatchQueue(label: "dev.thermo.panel.readings", qos: .utility)
        self.read = read
    }

    func reset() { queue.async { self.liveSampler.reset() } }

    func sample(cancellation: ScanCancellation, receive: @escaping @Sendable (PanelModel.Reading?) -> Void) {
        queue.async {
            guard !cancellation.isCancelled else { receive(nil); return }
            let reading: PanelModel.Reading
            if let read = self.read { reading = read() }
            else {
                let live = self.liveSampler.sample(metrics: [.cpuUsage, .download, .upload])
                reading = .init(cpu: live.cpu, gpu: QuickLoad.gpuPercent(), memory: SystemStats.memory(),
                                disk: SystemStats.disk(), download: live.download, upload: live.upload,
                                batteryMinutes: PanelModel.batteryMinutes())
            }
            receive(cancellation.isCancelled ? nil : reading)
        }
    }
}

/// What the menu bar panel shows besides the sensor snapshot: CPU, GPU, memory and network over the
/// last two minutes, battery time left, and a few facts about the machine. Samples every 2 s, and
/// only while the panel is open.
@MainActor
final class PanelModel: ObservableObject {
    static let length = 60

    struct Reading: Sendable {
        var cpu: Double? = nil
        var gpu: Double? = nil
        var memory: SystemStats.Memory? = nil
        var disk: SystemStats.Disk? = nil
        var download: Double? = nil
        var upload: Double? = nil
        var batteryMinutes: Int? = nil
    }
    @Published private(set) var currentCPU: Double?
    @Published private(set) var currentGPU: Double?
    @Published private(set) var currentDownload: Double?
    @Published private(set) var memoryStats: SystemStats.Memory?
    @Published private(set) var diskStats: SystemStats.Disk?
    @Published private(set) var cpu: [Double] = []
    @Published private(set) var gpu: [Double] = []
    @Published private(set) var memory: [Double] = []
    @Published private(set) var download: [Double] = []
    @Published private(set) var upload: Double?
    @Published private(set) var batteryMinutesLeft: Int?
    let chip = PanelModel.chipName()
    let macOS = "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
        .replacingOccurrences(of: "Version ", with: "").components(separatedBy: " (").first!
    let memoryTotal = ProcessInfo.processInfo.physicalMemory

    private var timer: Timer?
    private let samplingAllowed: () -> Bool
    private let worker: PanelReadingWorker
    private var generation = UUID()
    private var cancellation: ScanCancellation?
    private(set) var sampleInFlight = false
    private var holding = false
    private let readSample: (@MainActor () -> Reading)?
    private let holdPulse: @MainActor () -> Void
    private let releasePulse: @MainActor () -> Void

    init(readSample: (@MainActor () -> Reading)? = nil,
         readBackground: (@Sendable () -> Reading)? = nil, samplingQueue: DispatchQueue? = nil,
         holdPulse: @escaping @MainActor () -> Void,
         releasePulse: @escaping @MainActor () -> Void,
         samplingAllowed: @escaping () -> Bool = { true }) {
        self.readSample = readSample; self.holdPulse = holdPulse; self.releasePulse = releasePulse
        self.samplingAllowed = samplingAllowed
        worker = PanelReadingWorker(queue: samplingQueue, read: readBackground)
    }
    var samplingActive: Bool { timer != nil }

    /// Hidden panels do not retain periodic CPU, memory, GPU or network reads.
    private var interval: TimeInterval = 0

    func setActive(_ requested: Bool) {
        let on = requested && samplingAllowed()
        let wanted: TimeInterval = on ? 2 : 0
        if on, !holding { holdPulse(); holding = true }
        if !on, holding { releasePulse(); holding = false }
        guard wanted != interval else { return }
        interval = wanted
        generation = UUID()
        cancellation?.cancel()
        timer?.invalidate()
        timer = nil
        resetBaselines()
        guard on else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: wanted, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
    }

    func sample() {
        guard interval > 0 else { return }
        if let readSample {
            publish(readSample())
            return
        }
        guard !sampleInFlight else { return }
        sampleInFlight = true
        let token = generation, cancellation = ScanCancellation()
        self.cancellation = cancellation
        worker.sample(cancellation: cancellation) { [weak self] reading in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampleInFlight = false
                self.cancellation = nil
                guard self.interval > 0 else { return }
                guard self.generation == token, let reading else { self.sample(); return }
                self.publish(reading)
            }
        }
    }

    private func publish(_ reading: Reading) {
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        currentCPU = finite(reading.cpu); currentGPU = finite(reading.gpu)
        currentDownload = finite(reading.download); upload = finite(reading.upload)
        memoryStats = reading.memory; diskStats = reading.disk; batteryMinutesLeft = reading.batteryMinutes
        if let p = currentCPU { push(&cpu, p) }
        if let g = currentGPU { push(&gpu, g) }
        if let m = memoryStats { push(&memory, Double(m.usedBytes) / Double(max(1, m.totalBytes)) * 100) }
        if let d = currentDownload { push(&download, d) }
    }

    func resetBaselines() {
        worker.reset()
        currentCPU = nil; currentGPU = nil; currentDownload = nil; upload = nil
        memoryStats = nil; diskStats = nil; batteryMinutesLeft = nil
    }

    private func push(_ series: inout [Double], _ value: Double) {
        guard value.isFinite else { return }
        series.append(value)
        if series.count > Self.length { series.removeFirst(series.count - Self.length) }
    }

    /// macOS's own estimate while on battery; nil while charging or still estimating.
    nonisolated static func batteryMinutes() -> Int? {
        let seconds = IOPSGetTimeRemainingEstimate()
        guard seconds > 0, seconds != kIOPSTimeRemainingUnlimited, seconds != kIOPSTimeRemainingUnknown else { return nil }
        return Int(seconds / 60)
    }

    /// "M3", "M4 Pro", "Intel Core i7" from the CPU brand string.
    static func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let brand = String(cString: buffer)
        if brand.hasPrefix("Apple ") { return String(brand.dropFirst(6)) }
        return brand.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "")
            .components(separatedBy: " CPU").first?.trimmingCharacters(in: .whitespaces) ?? brand
    }

    static var uptime: TimeInterval? {
        var boot = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }
}

