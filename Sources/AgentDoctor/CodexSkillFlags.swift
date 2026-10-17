import Foundation

extension ConfigChecks {
    /// Conservative subset: absolute, single-line paths in [[skills.config]].
    /// Unsupported/contradictory syntax never disables an inventory entry by guesswork.
    static func codexSkillFlags(_ text: String) -> (paths: [String: Bool], incomplete: Bool) {
        var flags: [String: Bool] = [:]
        var active = false, incomplete = false
        var section = "", path: String?, enabled: Bool?
        func uncomment(_ line: String) -> String {
            var quote: Character?, escaped = false, result = ""
            for c in line {
                if escaped { result.append(c); escaped = false; continue }
                if quote == "\"", c == "\\" { result.append(c); escaped = true; continue }
                if let q = quote { if c == q { quote = nil } }
                else if c == "\"" || c == "'" { quote = c }
                else if c == "#" { break }
                result.append(c)
            }
            return result.trimmingCharacters(in: .whitespaces)
        }
        func flush() {
            guard active else { return }
            guard let path, path.hasPrefix("/"), let enabled else { incomplete = true; return }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            if let previous = flags[url.path], previous != enabled { incomplete = true }
            flags[url.path] = enabled
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = uncomment(raw)
            if line.hasPrefix("[") {
                flush(); path = nil; enabled = nil
                active = line == "[[skills.config]]"
                section = line
                let normalized = line.filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
                if (normalized == "[[skills.config]]" || normalized == "[skills.config]"), !active { incomplete = true }
                continue
            }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if (section == "[skills]" && key == "config") || (section.isEmpty && (key == "skills.config" || key == "skills")) { incomplete = true }
            guard active else { continue }
            if key == "path" {
                if path != nil { incomplete = true }
                if value.first == "\"", let data = value.data(using: .utf8) {
                    var escaped = false
                    for character in value.dropFirst().dropLast() {
                        if escaped {
                            if !"\"\\btnfru".contains(character) { incomplete = true }
                            escaped = false
                        } else if character == "\\" { escaped = true }
                    }
                    path = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
                } else if value.count >= 2, value.first == "'", value.last == "'", !value.dropFirst().dropLast().contains("'") {
                    path = String(value.dropFirst().dropLast())
                }
                if path == nil { incomplete = true }
            } else if key == "enabled" {
                if enabled != nil { incomplete = true }
                if value == "true" { enabled = true }
                else if value == "false" { enabled = false }
                else { incomplete = true }
            }
        }
        flush()
        if !flags.isEmpty && (text.contains("\"\"\"") || text.contains("'''")) { incomplete = true }
        return (incomplete ? [:] : flags, incomplete)
    }
}
