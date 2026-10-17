import Foundation

/// Unique-file content evidence, split by host and inventory scope, never a health score.
public struct SkillQualitySummary: Codable, Equatable, Sendable {
    public var host: String
    /// "directory" includes configured plugin files; "cache" never proves current loading.
    public var scope: String
    public var entries = 0
    public var uniqueFiles = 0
    public var inspectedFiles = 0
    public var aliases = 0
    public var checkedLocalReferences = 0
    public var findings = 0
    public var incompleteInspections = 0
    public var unavailableFiles = 0
    public var conflictingFiles = 0
    public var unverifiedIdentityEntries = 0
    public var unmeasuredEntries = 0

    private struct Group: Hashable {
        let host: String
        let scope: String
    }

    public static func summarize(_ items: [AgentItem]) -> [SkillQualitySummary] {
        let groups = Dictionary(grouping: items.filter { $0.area == .skills }) { item in
            Group(host: SkillContextSummary.host(item),
                  scope: item.agent == "codex-cache" || item.skillFootprint?.scope == "cache" ? "cache" : "directory")
        }
        return groups.keys.sorted { ($0.host, $0.scope) < ($1.host, $1.scope) }.map { group in
            let entries = groups[group]!
            var result = SkillQualitySummary(host: group.host, scope: group.scope)
            result.entries = entries.count
            result.unmeasuredEntries = entries.filter { $0.skillFootprint == nil }.count
            let measured = entries.compactMap(\.skillFootprint)
            let known = measured.filter { $0.canonicalID?.isEmpty == false }
            result.unverifiedIdentityEntries = measured.count - known.count
            let files = Dictionary(grouping: known, by: { $0.canonicalID! })
            result.uniqueFiles = files.count
            for versions in files.values {
                result.aliases += versions.count - 1
                // A file or its reference targets may change between alias observations.
                // Do not choose the first observation and silently hide conflicting evidence.
                guard Set(versions.map(\.contentHash)).count == 1 else { result.conflictingFiles += 1; continue }
                let qualities = versions.compactMap(\.quality)
                guard qualities.count == versions.count,
                      qualities.allSatisfy({ $0.checkedLocalReferences >= 0 && $0.skippedReferences >= 0 }) else {
                    result.unavailableFiles += 1; continue
                }
                let quality = qualities[0]
                guard qualities.allSatisfy({ $0 == quality }) else { result.conflictingFiles += 1; continue }
                result.inspectedFiles += 1
                result.checkedLocalReferences += quality.checkedLocalReferences
                result.findings += quality.issues.count
                if !quality.complete { result.incompleteInspections += 1 }
            }
            return result
        }
    }
}
