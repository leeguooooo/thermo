import Foundation

/// Command arguments stay typed across CLI and MCP. An array is allowed only for a repeating parameter.
public enum ModuleArgument: Codable, Sendable, Equatable {
    case string(String), integer(Int64), boolean(Bool), array([ModuleArgument])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? c.decode(Int64.self) { self = .integer(value) }
        else if let value = try? c.decode([ModuleArgument].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected a string, integer, boolean or array.") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .integer(let value): try c.encode(value)
        case .boolean(let value): try c.encode(value)
        case .array(let values): try c.encode(values)
        }
    }
    func matches(_ kind: ModuleManifest.Command.Parameter.Kind) -> Bool {
        switch (self, kind) {
        case (.string, .string), (.string, .path), (.integer, .integer), (.boolean, .boolean): return true
        default: return false
        }
    }
}

/// One projection of validated manifests, used for CLI discovery and MCP tools. Disabled commands
/// are absent; a caller must resolve again at execution time rather than trust a cached tool list.
public struct ModuleCommandCatalog: Sendable {
    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }
    public struct Entry: Sendable, Equatable {
        public let moduleID: String
        public let command: ModuleManifest.Command
        public var cliPath: [String] { command.cliPath(moduleID: moduleID) }
        public var toolName: String { moduleID + "." + command.id }

        public func validate(_ arguments: [String: ModuleArgument]) throws {
            try validate(arguments, parameters: command.parameters)
        }
        func validate(_ arguments: [String: ModuleArgument], parameters: [ModuleManifest.Command.Parameter]) throws {
            let names = Set(parameters.map(\.name))
            let unknown = Set(arguments.keys).subtracting(names).sorted()
            guard unknown.isEmpty else { throw Invalid("Unexpected arguments: " + unknown.joined(separator: ", ")) }
            for p in parameters {
                guard let value = arguments[p.name] else {
                    if p.required { throw Invalid("Missing argument: " + p.name) }
                    continue
                }
                if p.repeats == true {
                    guard case .array(let values) = value, values.allSatisfy({ $0.matches(p.kind) }), !p.required || !values.isEmpty else {
                        throw Invalid("Argument \(p.name) requires \(p.required ? "a nonempty" : "an") array of \(p.kind.rawValue).")
                    }
                } else if !value.matches(p.kind) { throw Invalid("Argument \(p.name) requires \(p.kind.rawValue).") }
            }
        }

        public var tool: Tool {
            let properties = Dictionary(uniqueKeysWithValues: command.parameters.map { p in
                let scalar = p.kind == .path ? "string" : p.kind.rawValue
                return (p.name, Tool.Property(type: p.repeats == true ? "array" : scalar, description: p.summary,
                    items: p.repeats == true ? .init(type: scalar) : nil,
                    minItems: p.repeats == true && p.required ? 1 : nil))
            })
            return Tool(name: toolName, title: command.title, description: command.summary,
                inputSchema: .init(properties: properties, required: command.parameters.filter(\.required).map(\.name)),
                annotations: .init(readOnlyHint: !command.mutates, destructiveHint: command.mutates))
        }
    }

    public struct Tool: Encodable, Sendable, Equatable {
        public struct Scalar: Encodable, Sendable, Equatable { public let type: String }
        public struct Property: Encodable, Sendable, Equatable {
            public let type: String
            public let description: String
            public let items: Scalar?
            public let minItems: Int?
        }
        public struct InputSchema: Encodable, Sendable, Equatable {
            public let type = "object"
            public let properties: [String: Property]
            public let required: [String]
            public let additionalProperties = false
        }
        public struct Annotations: Encodable, Sendable, Equatable {
            public let readOnlyHint: Bool
            public let destructiveHint: Bool
        }
        public let name: String
        public let title: String
        public let description: String
        public let inputSchema: InputSchema
        public let annotations: Annotations
    }

    public let entries: [Entry]
    public init(_ manifests: [ModuleManifest], reservedRoots: Set<String> = HostCommandSpecification.roots, enabled: (ModuleManifest) -> Bool) throws {
        var paths = Set<[String]>(), tools = Set<String>(), built: [Entry] = []
        var rootOwners: [String:String] = [:]
        for manifest in manifests.sorted(by: { $0.id < $1.id }) {
            let problems = manifest.problems()
            guard problems.isEmpty else { throw Invalid(problems.joined(separator: "; ")) }
            let isEnabled = enabled(manifest)
            for command in manifest.commands {
                let entry = Entry(moduleID: manifest.id, command: command)
                guard paths.insert(entry.cliPath).inserted else { throw Invalid("CLI path \(entry.cliPath.joined(separator: " ")) is used by more than one module.") }
                if let root = entry.cliPath.first {
                    if reservedRoots.contains(root) { throw Invalid("CLI prefix \(root) is reserved by the kernel.") }
                    if let owner = rootOwners[root], owner != manifest.id { throw Invalid("CLI prefix \(root) is used by more than one module.") }
                    rootOwners[root] = manifest.id
                }
                guard entry.toolName.utf8.count <= 128, tools.insert(entry.toolName).inserted else { throw Invalid("MCP tool name is too long or repeated: \(entry.toolName)") }
                if isEnabled { built.append(entry) }
            }
        }
        entries = built
    }
    public func tool(named name: String) -> Entry? { entries.first { $0.toolName == name } }
    public func command(matching words: [String]) -> Entry? {
        entries.filter { Array(words.prefix($0.cliPath.count)) == $0.cliPath }.max { $0.cliPath.count < $1.cliPath.count }
    }
}
