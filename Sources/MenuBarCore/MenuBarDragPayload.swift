import Foundation

/// Only app identities cross the drag boundary. Drops cannot import settings,
/// reveal groups, run commands or assign system/protected items.
public struct MenuBarDragPayload: Codable, Equatable, Sendable {
    public static let typeIdentifier = "dev.thermo.menubar-app"
    public let version: Int
    public let bundle: String
    public init(bundle: String) { version = 1; self.bundle = bundle }

    public enum ValidationError: Error { case invalidPayload }
    public static func read(_ data: Data, knownBundles: Set<String>, ownBundle: String) throws -> MenuBarDragPayload {
        guard data.count <= 1_024 else { throw ValidationError.invalidPayload }
        let payload = try JSONDecoder().decode(Self.self, from: data)
        guard payload.version == 1, payload.bundle != ownBundle,
              MenuBarSections.isAssignable(payload.bundle), knownBundles.contains(payload.bundle) else {
            throw ValidationError.invalidPayload
        }
        return payload
    }
}
