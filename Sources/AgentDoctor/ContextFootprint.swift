import Foundation
import ThermoL10n

/// Counts original text before redaction. No source text is retained or exported.
public struct TextFootprint: Codable, Equatable, Sendable {
    public var bytes: Int
    public var characters: Int
    public var lines: Int
    public var estimatedTokens: Int
    public let estimator: String
    public var referenceEncoding: String? = nil
    public var referenceTokens: Int? = nil
    public var referenceError: String? = nil
    public var comparisonTokens: Int? { referenceEncoding == nil ? estimatedTokens : referenceTokens }
    public var tokenLabel: String { comparisonTokens.map(String.init) ?? tr("Unknown") }

    public init(_ text: String, encoding: TextEncoding = .heuristic) {
        bytes = text.utf8.count
        characters = text.count
        lines = text.isEmpty ? 0 : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let ascii = text.unicodeScalars.filter { $0.isASCII }.count
        estimatedTokens = (ascii + 3) / 4 + text.unicodeScalars.count - ascii
        estimator = "ascii4-unicode1-v1"
        if encoding != .heuristic {
            referenceEncoding = encoding.rawValue
            let measured = ReferenceTokenizer.measure(text, encoding: encoding)
            referenceTokens = measured.count; referenceError = measured.error
        }
    }
}

public struct SkillFootprint: Codable, Equatable, Sendable {
    /// Name and complete description, as an approximation of a discovery catalog entry.
    public var catalog: TextFootprint
    /// Full SKILL.md, including front matter; separate from the catalog, not additive.
    public var document: TextFootprint
    public var body: TextFootprint
    public var sourcePath: String
    public var contentHash: String
    /// Device/inode identity, with a canonical-path fallback; only its hash is exported.
    public var canonicalID: String? = nil
    public var scope: String? = nil
    public var namespace: String? = nil
    public var pluginConfiguredEnabled: Bool? = nil
    public var codexConfiguredEnabled: Bool? = nil
    public var quality: SkillQualityReport? = nil
    public var identicalContentFiles: Int? = nil

    public var summary: String {
        let counts = tr("Catalog ≈%1$@ tokens · SKILL.md ≈%2$@ tokens · %3$@ bytes",
           catalog.tokenLabel, document.tokenLabel, String(document.bytes))
        return codexConfiguredEnabled == false ? counts + " · " + tr("Disabled in Codex configuration; file retained in inventory") : counts
    }

    public static var coverage: String {
        tr("Coverage: user Skill directories, enabled Claude plugins and Codex plugin cache inventories. Project directories are included only with an explicit project root. Cache presence does not prove loading; admin and remotely supplied Skills are not inspected.")
    }

    public static var caveat: String {
        tr("Heuristic fields use 4 ASCII characters or 1 Unicode scalar per token. Optional ordinary-text reference counts use the selected encoding; they do not prove a model’s actual prompt or billed usage. Catalog and SKILL.md remain separate views; referenced files and actual loading are not measured.")
    }
}

/// Configuration-only analysis: never starts a server or queries process/launchd state.
public struct ContextInventory: Codable, Sendable {
    public var generated: Date
    public var skills: [AgentItem]
    public var mcpServers: [AgentItem]
    public var findings: [Finding]
    public var cancelled: Bool
    public var coverageNote: String
    public var measurementNote: String
    public var mcpNote: String
    public var referenceEncoding: String? = nil
    public var referenceEngine: String? = nil
    public var project: String? = nil
    public var summaries: [SkillContextSummary] = []
    /// Optional for reports written before unique-file content summaries were available.
    public var qualitySummaries: [SkillQualitySummary]? = nil
}

extension AgentDoctor {
    public static func context(_ env: DoctorEnvironment = DoctorEnvironment()) -> ContextInventory {
        var checks = ConfigChecks(env: env)
        checks.runAll()
        var items = checks.items
        for i in items.indices {
            items[i].severity = checks.findings.filter { $0.item == items[i].id }.map(\.severity).min()
        }
        let skills = items.filter { $0.area == .skills }.sorted {
            let a = $0.skillFootprint?.document.comparisonTokens ?? -1
            let b = $1.skillFootprint?.document.comparisonTokens ?? -1
            return a == b ? $0.id < $1.id : a > b
        }
        return ContextInventory(generated: env.now, skills: skills, mcpServers: items.filter { $0.area == .mcp },
                                findings: checks.findings.filter { $0.area == .skills || $0.area == .mcp },
                                cancelled: env.cancelled(), coverageNote: SkillFootprint.coverage, measurementNote: SkillFootprint.caveat,
                                mcpNote: tr("MCP definitions, connection timing and actual usage have not been measured. Configuration checks do not prove that a server is reachable or that its tools work."), referenceEncoding: env.tokenEncoding == .heuristic ? nil : env.tokenEncoding.rawValue, referenceEngine: env.tokenEncoding == .heuristic ? nil : ReferenceTokenizer.engine, project: env.project.map { Redact.text(env.short($0.path)) }, summaries: SkillContextSummary.summarize(skills), qualitySummaries: SkillQualitySummary.summarize(skills))
    }
}
