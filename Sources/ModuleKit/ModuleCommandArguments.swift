import Foundation

extension ModuleCommandCatalog.Entry {
    /// Parse a command after its CLI path. Host controls (for example --json) are explicit inputs,
    /// so a command argument can never be mistaken for an execution or approval flag.
    public func parseCLI(_ words: [String], controls: [ModuleManifest.Command.Parameter] = [], aliases: [String:String] = [:]) throws -> [String: ModuleArgument] {
        let parameters = command.parameters + controls
        guard Set(parameters.map(\.name)).count == parameters.count else { throw ModuleCommandCatalog.Invalid("Command parameters conflict with CLI controls.") }
        let byName = Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0) })
        var result: [String: ModuleArgument] = [:], position = 0, options = true, i = 0
        func scalar(_ raw: String, _ parameter: ModuleManifest.Command.Parameter) throws -> ModuleArgument {
            switch parameter.kind {
            case .string, .path: return .string(raw)
            case .integer:
                guard let n = Int64(raw) else { throw ModuleCommandCatalog.Invalid("--\(parameter.name) expects an integer.") }
                return .integer(n)
            case .boolean:
                guard raw == "true" || raw == "false" else { throw ModuleCommandCatalog.Invalid("--\(parameter.name) expects true or false.") }
                return .boolean(raw == "true")
            }
        }
        func add(_ value: ModuleArgument, _ parameter: ModuleManifest.Command.Parameter) throws {
            if parameter.repeats == true {
                let previous: [ModuleArgument]
                if case .array(let values) = result[parameter.name] { previous = values } else { previous = [] }
                result[parameter.name] = .array(previous + [value])
            } else {
                guard result[parameter.name] == nil else { throw ModuleCommandCatalog.Invalid("--\(parameter.name) may be supplied only once.") }
                result[parameter.name] = value
            }
        }
        while i < words.count {
            let word = words[i]; i += 1
            if options && word == "--" { options = false; continue }
            if options && word.hasPrefix("-"), word.count > 1, Double(word) == nil {
                let option = word.hasPrefix("--") ? String(word.dropFirst(2)) : String(word.dropFirst())
                let parts = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let rawName = parts.first.map(String.init) ?? ""
                let name = word.hasPrefix("--") ? rawName : (aliases[rawName] ?? rawName)
                guard let parameter = byName[name] else { throw ModuleCommandCatalog.Invalid("Unknown option: \(word)") }
                let raw: String
                if parts.count == 2 { raw = String(parts[1]) }
                else if parameter.kind == .boolean {
                    if i < words.count && ["true", "false"].contains(words[i]) { raw = words[i]; i += 1 } else { raw = "true" }
                } else {
                    guard i < words.count else { throw ModuleCommandCatalog.Invalid("--\(name) needs a value.") }
                    raw = words[i]; i += 1
                }
                try add(scalar(raw, parameter), parameter)
            } else {
                while position < command.parameters.count && command.parameters[position].repeats != true && result[command.parameters[position].name] != nil { position += 1 }
                guard position < command.parameters.count else { throw ModuleCommandCatalog.Invalid("Unexpected argument: \(word)") }
                let parameter = command.parameters[position]
                try add(scalar(word, parameter), parameter)
                if parameter.repeats != true { position += 1 }
            }
        }
        // The same validator backs MCP input and CLI input, including required nonempty arrays.
        try validate(result, parameters: parameters)
        return result
    }

    public var cliUsage: String {
        cliPath.joined(separator: " ") + command.parameters.map { p in
            let value = p.kind == .boolean && p.repeats != true ? "" : " " + (p.kind == .path ? "PATH" : p.kind.rawValue.uppercased())
            let option = "--" + p.name + value
            if p.repeats == true { return p.required ? " " + option + " [" + option + "]…" : " [" + option + "]…" }
            return p.required ? " " + option : " [" + option + "]"
        }.joined()
    }
}
