import Foundation

/// The AI check-up: what Thermo measured about this Mac right now, sent once to the local AI, which
/// answers with findings in plain words — above all whether acting on each one interrupts the
/// person's work. Facts only (names, sizes, readings, Thermo's own diagnosis); never file contents.
/// Advice only: nothing is ended, cleaned or changed from here.
public struct CheckupSnapshot: Sendable {
    public struct Fan: Sendable, Hashable {
        public var name: String
        public var rpm: Double?
        public var max: Double?
        public var manual: Bool?
        public init(name: String, rpm: Double?, max: Double?, manual: Bool?) { self.name = name; self.rpm = rpm; self.max = max; self.manual = manual }
    }
    public struct Battery: Sendable, Hashable {
        public var percent: Double?
        /// Full-charge / design capacity, 0...1.
        public var health: Double?
        public var cycles: Int?
        public var charging: Bool
        public var externalPower: Bool
        public init(percent: Double?, health: Double?, cycles: Int?, charging: Bool, externalPower: Bool) {
            self.percent = percent; self.health = health; self.cycles = cycles; self.charging = charging; self.externalPower = externalPower
        }
    }

    public var model: String?
    public var uptime: TimeInterval?
    public var cpuTemperature: Double?
    public var gpuTemperature: Double?
    /// macOS thermal state: nominal, fair, serious, critical.
    public var thermalState: String?
    public var fans: [Fan]
    public var battery: Battery?
    public var diskFree: Int64?
    public var diskTotal: Int64?
    /// Thermo's own slowdown diagnosis: memory, CPU and the programs behind them.
    public var diagnosis: SlowdownDiagnosis?
    public var home: String

    public init(model: String? = nil, uptime: TimeInterval? = nil, cpuTemperature: Double? = nil, gpuTemperature: Double? = nil,
                thermalState: String? = nil, fans: [Fan] = [], battery: Battery? = nil, diskFree: Int64? = nil, diskTotal: Int64? = nil,
                diagnosis: SlowdownDiagnosis? = nil, home: String = NSHomeDirectory()) {
        self.model = model; self.uptime = uptime; self.cpuTemperature = cpuTemperature; self.gpuTemperature = gpuTemperature
        self.thermalState = thermalState; self.fans = fans; self.battery = battery; self.diskFree = diskFree; self.diskTotal = diskTotal
        self.diagnosis = diagnosis; self.home = home
    }

    /// The programs Thermo named, numbered as in `facts`; findings point back by that number.
    public var culprits: [SlowdownCulprit] { (diagnosis?.culprits ?? []) + (diagnosis?.also ?? []) }

    func tilde(_ s: String) -> String { s.replacingOccurrences(of: home + "/", with: "~/") }

    /// Exactly what is sent, shown to the user before the first check-up.
    public var facts: String {
        let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .memory) }
        let disk = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        var lines: [String] = []
        if let model { lines.append("Mac: \(model)") }
        if let uptime { lines.append("Up for: \(Int(uptime / 3600)) h") }
        if let d = diagnosis {
            let s = d.system
            lines.append("Memory: \(size(Int64(s.memoryBytes))), pressure \(s.pressure.rawValue), swap used \(size(Int64(s.swapUsed))) of \(size(Int64(s.swapTotal)))")
            lines.append("CPU: \(s.cores) cores, 1-minute load \(String(format: "%.1f", s.load1))")
            lines.append("Thermo's verdict: memory \(d.memoryStrain.rawValue), CPU \(d.cpuStrain.rawValue). \(tilde(d.headline))")
        }
        var heat: [String] = []
        if let t = cpuTemperature { heat.append("CPU \(Int(t.rounded())) °C") }
        if let t = gpuTemperature { heat.append("GPU \(Int(t.rounded())) °C") }
        if let s = thermalState { heat.append("macOS thermal state \(s)") }
        if !heat.isEmpty { lines.append("Heat: " + heat.joined(separator: ", ")) }
        for f in fans {
            var parts = [f.rpm.map { "\(Int($0)) rpm" } ?? "rpm unknown"]
            if let m = f.max, m > 0, let r = f.rpm { parts.append("\(Int((r / m * 100).rounded()))% of max") }
            if let manual = f.manual { parts.append(manual ? "set by hand in Thermo" : "automatic") }
            lines.append("Fan \(f.name): " + parts.joined(separator: ", "))
        }
        if let b = battery {
            var parts: [String] = []
            if let p = b.percent { parts.append("\(Int(p.rounded()))%") }
            if let h = b.health { parts.append("health \(Int((h * 100).rounded()))% of design") }
            if let c = b.cycles { parts.append("\(c) cycles") }
            parts.append(b.charging ? "charging" : b.externalPower ? "on power, not charging" : "on battery")
            lines.append("Battery: " + parts.joined(separator: ", "))
        }
        if let free = diskFree, let total = diskTotal { lines.append("Disk: \(disk(free)) free of \(disk(total))") }
        let named = culprits
        if !named.isEmpty {
            lines.append("Programs Thermo flagged (numbered):")
            for (i, c) in named.prefix(10).enumerated() {
                var head = ["\(i + 1). \(c.name) [\(c.kind.rawValue)]"]
                if c.freesKB >= 64 * 1024 { head.append("acting frees ~\(size(Int64(c.freesKB) * 1024))") }
                if c.cpu >= 5 { head.append(String(format: "%.0f%% CPU", c.cpu)) }
                if let l = c.launcher { head.append("started by \(tilde(l))") }
                if let p = c.project { head.append("project \(tilde(p))") }
                lines.append(head.joined(separator: " · "))
                lines.append("   Thermo saw: \(tilde(c.evidence))")
                lines.append("   Thermo suggests: \(tilde(c.guidance))")
                if let s = c.sessions, !s.isEmpty { lines.append("   Sessions: " + s.prefix(6).map(tilde).joined(separator: "; ")) }
            }
        }
        return lines.joined(separator: "\n")
    }
}

public struct CheckupFinding: Sendable, Equatable, Identifiable {
    public enum Area: String, Sendable, CaseIterable { case memory, cpu, thermal, disk, battery, processes, other }
    public enum Severity: String, Sendable, Comparable {
        case high, medium, low
        var rank: Int { switch self { case .high: 0; case .medium: 1; case .low: 2 } }
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }
    /// What acting on it does to the work in progress.
    public enum Safety: String, Sendable { case safe, interrupts, avoid }

    public var id: String { "\(area.rawValue):\(title)" }
    public var area: Area
    public var severity: Severity
    public var title: String
    public var detail: String
    /// In the person's words: what happens to their current work if they act.
    public var impact: String
    public var safety: Safety
    public var how: String?
    /// The flagged program it is about, when there is one.
    public var culprit: SlowdownCulprit?
}

public struct CheckupReport: Sendable, Equatable {
    public enum Overall: String, Sendable { case good, attention, urgent }
    public var overall: Overall
    public var summary: String
    /// Most severe first.
    public var findings: [CheckupFinding]
    public var source: String
    public var made: Date
}

extension LocalAI {
    static let checkupSystem = """
    You give someone a health check-up of their Mac. You get what Thermo (a system monitor) measured just now, \
    including the programs it flagged and why. The person is a developer running AI coding agents and is afraid \
    that acting will break work in progress, so for every finding say plainly what happens to their current work. \
    Reply with ONLY a JSON object: {"overall": "good" | "attention" | "urgent", "summary": "<two or three sentences: \
    how the Mac is doing and the one thing to do first>", "findings": [{"area": "memory" | "cpu" | "thermal" | "disk" | \
    "battery" | "processes" | "other", "severity": "high" | "medium" | "low", "title": "<short>", "detail": "<what is \
    going on, one or two sentences>", "impact": "<what acting does to their work: e.g. nothing in use stops / the \
    Codex sessions in ~/x lose their current task but conversations can be resumed>", "safety": "safe" | "interrupts" | \
    "avoid", "how": "<the step or command, or empty>", "culprit": <number of the flagged program, or 0>}]}. \
    "safe": nothing the person is using stops. "interrupts": something in use restarts or loses its current task; say what \
    and when it is better to do it. "avoid": would lose data or break the system. Order findings by what to do first. \
    Only state facts that are in the input; do not invent programs or numbers. Normal readings need no finding unless \
    they reassure (e.g. 79 °C under load is fine for Apple silicon). Be concrete and brief.
    """

    public static func checkup(_ s: CheckupSnapshot, using backend: LocalAIBackend, session: URLSession = .shared, now: Date = Date()) async throws -> CheckupReport {
        let lang = Locale.preferredLanguages.first ?? "en"
        let raw = try await send(system: checkupSystem, user: s.facts + "\n\nAnswer in the language with code \(lang).",
                                 using: backend, maxTokens: 6000, session: session)
        guard let report = parseCheckup(raw, snapshot: s, source: backend.label, now: now) else { throw LocalAIError.emptyAnswer }
        return report
    }

    /// Unknown areas become `other`, unknown severities `low`, unknown safety `interrupts` (the cautious
    /// reading); a culprit number outside the list is dropped rather than guessed.
    public static func parseCheckup(_ raw: String, snapshot s: CheckupSnapshot, source: String, now: Date = Date()) -> CheckupReport? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        struct Item: Decodable {
            var area: String?; var severity: String?; var title: String; var detail: String?; var impact: String?
            var safety: String?; var how: String?; var culprit: Int?
            enum CodingKeys: String, CodingKey { case area, severity, title, detail, impact, safety, how, culprit }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                area = try? c.decode(String.self, forKey: .area); severity = try? c.decode(String.self, forKey: .severity)
                title = try c.decode(String.self, forKey: .title); detail = try? c.decode(String.self, forKey: .detail)
                impact = try? c.decode(String.self, forKey: .impact); safety = try? c.decode(String.self, forKey: .safety)
                how = try? c.decode(String.self, forKey: .how)
                culprit = (try? c.decode(Int.self, forKey: .culprit)) ?? (try? c.decode(String.self, forKey: .culprit)).flatMap { Int($0) }
            }
        }
        struct Wire: Decodable { var overall: String?; var summary: String?; var findings: [Item]? }
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let w = try? JSONDecoder().decode(Wire.self, from: Data(text[a...b].utf8)) else { return nil }
        let named = s.culprits
        let trim = { (x: String?) -> String? in
            let t = x?.trimmingCharacters(in: .whitespacesAndNewlines); return t?.isEmpty == false ? t : nil
        }
        let findings = (w.findings ?? []).enumerated().compactMap { index, i -> (Int, CheckupFinding)? in
            guard let title = trim(i.title) else { return nil }
            let culprit = i.culprit.flatMap { $0 >= 1 && $0 <= named.count ? named[$0 - 1] : nil }
            return (index, CheckupFinding(area: CheckupFinding.Area(rawValue: (i.area ?? "").lowercased()) ?? .other,
                                          severity: CheckupFinding.Severity(rawValue: (i.severity ?? "").lowercased()) ?? .low,
                                          title: title, detail: trim(i.detail) ?? "", impact: trim(i.impact) ?? "",
                                          safety: CheckupFinding.Safety(rawValue: (i.safety ?? "").lowercased()) ?? .interrupts,
                                          how: trim(i.how), culprit: culprit))
        }
        // Severity first; within one severity keep the AI's "do this first" order.
        .sorted { ($0.1.severity, $0.0) < ($1.1.severity, $1.0) }.map(\.1)
        let summary = trim(w.summary) ?? ""
        guard !summary.isEmpty || !findings.isEmpty else { return nil }
        let overall = CheckupReport.Overall(rawValue: (w.overall ?? "").lowercased())
            ?? (findings.contains { $0.severity == .high } ? .urgent : findings.isEmpty ? .good : .attention)
        return CheckupReport(overall: overall, summary: summary, findings: findings, source: source, made: now)
    }
}
