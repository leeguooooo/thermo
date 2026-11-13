import Foundation

/// One thing a module may ask the kernel to do for it. Modules run sandboxed and hold no system
/// grants of their own, so everything outside their container goes through one of these.
/// Written as `kind` or `kind:scope` in a manifest, e.g. `files.read:~/Library/Caches`.
public struct Capability: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: String, CaseIterable, Sendable {
        case sensorsRead = "sensors.read"
        case processesRead = "processes.read"
        case processesEnd = "processes.end"
        case screenCapture = "screen.capture"
        case accessibilityRead = "accessibility.read"
        case filesRead = "files.read"
        case filesDelete = "files.delete"
        case networkConnect = "network.connect"
        case notificationsPost = "notifications.post"
        case fansControl = "fans.control"

        /// A path prefix for files, a host for the network.
        public var takesScope: Bool { self == .filesRead || self == .filesDelete || self == .networkConnect }
        /// The kernel asks the person each time, whatever the manifest says.
        public var alwaysConfirmed: Bool { self == .processesEnd || self == .filesDelete || self == .fansControl }
    }

    public var kind: Kind
    public var scope: String?

    public init(_ kind: Kind, scope: String? = nil) { self.kind = kind; self.scope = scope }

    public init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let kind = Kind(rawValue: parts[0]) else { return nil }
        if parts.count == 2, parts[1].isEmpty { return nil }
        self.init(kind, scope: parts.count == 2 ? parts[1] : nil)
    }

    public var description: String { scope.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = Capability(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown capability \(text)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Whether a manifest that declares `self` may make `request`. `home` expands a leading `~`.
    public func covers(_ request: Capability, home: String) -> Bool {
        guard kind == request.kind else { return false }
        guard kind.takesScope else { return scope == nil && request.scope == nil }
        guard let granted = scope, let wanted = request.scope else { return false }
        if kind == .networkConnect { return Self.host(granted, covers: wanted) }
        guard let root = Self.path(granted, home: home), let target = Self.path(wanted, home: home) else { return false }
        return target == root || target.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// An absolute path with `~` expanded and `.` removed; nil when it is relative or climbs with `..`.
    static func path(_ text: String, home: String) -> String? {
        var expanded = text
        if text == "~" { expanded = home } else if text.hasPrefix("~/") { expanded = home + String(text.dropFirst(1)) }
        guard expanded.hasPrefix("/") else { return nil }
        let parts = expanded.split(separator: "/").filter { $0 != "." }
        guard !parts.contains("..") else { return nil }
        return "/" + parts.joined(separator: "/")
    }

    /// `api.example.com` matches itself; `*.example.com` matches any subdomain but not `example.com`.
    static func host(_ pattern: String, covers host: String) -> Bool {
        let pattern = pattern.lowercased(), host = host.lowercased()
        guard !host.isEmpty, !host.contains("/"), !host.contains("*") else { return false }
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(1))
            return suffix.count > 1 && host.hasSuffix(suffix) && host.count > suffix.count
        }
        return pattern == host
    }
}

public enum CapabilityDecision: Equatable, Sendable {
    case allowed
    /// Declared, but the kernel must show what will happen and get a yes first.
    case needsConfirmation
    case denied(String)
}

public enum CapabilityPolicy {
    /// The kernel's answer to one request from a module. Anything the manifest did not declare is
    /// denied; nothing here can widen what the manifest says.
    public static func decide(_ request: Capability, for manifest: ModuleManifest, home: String) -> CapabilityDecision {
        if request.kind.takesScope, request.scope == nil { return .denied("\(request.kind.rawValue) needs a scope") }
        if !request.kind.takesScope, request.scope != nil { return .denied("\(request.kind.rawValue) takes no scope") }
        guard manifest.capabilities.contains(where: { $0.covers(request, home: home) }) else {
            return .denied("\(manifest.id) did not declare \(request)")
        }
        return request.kind.alwaysConfirmed ? .needsConfirmation : .allowed
    }
}
