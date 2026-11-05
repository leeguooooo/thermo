import AppKit
import CleanKit
import SwiftUI
import ThermoKit
import ThermoL10n

/// Holds the latest AI check-up across page switches. One run at a time.
@MainActor final class CheckupModel: ObservableObject {
    static let shared = CheckupModel()

    enum Phase: Equatable { case idle, measuring, preview, asking, failed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: CheckupReport?
    @Published private(set) var snapshot: CheckupSnapshot?

    /// Separate from the per-item "Ask AI" consent: this sends program names and project paths.
    var consented: Bool {
        get { UserDefaults.standard.bool(forKey: "localAI.checkupConsented") }
        set { UserDefaults.standard.set(newValue, forKey: "localAI.checkupConsented"); objectWillChange.send() }
    }

    var busy: Bool { phase == .measuring || phase == .asking }

    /// Measures now (a 2 s process sample plus the live readings), then asks — after the preview the first time.
    func start(monitor: Monitor) {
        guard !busy else { return }
        phase = .measuring
        let live = monitor.snapshot, home = NSHomeDirectory()
        Task.detached(priority: .userInitiated) {
            let diagnosis = SlowdownDiagnosis.diagnose(SlowdownSampler().sample(window: 2), system: .read())
            let volume = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            let thermal: String = {
                switch ProcessInfo.processInfo.thermalState {
                case .nominal: return "nominal"
                case .fair: return "fair"
                case .serious: return "serious"
                case .critical: return "critical"
                @unknown default: return "unknown"
                }
            }()
            let snapshot = CheckupSnapshot(
                model: Sampler.machineModel, uptime: ProcessInfo.processInfo.systemUptime,
                cpuTemperature: live?.cpu, gpuTemperature: live?.gpu, thermalState: thermal,
                fans: (live?.fans ?? []).map { .init(name: $0.name, rpm: $0.rpm, max: $0.max, manual: $0.manual) },
                battery: live?.battery.map { .init(percent: $0.percent, health: $0.health, cycles: $0.cycleCount, charging: $0.charging, externalPower: $0.externalPower) },
                diskFree: volume?.volumeAvailableCapacityForImportantUsage, diskTotal: volume?.volumeTotalCapacity.map(Int64.init),
                diagnosis: diagnosis, home: home)
            await MainActor.run {
                self.snapshot = snapshot
                if self.consented { self.ask() } else { self.phase = .preview }
            }
        }
    }

    /// Offscreen snapshots only: show a saved AI answer without asking anyone.
    func loadFixture(answer path: String) {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        report = LocalAI.parseCheckup(raw, snapshot: CheckupSnapshot(), source: "fixture")
    }

    func send() { consented = true; ask() }
    func cancel() { if phase == .preview { phase = .idle } }

    private func ask() {
        guard let snapshot, let backend = LocalAIStore.shared.backend else {
            phase = .failed(tr("No AI found on this Mac.")); return
        }
        phase = .asking
        Task {
            do { report = try await LocalAI.checkup(snapshot, using: backend); phase = .idle }
            catch { phase = .failed(error.localizedDescription) }
        }
    }
}

/// "AI Check-up": the AI on this Mac looks at everything Thermo measured and says, finding by
/// finding, what to do first and whether doing it interrupts the work in progress.
struct CheckupPage: View {
    @ObservedObject var monitor: Monitor
    let open: (MainPage) -> Void
    @ObservedObject private var model = CheckupModel.shared
    @ObservedObject private var ai = LocalAIStore.shared

    var body: some View {
        WindowPage(title: tr("AI Check-up"),
                   subtitle: tr("The AI on this Mac reads what Thermo measured and tells you what to do first, and whether it interrupts your work.")) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let backend = ai.backend { controls(backend) } else {
                    EmptyState(symbol: "sparkles", title: tr("No AI found on this Mac."),
                               detail: tr("Start magpie, Ollama or LM Studio, or install Claude Code, then try again."))
                    Button(tr("Look again")) { ai.discover(force: true) }.buttonStyle(PillButtonStyle())
                }
                if model.phase == .preview, let s = model.snapshot { preview(s) }
                if case .failed(let why) = model.phase {
                    NoticeBanner(text: why, dismiss: { model.cancel() })
                }
                if let r = model.report { report(r) }
                else if ai.backend != nil, model.phase == .idle { scope }
            }
        }
        .onAppear { ai.discover() }
    }

    /// Before the first run: what the AI will look at, so the button is not a leap in the dark.
    var scope: some View {
        let parts: [(String, String, String)] = [
            ("memorychip", tr("Memory and swap"), tr("Pressure, swap in use, and what holds the most")),
            ("cpu", tr("Processors"), tr("Load, and programs keeping the CPU busy")),
            ("thermometer.medium", tr("Heat and fans"), tr("CPU and GPU temperature, fan speed")),
            ("internaldrive", tr("Disk"), tr("Free space on the startup disk")),
            ("battery.75percent", tr("Battery"), tr("Charge, health and cycle count")),
            ("gearshape.2", tr("Flagged programs"), tr("Whether ending each one interrupts your work")),
        ]
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(tr("What it looks at")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.m), GridItem(.flexible(), spacing: Theme.Space.m)],
                      alignment: .leading, spacing: Theme.Space.m) {
                ForEach(parts, id: \.1) { symbol, title, detail in
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 20).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                            Text(detail).font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading).glass()
                }
            }
        }
    }

    @ViewBuilder func controls(_ backend: LocalAIBackend) -> some View {
        HStack(spacing: Theme.Space.m) {
            Button {
                model.start(monitor: monitor)
            } label: {
                Label(model.report == nil ? tr("Start check-up") : tr("Check again"), systemImage: "stethoscope")
            }
            .buttonStyle(PillButtonStyle(prominent: true)).disabled(model.busy || model.phase == .preview)
            switch model.phase {
            case .measuring:
                ProgressView().controlSize(.small)
                Text(tr("Measuring this Mac…")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            case .asking:
                ProgressView().controlSize(.small)
                Text(tr("%1$@ is looking it over; this usually takes under a minute…", backend.label)).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            default:
                Text(tr("Uses %1$@. Nothing is ended, cleaned or changed from here.", backend.label))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
    }

    func preview(_ s: CheckupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(tr("Sent to %1$@", ai.backend?.label ?? "")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary)
            ScrollView {
                Text(s.facts).font(Theme.mono).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }.frame(maxHeight: 320)
            Text(tr("Readings, program names and project folders Thermo flagged; never file contents. The AI may pass them to the cloud model it uses."))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(tr("Send")) { model.send() }.buttonStyle(PillButtonStyle(prominent: true))
                Button(tr("Cancel")) { model.cancel() }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading).glass()
    }

    func report(_ r: CheckupReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                let (text, color, symbol) = Self.overall(r.overall)
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(text).font(Theme.heading).foregroundStyle(color)
                    Text(r.summary).font(Theme.body).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(tr("AI answer · %1$@ · %2$@", r.source, AgeFormat.string(r.made))).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(Theme.Space.l).frame(maxWidth: .infinity, alignment: .leading).glass()
            ForEach(r.findings) { finding($0) }
            Text(tr("AI can be wrong. Thermo's own checks still apply when you act."))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    func finding(_ f: CheckupFinding) -> some View {
        let tone = Self.severity(f.severity)
        return HStack(alignment: .top, spacing: Theme.Space.m) {
            RoundedRectangle(cornerRadius: 2).fill(tone).frame(width: 4)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: Self.icon(f.area)).foregroundStyle(tone)
                    Text(f.title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                    if let c = f.culprit, c.freesKB >= 64 * 1024 {
                        Text(tr("frees ~%1$@", MemoryFormat.string(kibibytes: c.freesKB))).font(Theme.caption).foregroundStyle(Theme.caution)
                    }
                    Spacer()
                    // Beside the title, so a finding without a command does not grow a row just for it.
                    if let (title, page) = Self.destination(f) {
                        Button(title) { open(page) }.buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
                    }
                }
                if !f.detail.isEmpty {
                    Text(f.detail).font(Theme.secondary).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !f.impact.isEmpty {
                    let (label, color) = Self.safety(f.safety)
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text(label).font(Theme.label).foregroundStyle(color)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(color.opacity(0.15)))
                        Text(f.impact).font(Theme.secondary).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let how = f.how {
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        Text(how).font(Theme.mono).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(how, forType: .string) } label: {
                            Image(systemName: "doc.on.doc")
                        }.buttonStyle(.borderless).help(tr("Copy"))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading).glass()
    }

    /// Where in Thermo to act on it; the AI never acts itself.
    static func destination(_ f: CheckupFinding) -> (String, MainPage)? {
        if f.culprit != nil { return (tr("Open in Overview"), .overview) }
        switch f.area {
        case .memory: return (tr("Open Memory"), .memory)
        case .cpu, .processes: return (tr("Open CPU usage"), .compute(false))
        case .thermal: return (tr("Open Fans"), .fans)
        case .disk: return (tr("Open Space Lens"), .space(.browse))
        case .battery, .other: return nil
        }
    }

    static func overall(_ o: CheckupReport.Overall) -> (String, Color, String) {
        switch o {
        case .good: return (tr("In good shape"), Theme.good, "checkmark.seal.fill")
        case .attention: return (tr("A few things to look at"), Theme.caution, "exclamationmark.circle.fill")
        case .urgent: return (tr("Needs attention now"), Theme.danger, "exclamationmark.triangle.fill")
        }
    }

    static func severity(_ s: CheckupFinding.Severity) -> Color {
        switch s { case .high: Theme.danger; case .medium: Theme.caution; case .low: Theme.accent }
    }

    static func safety(_ s: CheckupFinding.Safety) -> (String, Color) {
        switch s {
        case .safe: return (tr("Safe to do"), Theme.good)
        case .interrupts: return (tr("Interrupts work"), Theme.caution)
        case .avoid: return (tr("Don't do it"), Theme.danger)
        }
    }

    static func icon(_ a: CheckupFinding.Area) -> String {
        switch a {
        case .memory: "memorychip"
        case .cpu: "cpu"
        case .thermal: "thermometer.medium"
        case .disk: "internaldrive"
        case .battery: "battery.75percent"
        case .processes: "gearshape.2"
        case .other: "info.circle"
        }
    }
}
