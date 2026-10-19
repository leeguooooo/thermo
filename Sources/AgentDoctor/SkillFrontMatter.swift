import Foundation
@_implementationOnly import Yams
import ThermoL10n

/// Static YAML inspection, not a prediction of any host's loading behavior.
/// Compose representation nodes; never construct arbitrary objects or recursively traverse metadata.
enum SkillFrontMatter {
    struct Parsed {
        var fields: [String: String]?
        var issue: SkillQualityIssue?
    }

    static func parse(_ text: String) -> Parsed {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let first = lines.first?.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{feff}")))
        guard first == "---" else { return Parsed() }
        func invalid(_ code: String, _ message: String) -> Parsed {
            Parsed(issue: SkillQualityIssue(code: code, line: 2, target: nil, message: tr(message)))
        }
        guard let end = lines.dropFirst().firstIndex(where: { $0.hasPrefix("---") && $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return invalid("invalid_front_matter", "Skill YAML front matter is unclosed or invalid; catalog measurement is unavailable. Host loading was not tested.")
        }
        let yaml = lines[1..<end].joined(separator: "\n") + "\n"
        guard yaml.utf8.count <= 65_536 else {
            return invalid("front_matter_limit", "Skill YAML front matter exceeds the 64 KiB inspection limit; catalog measurement is unavailable.")
        }
        do {
            guard let node = try Yams.compose(yaml: yaml, .default, .default, .utf8), let mapping = node.mapping else {
                return invalid("invalid_front_matter", "Skill YAML front matter must be a mapping with string name and description; catalog measurement is unavailable.")
            }
            var keys = Set<String>(), fields: [String: String] = [:]
            for pair in mapping {
                guard case let .scalar(key) = pair.key, pair.key.tag == Tag(.str),
                      keys.insert(key.string).inserted else {
                    return invalid("invalid_front_matter", "Skill YAML front matter has duplicate or unsupported keys; catalog measurement is unavailable.")
                }
                guard ["name", "description"].contains(key.string) else { continue }
                guard case let .scalar(value) = pair.value, pair.value.tag == Tag(.str) else {
                    return invalid("invalid_front_matter", "Skill YAML front matter must be a mapping with string name and description; catalog measurement is unavailable.")
                }
                fields[key.string] = value.string
            }
            return Parsed(fields: fields)
        } catch {
            // Parser diagnostics may contain the source line. Export a fixed explanation only.
            return invalid("invalid_front_matter", "Skill YAML front matter is unclosed or invalid; catalog measurement is unavailable. Host loading was not tested.")
        }
    }
}
