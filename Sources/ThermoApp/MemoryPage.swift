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

    @Published private(set) var breakdown: MemoryBreakdown?
    @Published private(set) var programs: [MachinePulse.Hog] = []
    @Published private(set) var suspects: [MemorySuspect] = []
    @Published private(set) var day: [PulseRecord] = []
    private var timer: Timer?
    private var sampling = false
    private var dayLoaded = Date.distantPast

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { MemoryModel.shared.sample() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func sample() {
        guard !sampling else { return }
        sampling = true
        if Date().timeIntervalSince(dayLoaded) >= 60 { loadDay() }
        Task.detached(priority: .utility) {
            let b = MemoryBreakdown.read()
            let all = MachinePulse.group(ProcessTable.current(.init(cpu: false)).entries, byMemory: true, limit: nil)
                .filter { $0.memoryKB >= 50 * 1024 }.sorted { $0.memoryKB > $1.memoryKB }
            let history = PulseRecorder.shared.programHistory.records(since: Date().addingTimeInterval(-PulseHistory.keep))
            let suspects = MemorySuspects.find(programs: all, history: history)
            await MainActor.run {
                var list = all
                for i in list.indices {
                    if let path = list[i].app,
                       let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == path }) {
                        list[i].applicationIdentity = ProcessTable.identity(app.processIdentifier)
                    }
                }
                self.breakdown = b
                self.programs = list
                self.suspects = suspects
                self.sampling = false
            }
        }
    }

    func loadDay() {
        dayLoaded = Date()
        Task.detached(priority: .utility) {
            let records = PulseRecorder.shared.history.records(since: Date().addingTimeInterval(-PulseHistory.keep))
            await MainActor.run { self.day = records }
        }
    }
}

struct MemoryPage: View {
    @ObservedObject var model: MemoryModel
    @ObservedObject private var pulse = SystemPulse.shared
    let open: (MainPage) -> Void
    @State private var hours = 6
    @State private var expanded: Set<String> = []
    @State private var confirming: MachinePulse.Hog?
    @State private var restartTarget: MachinePulse.Hog?
    @State private var showAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let b = model.breakdown {
                    if b.swapBlocked { swapBlockedBanner(b) }
                    breakdownCard(b)
                    trendCard
                    if !model.suspects.isEmpty { suspectsCard }
                    programsCard
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
                Text(tr("Swap has no room to grow")).font(.callout.weight(.semibold)).foregroundStyle(.white)
                Text(tr("When memory is short macOS writes some of it to the disk. With only %1$@ free, that fails and macOS asks you to force quit apps, even ones using little memory.",
                        ByteFormat.string(b.diskFree ?? 0)))
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
                pill(tr("Pressure: %1$@", MachinePulse.memoryName(b.pressure)), color: b.pressure == .normal ? .green : b.pressure == .warning ? .orange : .red)
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
                        Text(b.swapFiles > 0 ? tr("%1$@ of %2$@", MemoryFormat.string(bytes: b.swapUsed), MemoryFormat.string(bytes: b.swapFiles)) : tr("none"))
                            .font(.callout.monospacedDigit()).foregroundStyle(b.swapUsed >= 4 << 30 ? .orange : .white)
                    }
                }
                .accessibilityElement(children: .combine)
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
                            LineMark(x: .value("t", r.t), y: .value("GB", Double(used) / 1024), series: .value("k", "used"))
                                .foregroundStyle(by: .value("k", tr("Memory used")))
                        }
                        LineMark(x: .value("t", r.t), y: .value("GB", Double(r.swapUsedMB) / 1024), series: .value("k", "swap"))
                            .foregroundStyle(by: .value("k", tr("Swap")))
                        if r.memory != .normal {
                            RuleMark(x: .value("t", r.t)).foregroundStyle(r.memory == .critical ? Color.red.opacity(0.25) : Color.orange.opacity(0.18))
                        }
                    }
                    if let b = model.breakdown {
                        RuleMark(y: .value("GB", Double(b.total) / 1_073_741_824)).foregroundStyle(.white.opacity(0.25))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartForegroundStyleScale([tr("Memory used"): Color.green, tr("Swap"): Color.yellow])
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) GB") } } } }
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
            Label(tr("Worth a restart"), systemImage: "arrow.triangle.2.circlepath").font(.callout.weight(.semibold)).foregroundStyle(.orange)
            ForEach(model.suspects) { s in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                        Text(s.text).font(.caption).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(MemoryFormat.string(kibibytes: s.memoryKB)).font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                    if let h = model.programs.first(where: { $0.id == s.id }) { actions(h, emphasizeRestart: true) }
                }
            }
        }
        .padding(16).glass(radius: 16)
    }

    // MARK: Programs

    var programsCard: some View {
        let list = showAll ? model.programs : Array(model.programs.prefix(15))
        let top = Double(max(1, model.programs.first?.memoryKB ?? 1))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Programs by memory")).font(.callout.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Text(tr("helpers and pages counted with their app")).font(.caption).foregroundStyle(.white.opacity(0.45))
            }
            ForEach(list) { h in programRow(h, top: top) }
            if model.programs.count > 15 {
                Button(showAll ? tr("Show fewer") : tr("Show all %1$@", String(model.programs.count))) { showAll.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
            ForEach([pulse.quitProblem, pulse.restartProblem, pulse.actionFeedback].compactMap { $0 }, id: \.self) { t in
                Text(t).font(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).glass(radius: 16)
    }

    func programRow(_ h: MachinePulse.Hog, top: Double) -> some View {
        let open_ = expanded.contains(h.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let app = h.app {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable().frame(width: 22, height: 22).accessibilityHidden(true)
                } else {
                    Image(systemName: "terminal").frame(width: 22, height: 22).foregroundStyle(.white.opacity(0.6)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(h.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        if h.pids.count > 1 { Text("×\(h.pids.count)").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.45)) }
                    }
                    Text(detail(h)).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(Color.green.opacity(0.7)).frame(width: max(2, g.size.width * CGFloat(Double(h.memoryKB) / top)))
                    }
                }
                .frame(width: 80, height: 5).accessibilityHidden(true)
                Text(MemoryFormat.string(kibibytes: h.memoryKB)).font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9)).frame(width: 72, alignment: .trailing)
                actions(h, emphasizeRestart: false)
            }
            .contentShape(Rectangle())
            .onTapGesture { if h.parts != nil { if open_ { expanded.remove(h.id) } else { expanded.insert(h.id) } } }
            if open_, let parts = h.parts {
                ForEach(parts, id: \.pid) { p in
                    HStack {
                        Text("\(MachinePulse.roleName(p.role)) · pid \(p.pid)").font(.caption.monospaced()).foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Text(MemoryFormat.string(kibibytes: p.memoryKB)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.leading, 32)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// "shop · started by Claude Code · up 26 h · mostly compressed".
    func detail(_ h: MachinePulse.Hog) -> String {
        var parts: [String] = []
        if let p = h.project { parts.append((p as NSString).lastPathComponent) }
        if let o = h.owner { parts.append(tr("started by %1$@", o)) }
        if let up = h.uptime { parts.append(tr("up %1$@", MemorySuspects.duration(up))) }
        if let r = h.residentKB, h.memoryKB >= 200 * 1024, r * 2 < h.memoryKB { parts.append(tr("mostly compressed or swapped out")) }
        if let n = h.pagesOpened, n > 0 { parts.append(tr("%1$@ pages opened since launch", String(n))) }
        if h.parts != nil { parts.append(tr("click for its processes")) }
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
