import Foundation
import ThermoL10n

/// Counts original text before redaction. No source text is retained or exported.
public struct TextFootprint: Codable, Equatable, Sendable {
    public var bytes: Int
    public var characters: Int
    public var lines: Int
    public var estimatedTokens: Int
    public let estimator: String

    public init(_ text: String) {
        bytes = text.utf8.count
        characters = text.count
        lines = text.isEmpty ? 0 : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let ascii = text.unicodeScalars.filter { $0.isASCII }.count
        estimatedTokens = (ascii + 3) / 4 + text.unicodeScalars.count - ascii
        estimator = "ascii4-unicode1-v1"
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

    public var summary: String {
        tr("Catalog ≈%1$@ tokens · SKILL.md ≈%2$@ tokens · %3$@ bytes",
           String(catalog.estimatedTokens), String(document.estimatedTokens), String(document.bytes))
    }

    public static var coverage: String {
        tr("Coverage: user-level Skill directories and enabled Claude plugins. Project Skills and the Codex plugin catalog are not included yet. Entries may include aliases of the same file.")
    }

    public static var caveat: String {
        tr("Static estimates use 4 ASCII characters or 1 Unicode scalar per token, not a model tokenizer. Catalog and SKILL.md are separate views; referenced files and actual session loading are not measured.")
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
            let a = $0.skillFootprint?.document.estimatedTokens ?? -1
            let b = $1.skillFootprint?.document.estimatedTokens ?? -1
            return a == b ? $0.id < $1.id : a > b
        }
        return ContextInventory(generated: env.now, skills: skills, mcpServers: items.filter { $0.area == .mcp },
                                findings: checks.findings.filter { $0.area == .skills || $0.area == .mcp },
                                cancelled: env.cancelled(), coverageNote: SkillFootprint.coverage, measurementNote: SkillFootprint.caveat,
                                mcpNote: tr("MCP definitions, connection timing and actual usage have not been measured. Configuration checks do not prove that a server is reachable or that its tools work."))
    }
}
