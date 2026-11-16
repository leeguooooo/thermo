import Foundation

/// The registry listing: which modules exist, their latest version and where the package is.
/// Untrusted. It only decides what is shown; installing re-checks everything from the signed package.
public struct ModuleRegistry: Codable, Equatable, Sendable {
    public static let format = "dev.thermo.module-registry"
    public static let maxBytes = 1 << 20

    public struct Listing: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var version: String
        public var name: String
        public var summary: String
        public var symbol: String?
        /// As declared in the package's manifest; shown before download, checked again after.
        public var capabilities: [Capability]
        public var size: Int
        /// SHA-256 of the package file.
        public var sha256: String
        public var url: URL
        public init(id: String, version: String, name: String, summary: String, symbol: String? = nil, capabilities: [Capability],
                    size: Int, sha256: String, url: URL) {
            self.id = id; self.version = version; self.name = name; self.summary = summary; self.symbol = symbol
            self.capabilities = capabilities; self.size = size; self.sha256 = sha256; self.url = url
        }
    }
    public var format: String
    public var modules: [Listing]
    public init(modules: [Listing]) { format = Self.format; self.modules = modules }

    /// Entries that can't be installed safely are dropped rather than shown.
    public static func decode(_ data: Data) -> ModuleRegistry? {
        guard data.count <= maxBytes, var registry = try? JSONDecoder().decode(ModuleRegistry.self, from: data),
              registry.format == format else { return nil }
        var seen = Set<String>()
        registry.modules = registry.modules.filter { listing in
            guard seen.insert(listing.id).inserted, listing.url.scheme?.lowercased() == "https",
                  listing.size > 0, listing.size <= ModulePackage.maxPackageBytes, listing.sha256.count == 64,
                  ModuleVersion.parts(listing.version) != nil, !listing.id.hasPrefix("dev.thermo.") else { return false }
            return true
        }
        return registry
    }
}

/// Installed packages under `<root>/<module id>/`: the verified package file and its hash.
/// Every change goes through here: install and update write a new copy and swap it in, so a failed
/// update leaves the old version in place.
public struct ModuleMarketStore: Sendable {
    public let root: URL
    public let keys: [String: Data]
    public init(root: URL, keys: [String: Data]) { self.root = root; self.keys = keys }
    public static func defaultRoot(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Thermo/Modules", isDirectory: true)
    }

    public struct Installed: Equatable, Sendable, Identifiable {
        public var manifest: ModuleManifest
        public var sha256: String
        public var folder: URL
        public var id: String { manifest.id }
        public var packageURL: URL { folder.appendingPathComponent("package.thermomodule") }
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case hashMismatch, listingMismatch(String), notNewer, notInstalled, package(ModulePackage.Problem)
        public var description: String {
            switch self {
            case .hashMismatch: return "the download does not match the registry's hash"
            case .listingMismatch(let what): return "the package's \(what) differs from the listing"
            case .notNewer: return "the package is not newer than the installed version"
            case .notInstalled: return "not installed"
            case .package(let problem): return problem.description
            }
        }
    }

    /// Re-verifies every installed package; a copy that no longer verifies (key removed, file changed) is left out.
    public func installed() -> [Installed] {
        let folders = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("package.thermomodule")),
                  let package = try? ModulePackage.decode(data), let manifest = try? package.verify(keys: keys),
                  manifest.id == folder.lastPathComponent else { return nil }
            return Installed(manifest: manifest, sha256: ModulePackage.fileHash(data), folder: folder)
        }
    }

    /// Checks a downloaded package against its listing and the signing keys without writing anything.
    public func review(_ data: Data, listing: ModuleRegistry.Listing) throws -> ModuleManifest {
        guard ModulePackage.fileHash(data) == listing.sha256.lowercased() else { throw Failure.hashMismatch }
        let manifest: ModuleManifest
        do { manifest = try ModulePackage.decode(data).verify(keys: keys) } catch let problem as ModulePackage.Problem { throw Failure.package(problem) }
        guard manifest.id == listing.id else { throw Failure.listingMismatch("id") }
        guard manifest.version == listing.version else { throw Failure.listingMismatch("version") }
        // What the person agreed to must be what the module gets.
        guard Set(manifest.capabilities) == Set(listing.capabilities) else { throw Failure.listingMismatch("declared access") }
        return manifest
    }

    /// Installs, or updates to a newer version. Downgrades and same-version reinstalls are refused.
    @discardableResult
    public func install(_ data: Data, listing: ModuleRegistry.Listing) throws -> Installed {
        let manifest = try review(data, listing: listing)
        let folder = root.appendingPathComponent(manifest.id, isDirectory: true)
        if let current = installed().first(where: { $0.id == manifest.id }), !ModuleVersion.isNewer(manifest.version, than: current.manifest.version) {
            throw Failure.notNewer
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        try data.write(to: staging.appendingPathComponent("package.thermomodule"), options: .atomic)
        if fm.fileExists(atPath: folder.path) {
            _ = try fm.replaceItemAt(folder, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: folder)
        }
        return Installed(manifest: manifest, sha256: listing.sha256.lowercased(), folder: folder)
    }

    /// Hands the module's folder to `remove` (the app moves it to the Trash with an undo record).
    public func uninstall(_ id: String, remove: (URL) throws -> Void) throws {
        guard let current = installed().first(where: { $0.id == id }) else { throw Failure.notInstalled }
        try remove(current.folder)
    }

    /// Listings newer than what is installed.
    public func updates(_ registry: ModuleRegistry) -> [ModuleRegistry.Listing] {
        let have = Dictionary(uniqueKeysWithValues: installed().map { ($0.id, $0.manifest.version) })
        return registry.modules.filter { listing in have[listing.id].map { ModuleVersion.isNewer(listing.version, than: $0) } ?? false }
    }
}
