import Darwin
import Foundation

/// What a module sends with a request: `{"op": "...", "targets": ["..."], ...}`. `targets` are paths
/// for file capabilities and hosts for the network; other kinds take none.
public struct BrokerRequest: Sendable {
    public var manifest: ModuleManifest
    public var kind: Capability.Kind
    public var operation: String
    /// Checked against the manifest. Paths are absolute with every symbolic link resolved.
    public var targets: [String]
    public var payload: [String: JSONValue]

    public init(manifest: ModuleManifest, kind: Capability.Kind, operation: String, targets: [String], payload: [String: JSONValue]) {
        self.manifest = manifest; self.kind = kind; self.operation = operation; self.targets = targets; self.payload = payload
    }
}

/// What a kernel service answers with, and what it actually did: the targets it acted on, as the
/// access log should name them. `nil` means every target of the request.
public struct BrokerAnswer: Sendable {
    public var data: Data
    public var acted: [String]?
    public init(_ data: Data, acted: [String]? = nil) { self.data = data; self.acted = acted }
}

public struct BrokerError: Error, Equatable, CustomStringConvertible {
    public var outcome: ModuleAccessRecord.Outcome
    public var message: String
    public init(_ outcome: ModuleAccessRecord.Outcome, _ message: String) { self.outcome = outcome; self.message = message }
    public var description: String { "\(outcome.rawValue): \(message)" }
}

/// The only door from a module to the Mac. For every request: is the kind known, does the module's
/// manifest cover every target, does the person agree where that is required, and only then the
/// handler. Each request leaves one line in the module's access log, refused ones included.
public final class CapabilityBroker: @unchecked Sendable {
    public typealias Handler = @Sendable (BrokerRequest) async throws -> BrokerAnswer
    /// A kernel rule that runs after the manifest check and before the person is asked: it refuses
    /// by throwing a `BrokerError`, so nobody is ever asked to confirm what Thermo will not do.
    public typealias Rule = @Sendable (BrokerRequest) async throws -> Void
    /// Shown to the person before a confirmed capability is used; answers whether to go ahead.
    public typealias Confirm = @Sendable (BrokerRequest) async -> Bool

    public static let maxTargets = 10_000

    public let manifest: ModuleManifest
    private let home: String
    private let log: ModuleAccessLog
    private let handlers: [Capability.Kind: Handler]
    private let rules: [Capability.Kind: Rule]
    private let confirm: Confirm

    public init(manifest: ModuleManifest, home: String = NSHomeDirectory(), log: ModuleAccessLog,
                handlers: [Capability.Kind: Handler], rules: [Capability.Kind: Rule] = [:], confirm: @escaping Confirm = { _ in false }) {
        self.manifest = manifest; self.home = home; self.log = log; self.handlers = handlers; self.rules = rules; self.confirm = confirm
    }

    public func request(_ capability: String, payload: Data) async -> Result<Data, BrokerError> {
        // `kind` or `kind:target`; more targets come in the payload.
        let parts = capability.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let kind = Capability.Kind(rawValue: parts[0]) else {
            return refuse(capability, nil, [], .denied, "unknown capability \(parts[0])")
        }
        let body: [String: JSONValue]
        if payload.isEmpty { body = [:] } else {
            guard case let .object(object)? = try? JSONDecoder().decode(JSONValue.self, from: payload) else {
                return refuse(kind.rawValue, nil, [], .denied, "the payload is not a JSON object")
            }
            body = object
        }
        let operation = body["op"]?.string ?? ""
        var named = parts.count == 2 ? [parts[1]] : []
        if case let .array(list)? = body["targets"] {
            for item in list {
                guard let text = item.string else { return refuse(kind.rawValue, operation, named, .denied, "targets must be strings") }
                named.append(text)
            }
        }
        guard named.count <= Self.maxTargets else { return refuse(kind.rawValue, operation, [], .denied, "more than \(Self.maxTargets) targets") }

        var targets: [String] = []
        if kind.takesScope {
            guard !named.isEmpty else { return refuse(kind.rawValue, operation, [], .denied, "\(kind.rawValue) needs a target") }
            for name in named {
                switch check(kind, name) {
                case .success(let target): targets.append(target)
                case .failure(let error): return refuse(kind.rawValue, operation, named, error.outcome, error.message)
                }
            }
        } else {
            guard named.isEmpty else { return refuse(kind.rawValue, operation, named, .denied, "\(kind.rawValue) takes no target") }
            guard manifest.capabilities.contains(where: { $0.kind == kind }) else {
                return refuse(kind.rawValue, operation, [], .denied, "\(manifest.id) did not declare \(kind.rawValue)")
            }
        }

        let request = BrokerRequest(manifest: manifest, kind: kind, operation: operation, targets: targets, payload: body)
        guard let handler = handlers[kind] else {
            return refuse(kind.rawValue, operation, targets, .failed, "\(kind.rawValue) is not available in this version of Thermo")
        }
        if let rule = rules[kind] {
            do { try await rule(request) }
            catch let error as BrokerError { return refuse(kind.rawValue, operation, targets, error.outcome, error.message) }
            catch { return refuse(kind.rawValue, operation, targets, .denied, error.localizedDescription) }
        }
        if kind.alwaysConfirmed, !(await confirm(request)) {
            return refuse(kind.rawValue, operation, targets, .declined, "not confirmed")
        }
        do {
            let answer = try await handler(request)
            log.record(.init(module: manifest.id, capability: kind.rawValue, operation: operation, targets: answer.acted ?? targets, outcome: .allowed))
            return .success(answer.data)
        } catch let error as BrokerError {
            return refuse(kind.rawValue, operation, targets, error.outcome, error.message)
        } catch {
            return refuse(kind.rawValue, operation, targets, .failed, "\(error.localizedDescription)")
        }
    }

    private func refuse(_ capability: String, _ operation: String?, _ targets: [String], _ outcome: ModuleAccessRecord.Outcome,
                        _ message: String) -> Result<Data, BrokerError> {
        log.record(.init(module: manifest.id, capability: capability, operation: operation, targets: targets, outcome: outcome, detail: message))
        return .failure(BrokerError(outcome, message))
    }

    /// The target as the kernel will act on it, or why the manifest does not cover it.
    private func check(_ kind: Capability.Kind, _ name: String) -> Result<String, BrokerError> {
        if kind == .networkConnect {
            let host = name.lowercased()
            guard manifest.capabilities.contains(where: { $0.covers(Capability(kind, scope: host), home: home) }) else {
                return .failure(BrokerError(.denied, "\(manifest.id) did not declare \(kind.rawValue):\(host)"))
            }
            return .success(host)
        }
        guard let plain = Capability.path(name, home: home) else {
            return .failure(BrokerError(.denied, "\(name) must be absolute or start with ~/ and may not contain .."))
        }
        // A link inside a granted folder must not lead out of it. Deleting acts on the entry itself,
        // so only the folder it sits in is resolved; reading follows the link all the way.
        let target: String
        if kind == .filesDelete {
            let url = URL(fileURLWithPath: plain)
            target = Self.resolved(url.deletingLastPathComponent().path) + "/" + url.lastPathComponent
        } else { target = Self.resolved(plain) }
        for declared in manifest.capabilities where declared.kind == kind {
            guard let scope = declared.scope, let root = Capability.path(scope, home: home).map(Self.resolved) else { continue }
            let inside = target.hasPrefix(root == "/" ? "/" : root + "/")
            // The granted folder itself may be read but never deleted.
            if inside || (kind == .filesRead && target == root) { return .success(target) }
        }
        return .failure(BrokerError(.denied, "\(manifest.id) did not declare \(kind.rawValue) for \(target)"))
    }

    /// `path` with symbolic links resolved as far as it exists; the part that does not exist is kept as written.
    public static func resolved(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path), rest: [String] = []
        while existing.path != "/" {
            if let real = realpath(existing.path, nil) {
                defer { free(real) }
                let base = String(cString: real)
                return rest.isEmpty ? base : (base == "/" ? "" : base) + "/" + rest.reversed().joined(separator: "/")
            }
            rest.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
        return rest.isEmpty ? "/" : "/" + rest.reversed().joined(separator: "/")
    }
}

/// JSON as a value, for payloads whose shape depends on the operation.
public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var string: String? { if case let .string(v) = self { return v } else { return nil } }
    public var number: Double? { if case let .number(v) = self { return v } else { return nil } }
    public var bool: Bool? { if case let .bool(v) = self { return v } else { return nil } }
}
