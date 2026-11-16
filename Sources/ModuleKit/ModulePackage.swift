import CryptoKit
import Foundation

/// A third-party WebAssembly module as it travels: one `.thermomodule` file holding the manifest,
/// the module code and a signature from Thermo's module pipeline.
///
/// The signature covers a content digest of the exact manifest and wasm bytes, so changing either
/// one, or pairing a manifest with another module's code, fails verification. Thermo installs only
/// packages that verify against a key built into the app; the registry index is just a listing and
/// is never trusted for what a module may do.
public struct ModulePackage: Equatable, Sendable {
    public static let format = "dev.thermo.module-package"
    public static let version = 1
    public static let maxPackageBytes = 24 << 20
    public static let maxWasmBytes = 16 << 20
    public static let maxManifestBytes = 256 << 10

    public var manifestData: Data
    public var wasm: Data
    /// Ed25519 over `digest`.
    public var signature: Data
    /// Which pipeline key signed it.
    public var keyID: String

    public init(manifestData: Data, wasm: Data, signature: Data, keyID: String) {
        self.manifestData = manifestData; self.wasm = wasm; self.signature = signature; self.keyID = keyID
    }

    /// What the signature covers: format, both content hashes, in a fixed layout.
    public static func digest(manifest: Data, wasm: Data) -> Data {
        let text = "\(format)/v\(version)\nmanifest-sha256:\(packageHex(SHA256.hash(data: manifest)))\nwasm-sha256:\(packageHex(SHA256.hash(data: wasm)))\n"
        return Data(text.utf8)
    }
    public var digest: Data { Self.digest(manifest: manifestData, wasm: wasm) }
    public var wasmHash: String { packageHex(SHA256.hash(data: wasm)) }
    /// Content address of a package file as downloaded.
    public static func fileHash(_ data: Data) -> String { packageHex(SHA256.hash(data: data)) }

    struct Wire: Codable {
        var format: String
        var version: Int
        var keyID: String
        var manifest: String
        var wasm: String
        var signature: String
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Wire(format: Self.format, version: Self.version, keyID: keyID, manifest: manifestData.base64EncodedString(),
                                       wasm: wasm.base64EncodedString(), signature: signature.base64EncodedString()))
    }

    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case tooLarge
        case notAPackage
        case newerFormat(Int)
        case unknownKey(String)
        case badSignature
        case invalidManifest([String])
        case reservedID(String)
        case notWebAssembly
        public var description: String {
            switch self {
            case .tooLarge: return "package is larger than allowed"
            case .notAPackage: return "not a Thermo module package"
            case .newerFormat(let v): return "package format \(v) is newer than this Thermo"
            case .unknownKey(let k): return "signed by unknown key \(k)"
            case .badSignature: return "signature does not match the contents"
            case .invalidManifest(let p): return "manifest: " + p.joined(separator: "; ")
            case .reservedID(let id): return "\(id) belongs to a built-in feature"
            case .notWebAssembly: return "module code is not WebAssembly"
            }
        }
    }

    public static func decode(_ data: Data) throws -> ModulePackage {
        guard data.count <= maxPackageBytes else { throw Problem.tooLarge }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.format == format else { throw Problem.notAPackage }
        guard wire.version <= version else { throw Problem.newerFormat(wire.version) }
        guard let manifest = Data(base64Encoded: wire.manifest), let wasm = Data(base64Encoded: wire.wasm),
              let signature = Data(base64Encoded: wire.signature) else { throw Problem.notAPackage }
        guard manifest.count <= maxManifestBytes, wasm.count <= maxWasmBytes else { throw Problem.tooLarge }
        return ModulePackage(manifestData: manifest, wasm: wasm, signature: signature, keyID: wire.keyID)
    }

    /// Checks everything that can be checked without running it and returns the manifest.
    /// `keys` maps a key ID to a raw 32-byte Ed25519 public key.
    public func verify(keys: [String: Data]) throws -> ModuleManifest {
        guard let raw = keys[keyID] else { throw Problem.unknownKey(keyID) }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw), key.isValidSignature(signature, for: digest) else {
            throw Problem.badSignature
        }
        guard wasm.starts(with: [0x00, 0x61, 0x73, 0x6d]) else { throw Problem.notWebAssembly }
        let manifest: ModuleManifest
        do { manifest = try ModuleManifest.load(manifestData) }
        catch let invalid as ModuleManifest.Invalid { throw Problem.invalidManifest(invalid.problems) }
        catch { throw Problem.invalidManifest(["\(error)"]) }
        if BuiltinModuleManifests.all.contains(where: { $0.id == manifest.id }) || manifest.id.hasPrefix("dev.thermo.") {
            throw Problem.reservedID(manifest.id)
        }
        return manifest
    }

    /// Signing, for the pipeline tool and tests. The app never holds a private key.
    public static func sign(manifest: Data, wasm: Data, key: Curve25519.Signing.PrivateKey, keyID: String) throws -> ModulePackage {
        ModulePackage(manifestData: manifest, wasm: wasm, signature: try key.signature(for: digest(manifest: manifest, wasm: wasm)), keyID: keyID)
    }
}

/// Keys whose signatures Thermo accepts for module packages.
public enum ModuleSigningKeys {
    /// The production pipeline key. Empty until the real key pair is generated and its private half
    /// stored as the registry's CI secret; until then no package installs in a release build.
    public static let production: [String: Data] = [:]
}

func packageHex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }

/// Dotted-number versions; anything else is not comparable and never counts as an update.
public enum ModuleVersion {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
    static func parts(_ text: String) -> [Int]? {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
        let numbers = pieces.map { $0.allSatisfy(\.isASCII) ? Int($0) : nil }
        return numbers.contains(nil) ? nil : numbers.compactMap { $0 }.allSatisfy { $0 >= 0 } ? numbers.compactMap { $0 } : nil
    }
}
