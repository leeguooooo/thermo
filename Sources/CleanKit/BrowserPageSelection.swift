import Foundation

extension ChromeInspector {
    /// Native main process identity, so an old plan cannot act on a restarted browser's reused tab IDs.
    public static func browserIdentity(app: String) -> ProcessIdentity? {
        let matches = ProcessTable.usage().compactMap { row -> ProcessIdentity? in
            guard let path = ProcessTable.pidPath(row.pid), path.contains("/\(app).app/Contents/MacOS/") else { return nil }
            return ProcessTable.identity(row.pid)
        }
        return matches.count == 1 ? matches.first : nil
    }

    public struct PageChoice: Identifiable, Sendable, Equatable {
        public let tab: Tab
        public let measured: Page?
        public let reasons: [String]
        public var id: String { tab.selectionID }
        public var recommended: Bool { tab.canSelect && tab.active == false && !reasons.isEmpty }
    }

    /// Recommendations are candidates for review. Large heap alone is never a reason to close.
    public static func pageChoices(tabs: [Tab], report: Report?, stale: Bool = false) -> [PageChoice] {
        let groups = Dictionary(grouping: tabs.filter { !$0.url.isEmpty && !isInternal($0.url) }, by: \.url)
        let metricGroups = Dictionary(grouping: report?.pages ?? [], by: { $0.url + "\u{0}" + $0.title })
        let tabGroups = Dictionary(grouping: tabs, by: { $0.url + "\u{0}" + $0.title })
        return tabs.map { tab in
            let key = tab.url + "\u{0}" + tab.title
            let metrics = metricGroups[key] ?? []
            // Identical pages cannot be paired to a measured target without inventing a mapping.
            let measured = metrics.count == 1 && tabGroups[key]?.count == 1 ? metrics.first : nil
            var reasons: [String] = []
            if tab.active == false && tab.canSelect && !isInternal(tab.url) {
                if let group = groups[tab.url], group.count > 1 {
                    let keep = group.first { $0.active != false } ?? group.first!
                    if tab.selectionID != keep.selectionID {
                        reasons.append(tr("Another page has the same address; keep the copy you need."))
                    }
                }
                if !stale, report?.invalidTimestamp != true, let measured, measured.leak != nil,
                   let growth = measured.growth, growth.seconds.isFinite, growth.seconds >= 30 {
                    reasons.append(tr("This page grew between two readings. If you no longer need it, consider closing it."))
                }
            }
            return PageChoice(tab: tab, measured: measured, reasons: reasons)
        }.sorted {
            if $0.recommended != $1.recommended { return $0.recommended }
            return ($0.tab.window, $0.tab.index) < ($1.tab.window, $1.tab.index)
        }
    }

    public struct TabCloseResult: Codable, Sendable, Equatable, Identifiable {
        public enum Status: String, Codable, Sendable { case closed, missing, changed, becameActive, failed, unavailable }
        public let id: String
        public let status: Status
        public init(id: String, status: Status) { self.id = id; self.status = status }
    }

    /// Every selected tab is rechecked by unique ID and snapshot URL/title; never falls back to URL.
    public static func closeTabs(_ selected: [Tab], app: String,
                                 identity: (String) -> ProcessIdentity? = { browserIdentity(app: $0) },
                                 execute: ((String) -> String?)? = nil) -> [TabCloseResult] {
        let execute = execute ?? { osascript($0) }
        func refused() -> [TabCloseResult] { selected.map { .init(id: $0.selectionID, status: .unavailable) } }
        guard !selected.isEmpty, selected.allSatisfy(\.canSelect),
              Set(selected.map(\.selectionID)).count == selected.count,
              let process = selected.first?.browserProcess, selected.allSatisfy({ $0.browserProcess == process }),
              process == identity(app) else { return refused() }
        let payload = selected.map { ["key": $0.selectionID, "id": $0.browserID!, "url": $0.url, "title": $0.title,
                                      "protectActive": $0.active != true] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return refused() }
        let script = """
        const app = Application(\(jsString(app)));
        const requests = \(String(decoding: data, as: UTF8.self));
        const results = requests.map(r => {
          try {
            if (!app.running()) return {id:r.key, status:'missing'};
            let hits = [];
            for (const w of app.windows()) {
              const tabs = w.tabs();
              for (let i=0;i<tabs.length;i++) if (String(tabs[i].id()) === r.id) hits.push({tab:tabs[i],window:w,index:i+1});
            }
            if (!hits.length) return {id:r.key, status:'missing'};
            if (hits.length !== 1) return {id:r.key, status:'unavailable'};
            const h = hits[0];
            if (h.tab.url() !== r.url || h.tab.title() !== r.title) return {id:r.key,status:'changed'};
            if (r.protectActive && h.window.activeTabIndex() === h.index) return {id:r.key,status:'becameActive'};
            h.tab.close();
            return {id:r.key,status:'closed'};
          } catch(e) { return {id:r.key,status:'failed'}; }
        });
        JSON.stringify(results);
        """
        guard process == identity(app), let out = execute(script),
              let result = try? JSONDecoder().decode([TabCloseResult].self, from: Data(out.utf8)),
              result.count == selected.count, Set(result.map(\.id)) == Set(selected.map(\.selectionID)) else { return refused() }
        return result
    }
}

/// Overall browser footprint and system conditions around the user-confirmed page closure.
public struct BrowserCloseReading: Sendable {
    public let pulse: MachinePulse
    public let browserMemoryKB: Int?
    public init(pulse: MachinePulse, browserMemoryKB: Int?) { self.pulse = pulse; self.browserMemoryKB = browserMemoryKB }
    public static func sample(app: String) -> BrowserCloseReading {
        let pulse = MachinePulse.sample()
        let programs = MachinePulse.group(ProcessTable.current(.init(cpu: false)).entries, byMemory: true, limit: nil)
        return .init(pulse: pulse, browserMemoryKB: programs.first { $0.name == app }?.memoryKB)
    }
}

public struct BrowserCloseReview: Sendable {
    public let results: [ChromeInspector.TabCloseResult]
    public let remaining: [ChromeInspector.Tab]?
    public let before: BrowserCloseReading
    public let after: BrowserCloseReading
    public var closed: Int { results.filter { $0.status == .closed }.count }
    public var skipped: Int { results.count - closed }
    public var verified: Int? {
        guard let remaining else { return nil }
        let present = Set(remaining.map(\.selectionID))
        return results.filter { !present.contains($0.id) }.count
    }
    public init(results: [ChromeInspector.TabCloseResult], remaining: [ChromeInspector.Tab]?,
                before: BrowserCloseReading, after: BrowserCloseReading) {
        self.results = results; self.remaining = remaining; self.before = before; self.after = after
    }
    public var summary: String {
        if let verified {
            return tr("Closed %1$@ of %2$@ selected pages; %3$@ no longer appear in the tab list.", String(closed), String(results.count), String(verified))
        }
        return tr("Closed %1$@ of %2$@ selected pages; the tab list could not be rechecked.", String(closed), String(results.count))
    }
    public var detail: String {
        var lines: [String] = []
        if skipped > 0 { lines.append(tr("%1$@ pages were skipped or their close result is unconfirmed. Changed pages and newly active pages are kept.", String(skipped))) }
        let elapsed = after.pulse.sampled.timeIntervalSince(before.pulse.sampled)
        guard elapsed.isFinite, elapsed >= 1, elapsed <= 180 else {
            lines.append(tr("The follow-up readings cannot be compared. Check again."))
            return lines.joined(separator: "\n")
        }
        if let initial = before.browserMemoryKB, let current = after.browserMemoryKB, initial >= 0, current >= 0 {
            lines.append(tr("Browser memory use: %1$@ → %2$@.", MemoryFormat.string(kibibytes: initial), MemoryFormat.string(kibibytes: current)))
        } else { lines.append(tr("Browser memory could not be compared; no reduction is claimed.")) }
        lines.append(tr("Memory pressure: %1$@ → %2$@. Thermal pressure: %3$@ → %4$@. One-minute load: %5$@ → %6$@.",
                        MachinePulse.memoryName(before.pulse.memory), MachinePulse.memoryName(after.pulse.memory),
                        MachinePulse.thermalName(before.pulse.thermal), MachinePulse.thermalName(after.pulse.thermal),
                        before.pulse.load1.isFinite ? String(format: "%.1f", before.pulse.load1) : "—",
                        after.pulse.load1.isFinite ? String(format: "%.1f", after.pulse.load1) : "—"))
        lines.append(tr("This is a short follow-up; swap and load averages may take longer to change."))
        return lines.joined(separator: "\n")
    }
}
