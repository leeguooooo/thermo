import Foundation

/// Persist app identities, never PIDs or window IDs. On macOS 27 every item
/// owned by one application shares its section.
public enum MenuBarSection: String, Codable, CaseIterable, Sendable {
    case visible, hidden, alwaysHidden
}

public enum MenuBarReveal: Equatable, Sendable {
    case collapsed, hidden, all
}

public struct MenuBarSections: Equatable, Codable, Sendable {
    public private(set) var assignments: [String: MenuBarSection]
    public init(assignments: [String: MenuBarSection] = [:]) {
        self.assignments = assignments.filter { Self.isAssignable($0.key) && $0.value != .visible }
    }

    /// System extras are not individually controllable through the bundle API.
    /// Keep Thermo and its isolated QA builds accessible as recovery entry points.
    public static func isAssignable(_ bundle: String) -> Bool {
        let parts = bundle.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty } &&
            !bundle.contains(where: { $0.isWhitespace || $0.isNewline }) &&
            !bundle.hasPrefix("com.apple.") && bundle != "dev.thermo" &&
            !bundle.hasPrefix("dev.thermo.")
    }

    public subscript(bundle: String) -> MenuBarSection {
        guard Self.isAssignable(bundle) else { return .visible }
        return assignments[bundle] ?? .visible
    }

    public mutating func assign(_ bundle: String, to section: MenuBarSection) {
        guard Self.isAssignable(bundle) else { return }
        assignments[bundle] = section == .visible ? nil : section
    }

    public func hiddenBundles(reveal: MenuBarReveal) -> Set<String> {
        Set(assignments.compactMap { bundle, section in
            guard Self.isAssignable(bundle) else { return nil }
            switch (reveal, section) {
            case (.all, _), (_, .visible), (.hidden, .hidden): return nil
            default: return bundle
            }
        })
    }

    public func configuration(running: Set<String>, ownBundle: String, reveal: MenuBarReveal) -> MenuBarConfiguration? {
        let hidden = hiddenBundles(reveal: reveal).subtracting([ownBundle])
        // An absent app must not activate assessment mode and its system effects.
        guard !hidden.isDisjoint(with: running) else { return nil }
        return MenuBarConfiguration(allowedBundles: running.union([ownBundle]).subtracting(hidden).sorted())
    }

    private enum CodingKeys: String, CodingKey { case assignments }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(assignments: try container.decode([String: MenuBarSection].self, forKey: .assignments))
    }
}

public struct MenuBarConfiguration: Equatable, Sendable {
    public let allowedBundles: [String]
    public init(allowedBundles: [String]) { self.allowedBundles = Array(Set(allowedBundles)).sorted() }
}

/// A single versioned value avoids half-written section assignments. A malformed
/// value is reported to callers, so they can preserve it and start fully visible.
public struct MenuBarSectionStore {
    public enum ReadError: Error { case invalidStorageType }
    public static let key = "menuBarSections.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func read() throws -> MenuBarSections {
        guard let value = defaults.object(forKey: Self.key) else { return MenuBarSections() }
        guard let data = value as? Data else { throw ReadError.invalidStorageType }
        return try JSONDecoder().decode(MenuBarSections.self, from: data)
    }
    public func write(_ sections: MenuBarSections) throws {
        defaults.set(try JSONEncoder().encode(sections), forKey: Self.key)
    }
}
