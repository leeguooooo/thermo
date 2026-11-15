import Foundation

/// Modules keep the ordinary app sandbox. Manifest capabilities authorize kernel requests;
/// they never become direct filesystem or network exceptions that bypass the kernel's rules.
public enum ModuleEntitlements {
    public static let sandbox = "com.apple.security.app-sandbox"
    public static let homeReadOnly = "com.apple.security.temporary-exception.files.home-relative-path.read-only"
    public static let absoluteReadOnly = "com.apple.security.temporary-exception.files.absolute-path.read-only"

    /// The kernel performs declared operations after validating and recording each request.
    public static func values(for _: ModuleManifest) -> [String: Any] { [sandbox: true] }

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
