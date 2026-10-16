import Foundation
import Darwin
@_implementationOnly import Markdown
import ThermoL10n

public struct SkillQualityIssue: Codable, Equatable, Sendable {
    public var code: String
    public var line: Int
    public var target: String?
    public var message: String
}

extension ConfigChecks {
    mutating func checkIdenticalSkillContent() {
        let candidates = items.indices.filter { items[$0].area == .skills && items[$0].skillFootprint != nil && items[$0].skillFootprint?.scope != "cache" }
        let groups = Dictionary(grouping: candidates) { index in
            let host = ["shared", "codex"].contains(items[index].agent) ? "codex" : items[index].agent == "plugin" ? "claude" : items[index].agent
            return host + "|" + items[index].skillFootprint!.contentHash
        }
        for key in groups.keys.sorted() {
            let indices = groups[key]!
            let files = Set(indices.compactMap { items[$0].skillFootprint?.canonicalID })
            guard files.count > 1 else { continue }
            var seen = Set<String>()
            let sources = indices.sorted().compactMap { index -> String? in
                guard let footprint = items[index].skillFootprint, let identity = footprint.canonicalID,
                      seen.insert(identity).inserted else { return nil }
                return footprint.sourcePath
            }
            for index in indices {
                items[index].skillFootprint?.identicalContentFiles = files.count
                currentItem = items[index].id
                add(Finding(.info, .skills, agent: items[index].agent, subject: items[index].name,
                            tr("Identical SKILL.md content exists in %1$@ independent files. This may be intentional; no copy was selected for removal.", String(files.count)),
                            fix: tr("Compare the sources: %1$@", sources.prefix(5).joined(separator: ", ")),
                            source: items[index].skillFootprint?.sourcePath))
            }
        }
        currentItem = nil
    }
}

public struct SkillQualityReport: Codable, Equatable, Sendable {
    public var checkedLocalReferences = 0
    public var skippedReferences = 0
    public var complete = true
    public var parser: String? = "swift-markdown-0.9.0"
    public var issues: [SkillQualityIssue] = []
}

/// Markdown syntax comes from swift-markdown/cmark-gfm. Only static local
/// destinations are statted: no scripts, remote URLs or referenced contents run.
enum SkillQuality {
    static let scheme = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9+.-]*:"#)

    static func inspect(_ text: String, at file: URL, cancelled: () -> Bool = { false }) -> SkillQualityReport {
        var report = SkillQualityReport()
        guard !cancelled() else { report.complete = false; return report }
        let body = ConfigChecks.skillBody(text)
        let base = text.components(separatedBy: "\n").count - body.components(separatedBy: "\n").count
        let document = Document(parsing: body)
        var seen = Set<String>()
        var references = 0
        var nodes = 0
        var hasBody = false
        func check(_ target: String, line: Int) {
            guard references < 512, !cancelled() else { report.complete = false; return }
            references += 1
            let value = target.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value.hasPrefix("#") || scheme.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
                report.skippedReferences += 1; return
            }
            let withoutFragment = String(value.prefix { $0 != "#" && $0 != "?" })
            guard let path = withoutFragment.removingPercentEncoding, !path.isEmpty,
                  !path.hasPrefix("/"), !path.hasPrefix("~"),
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !path.contains(where: { "$<>*{}[]".contains($0) || $0.isNewline || $0.asciiValue == 0 }),
                  path.hasPrefix("./") || path.hasPrefix("../") || path.contains(".") || path.hasSuffix("/") else { report.skippedReferences += 1; return }
            let url = file.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
            guard seen.insert(url.path).inserted else { return }
            var info = stat()
            if stat(url.path, &info) == 0 { report.checkedLocalReferences += 1; return }
            if errno == ENOENT || errno == ENOTDIR {
                report.checkedLocalReferences += 1
                let safe = String(Redact.text(path).prefix(300))
                report.issues.append(SkillQualityIssue(code: "missing_local_reference", line: line, target: safe,
                                                       message: tr("Local Markdown target does not exist now: %1$@. Check whether it should be packaged or generated during use.", safe)))
            } else { report.skippedReferences += 1; report.complete = false }
        }
        func visibleHTML(_ html: String) -> Bool {
            var remaining = html[...]
            while let start = remaining.range(of: "<!--") {
                if !remaining[..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                guard let end = remaining.range(of: "-->", range: start.upperBound..<remaining.endIndex) else { return false }
                remaining = remaining[end.upperBound...]
            }
            return !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var stack: [any Markup] = [document]
        while let node = stack.popLast() {
            guard !cancelled(), nodes < 100_000 else { report.complete = false; break }
            nodes += 1
            let line = base + (node.range?.lowerBound.line ?? 1)
            if let link = node as? Markdown.Link, let target = link.destination { check(target, line: line) }
            if let image = node as? Markdown.Image, let target = image.source { hasBody = true; check(target, line: line) }
            if let text = node as? Markdown.Text, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasBody = true }
            if let code = node as? CodeBlock, !code.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasBody = true }
            if let code = node as? InlineCode, !code.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasBody = true }
            if let html = node as? HTMLBlock, visibleHTML(html.rawHTML) { hasBody = true }
            if let html = node as? InlineHTML, visibleHTML(html.rawHTML) { hasBody = true }
            stack.append(contentsOf: node.children.reversed())
        }
        if !hasBody && report.complete {
            report.issues.append(SkillQualityIssue(code: "empty_body", line: base + 1, target: nil, message: tr("SKILL.md has no instruction body after front matter and comments.")))
        }
        return report
    }
}
