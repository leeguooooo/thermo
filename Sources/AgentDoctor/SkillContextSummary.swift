import Foundation

/// Inventory totals, not effective prompt tokens. Cache versions have separate totals.
public struct SkillContextSummary: Codable, Equatable, Sendable {
    public var host: String
    public var referenceEncoding: String? = nil
    public var referenceCatalogTokens: Int? = nil
    public var referenceDocumentTokens: Int? = nil
    public var unavailableReferenceFiles: Int? = nil
    public var entries = 0
    public var measuredEntries = 0
    public var uniqueFiles = 0
    public var aliases = 0
    public var catalogEntries = 0
    public var catalogEstimatedTokens: Int? = 0
    public var documentBytes = 0
    public var documentEstimatedTokens = 0
    public var cacheEntries = 0
    public var cacheUniqueFiles = 0
    public var cacheDocumentBytes = 0
    public var unverifiedIdentityEntries = 0
    public var inconsistentFiles = 0

    static func host(_ item: AgentItem) -> String {
        switch item.agent {
        case "shared", "codex", "codex-cache": return "codex"
        case "plugin", "claude": return "claude"
        default: return item.agent
        }
    }

    public static func summarize(_ items: [AgentItem]) -> [SkillContextSummary] {
        let groups = Dictionary(grouping: items.filter { $0.area == .skills }, by: host)
        return groups.keys.sorted().map { name in
            let entries = groups[name]!.sorted { $0.id < $1.id }
            var summary = SkillContextSummary(host: name)
            summary.entries = entries.count
            summary.measuredEntries = entries.filter { $0.skillFootprint != nil }.count
            summary.cacheEntries = entries.filter { $0.agent == "codex-cache" || $0.skillFootprint?.scope == "cache" }.count
            let measured = entries.compactMap { $0.skillFootprint }
            summary.unverifiedIdentityEntries = measured.filter { $0.canonicalID == nil }.count
            let known = measured.filter { $0.canonicalID != nil }
            let requested = Set(known.compactMap { $0.document.referenceEncoding })
            if requested.count == 1 { summary.referenceEncoding = requested.first; summary.referenceCatalogTokens = 0; summary.referenceDocumentTokens = 0; summary.unavailableReferenceFiles = 0 }
            let files = Dictionary(grouping: known.filter { $0.scope != "cache" }, by: { $0.canonicalID! })
            var catalogs = Set<String>()
            for (id, versions) in files {
                guard Set(versions.map(\.contentHash)).count == 1 else { summary.inconsistentFiles += 1; continue }
                summary.uniqueFiles += 1
                summary.aliases += versions.count - 1
                summary.documentBytes += versions[0].document.bytes
                summary.documentEstimatedTokens += versions[0].document.estimatedTokens
                if summary.referenceEncoding != nil {
                    if let sum = summary.referenceDocumentTokens, let count = versions[0].document.referenceTokens { summary.referenceDocumentTokens = sum + count }
                    else { summary.referenceDocumentTokens = nil }
                    if versions.contains(where: { $0.document.referenceTokens == nil || $0.catalog.referenceTokens == nil }) { summary.unavailableReferenceFiles = (summary.unavailableReferenceFiles ?? 0) + 1 }
                }
                for version in versions {
                    if catalogs.insert(id + "|" + (version.namespace ?? "")).inserted {
                        summary.catalogEntries += 1
                        if version.catalog.measurementComplete == false { summary.catalogEstimatedTokens = nil }
                        else if let total = summary.catalogEstimatedTokens { summary.catalogEstimatedTokens = total + version.catalog.estimatedTokens }
                        if summary.referenceEncoding != nil {
                            if version.catalog.measurementComplete != false, let sum = summary.referenceCatalogTokens, let count = version.catalog.referenceTokens { summary.referenceCatalogTokens = sum + count }
                            else { summary.referenceCatalogTokens = nil }
                        }
                    }
                }
            }
            let cache = Dictionary(grouping: known.filter { $0.scope == "cache" }, by: { $0.canonicalID! })
            for versions in cache.values {
                guard Set(versions.map(\.contentHash)).count == 1 else { summary.inconsistentFiles += 1; continue }
                summary.cacheUniqueFiles += 1
                summary.cacheDocumentBytes += versions[0].document.bytes
            }
            return summary
        }
    }
}
