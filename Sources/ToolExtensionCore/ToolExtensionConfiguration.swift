import Foundation

/// Native modules and future out-of-process providers share stable extension
/// IDs. Display names and application branding do not identify saved settings.
public struct ToolExtensionDescriptor: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let summary: String
    public let defaultEnabled: Bool
    public init(id: String, title: String, symbol: String, summary: String, defaultEnabled: Bool = true) {
        self.id = id; self.title = title; self.symbol = symbol; self.summary = summary; self.defaultEnabled = defaultEnabled
    }
}

public struct ToolExtensionPreference: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var showInMenu: Bool
    public var order: Int
    public init(enabled: Bool = true, showInMenu: Bool = true, order: Int = 0) {
        self.enabled = enabled; self.showInMenu = showInMenu; self.order = order
    }
}

public struct ToolExtensionConfiguration: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion: Int
    public var extensions: [String: ToolExtensionPreference]
    public init(extensions: [String: ToolExtensionPreference] = [:]) {
        self.schemaVersion = Self.currentSchema; self.extensions = extensions
    }
    public func preference(for descriptor: ToolExtensionDescriptor) -> ToolExtensionPreference {
        extensions[descriptor.id] ?? ToolExtensionPreference(enabled: descriptor.defaultEnabled)
    }
    public func ordered(_ descriptors: [ToolExtensionDescriptor], menuOnly: Bool = false) -> [ToolExtensionDescriptor] {
        descriptors.filter { descriptor in
            let p = preference(for: descriptor)
            return !menuOnly || (p.enabled && p.showInMenu)
        }.sorted {
            let lhs = preference(for: $0).order, rhs = preference(for: $1).order
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }
    public func validate() throws {
        guard schemaVersion == Self.currentSchema else { throw ToolExtensionConfigurationError.unsupportedSchema(schemaVersion) }
        guard extensions.count <= 256, extensions.keys.allSatisfy(Self.validID) else {
            throw ToolExtensionConfigurationError.invalidConfiguration
        }
    }
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 160 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}

public enum ToolExtensionConfigurationError: Error, LocalizedError {
    case unsupportedSchema(Int), invalidConfiguration, tooLarge
    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version): return "Unsupported extension settings version: \(version)"
        case .invalidConfiguration: return "Invalid extension settings. The original file has been preserved."
        case .tooLarge: return "Extension settings exceed 64 KiB."
        }
    }
}

/// Loading never changes an extension's lifecycle or executes code. Unknown IDs
/// survive edits so temporarily removed providers retain their configuration.
public struct ToolExtensionConfigurationStore {
    public let url: URL
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thermo/Extensions/settings.json")
    }
    public init(url: URL = Self.defaultURL) { self.url = url }
    public func read() throws -> ToolExtensionConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return ToolExtensionConfiguration() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw ToolExtensionConfigurationError.tooLarge }
        let configuration = try JSONDecoder().decode(ToolExtensionConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }
    public func write(_ configuration: ToolExtensionConfiguration) throws {
        try configuration.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        guard data.count <= 65_536 else { throw ToolExtensionConfigurationError.tooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
