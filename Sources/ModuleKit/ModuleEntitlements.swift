import Foundation

/// The sandbox a module is signed into, derived from its manifest and nothing else. Every module is
/// sandboxed. Each `files.read` scope becomes a read-only exception, so the module reads those
/// folders itself and the system, not Thermo, keeps it inside them. Nothing ever becomes writable:
/// changes go through the kernel.
public enum ModuleEntitlements {
    public static let sandbox = "com.apple.security.app-sandbox"
    public static let homeReadOnly = "com.apple.security.temporary-exception.files.home-relative-path.read-only"
    public static let absoluteReadOnly = "com.apple.security.temporary-exception.files.absolute-path.read-only"

    /// The entitlements for `manifest`, keys and paths sorted.
    public static func values(for manifest: ModuleManifest) -> [String: Any] {
        var home = Set<String>(), absolute = Set<String>()
        for capability in manifest.capabilities where capability.kind == .filesRead {
            guard let scope = capability.scope else { continue }
            // A trailing slash makes the exception cover the folder and everything below it.
            if scope == "~" { home.insert("/") }
            else if scope.hasPrefix("~/"), let path = Capability.path(scope, home: "") { home.insert(path + "/") }
            else if let path = Capability.path(scope, home: "") { absolute.insert(path == "/" ? "/" : path + "/") }
        }
        var values: [String: Any] = [sandbox: true]
        if !home.isEmpty { values[homeReadOnly] = home.sorted() }
        if !absolute.isEmpty { values[absoluteReadOnly] = absolute.sorted() }
        return values
    }

    public static func plist(for manifest: ModuleManifest) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values(for: manifest), format: .xml, options: 0)
    }

    /// What is wrong with the entitlements a module was actually signed with; empty when they are
    /// exactly what its manifest gives it.
    public static func problems(signed: [String: Any], manifest: ModuleManifest) -> [String] {
        let expected = values(for: manifest)
        var found: [String] = []
        for key in Set(signed.keys).union(expected.keys).sorted() {
            switch (signed[key], expected[key]) {
            case (nil, _): found.append("\(manifest.id): signature lacks \(key)")
            case (_, nil): found.append("\(manifest.id): signature has \(key), which its manifest does not give it")
            case let (have?, want?):
                if !(have as AnyObject).isEqual(want) { found.append("\(manifest.id): \(key) is \(have), manifest gives \(want)") }
            }
        }
        return found
    }
}
