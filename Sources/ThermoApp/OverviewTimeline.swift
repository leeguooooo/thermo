import AgentCore
import Charts
import CleanKit
import SwiftUI
import ThermoL10n

/// What happened in the last 15 minutes that can explain a curve: a program that started or
/// stopped keeping cores busy (with its project and agent), and every change Thermo itself made.
@MainActor
final class TimelineEvents: ObservableObject {
    static let shared = TimelineEvents()
    static let window: TimeInterval = 900

    struct Event: Identifiable, Equatable {
        enum Kind: Equatable { case busy, calm, operation }
        let id = UUID()
        let time: Date
        let kind: Kind
        let text: String
        var symbol: String {
            switch kind {
            case .busy: return "flame"
            case .calm: return "leaf"
            case .operation: return "wrench.and.screwdriver"
            }
        }
    }

    @Published private(set) var events: [Event] = []
    private var busy: [String: Date] = [:]
    private var lastJournal = Date.distantPast
    private var journal: [Event] = []

    /// A program counts as busy from 80% of a core and as calm again below 20%, so one that hovers
    /// around a threshold does not flood the timeline.
    static let busyCPU = 80.0, calmCPU = 20.0

    func observe(_ pulse: MachinePulse, now: Date = Date()) {
        var live: [Event] = events.filter { $0.kind != .operation }
        let byID = Dictionary(pulse.hogs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for hog in pulse.hogs where hog.cpu >= Self.busyCPU && busy[hog.id] == nil {
            busy[hog.id] = now
            live.append(Event(time: now, kind: .busy, text: tr("%1$@ became busy", Self.label(hog))))
        }
        for (id, since) in busy where (byID[id]?.cpu ?? 0) < Self.calmCPU {
            busy[id] = nil
            let name = byID[id].map(Self.label) ?? Self.name(fromID: id)
            live.append(Event(time: now, kind: .calm, text: tr("%1$@ calmed down after %2$@", name, Self.duration(now.timeIntervalSince(since)))))
        }
        publish(live, now: now)
    }

    /// Thermo's own operations from the shared history, re-read at most every 30 seconds.
    func refreshJournal(now: Date = Date(), read: () -> [OperationRecord] = { OperationJournal.read(limit: 40) }) {
        guard now.timeIntervalSince(lastJournal) >= 30 else { return }
        lastJournal = now
        journal = read().filter { now.timeIntervalSince($0.time) <= Self.window }
            .map { Event(time: $0.time, kind: .operation, text: $0.title + ($0.subject.map { " · " + $0 } ?? "")) }
        publish(events.filter { $0.kind != .operation }, now: now)
    }

    private func publish(_ live: [Event], now: Date) {
        let cutoff = now.addingTimeInterval(-Self.window)
        let merged = (live + journal).filter { $0.time >= cutoff }.sorted { $0.time < $1.time }
        events = Array(merged.suffix(40))
    }

    /// "swift-build (thermo · Claude Code)" or "Google Chrome".
    static func label(_ hog: MachinePulse.Hog) -> String {
        let folder = hog.project.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty || $0 == "~" ? nil : $0 }
        let origin = [folder, hog.owner].compactMap { $0 }
        return origin.isEmpty ? hog.name : hog.name + " (" + origin.joined(separator: " · ") + ")"
    }

    static func name(fromID id: String) -> String {
        String(id.split(separator: "|").first ?? Substring(id))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds >= 60 ? tr("%1$@ min", String(Int(seconds / 60))) : tr("%1$@ s", String(max(1, Int(seconds))))
    }
}

/// Temperature over load for the last 15 minutes, with the events above drawn across both.
struct HeatTimeline: View {
    let history: [HistoryPoint]
    let events: [TimelineEvents.Event]
    var now = Date()
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    var domain: ClosedRange<Date> { now.addingTimeInterval(-TimelineEvents.window)...now }
    func temperature(_ c: Double) -> Double { fahrenheit ? c * 9 / 5 + 32 : c }
    var temperatureDomain: ClosedRange<Double> {
        let values = history.flatMap { [$0.cpu, $0.gpu].compactMap { $0 } }.filter(\.isFinite)
        return temperature(min(30, (values.min() ?? 30) - 5))...temperature(max(100, (values.max() ?? 100) + 5))
    }
    var loadTop: Double { max(2, (history.compactMap(\.load).filter(\.isFinite).max() ?? 0) * 1.15) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(history) { p in
                    if let c = p.cpu, c.isFinite {
                        LineMark(x: .value("Time", p.time), y: .value("°", temperature(c)), series: .value("Sensor", "CPU"))
                            .foregroundStyle(by: .value("Sensor", "CPU")).interpolationMethod(.monotone)
                    }
                    if let g = p.gpu, g.isFinite {
                        LineMark(x: .value("Time", p.time), y: .value("°", temperature(g)), series: .value("Sensor", "GPU"))
                            .foregroundStyle(by: .value("Sensor", "GPU")).interpolationMethod(.monotone)
                    }
                }
                ForEach(events) { e in
                    RuleMark(x: .value("Time", e.time))
                        .foregroundStyle(Theme.border).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, spacing: 2) {
                            Image(systemName: e.symbol).font(.system(size: 9)).foregroundStyle(color(e.kind))
                        }
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: temperatureDomain)
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { v in AxisGridLine().foregroundStyle(Theme.hairline); AxisValueLabel { axisLabel(v.as(Double.self)) } } }
            .chartXAxis(.hidden)
            .chartYAxisLabel(fahrenheit ? "°F" : "°C")
            .chartLegend(position: .top, alignment: .trailing)
            .chartForegroundStyleScale(["CPU": Theme.caution, "GPU": Color(red: 1.0, green: 0.45, blue: 0.62)])
            .chartOverlay { _ in
                if !history.contains(where: { $0.cpu?.isFinite == true || $0.gpu?.isFinite == true }) {
                    Text(tr("Waiting for temperature readings…")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 110)
            .accessibilityLabel(tr("Temperature, last 15 minutes"))

            Chart {
                ForEach(history) { p in
                    if let l = p.load, l.isFinite {
                        AreaMark(x: .value("Time", p.time), y: .value("Load", min(l, loadTop)))
                            .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.time), y: .value("Load", min(l, loadTop))).foregroundStyle(Theme.accent).interpolationMethod(.monotone)
                    }
                }
                RuleMark(y: .value("Load", 1)).foregroundStyle(Theme.border).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 1) {
                        Text(tr("all cores busy")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                ForEach(events) { e in
                    RuleMark(x: .value("Time", e.time))
                        .foregroundStyle(Theme.border).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...loadTop)
            .chartYAxis { AxisMarks(values: Array(Set([0, 1, max(2, (loadTop * 0.9).rounded(.down))])).sorted()) { v in AxisGridLine().foregroundStyle(Theme.hairline); AxisValueLabel { axisLabel(v.as(Double.self)) } } }
            .chartYAxisLabel(tr("load per core"))
            // Every 5 minutes back from now; "now" itself would sit on the edge and be clipped.
            .chartXAxis { AxisMarks(values: [15, 10, 5].map { now.addingTimeInterval(-Double($0) * 60) }) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel(format: .dateTime.hour().minute()).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            } }
            .frame(height: 80)
            .accessibilityLabel(tr("Load per core, last 15 minutes"))

            if events.isEmpty {
                Text(tr("No program became busy and Thermo changed nothing in this window."))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).padding(.top, Theme.Space.s)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(events.suffix(5).reversed()) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(e.time.formatted(date: .omitted, time: .shortened)).font(Theme.caption.monospacedDigit())
                                .foregroundStyle(Theme.textTertiary).frame(width: 44, alignment: .leading)
                            Image(systemName: e.symbol).font(.system(size: 10)).foregroundStyle(color(e.kind)).frame(width: 14)
                                .accessibilityHidden(true)
                            Text(e.text).font(Theme.secondary).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .padding(.top, Theme.Space.s)
            }
        }
    }

    /// Same width on both charts, so their plot areas — and the event lines across them — line up.
    func axisLabel(_ value: Double?) -> some View {
        Text(value.map { String(format: "%.0f", $0) } ?? "").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
            .frame(width: 28, alignment: .leading)
    }

    func color(_ kind: TimelineEvents.Event.Kind) -> Color {
        switch kind {
        case .busy: return Theme.caution
        case .calm: return Theme.good
        case .operation: return Theme.accent
        }
    }
}
