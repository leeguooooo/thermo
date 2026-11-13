import Foundation

/// A module as it sits inside Thermo.app: `Contents/Extensions/<name>.appex` with its `module.json`.
public struct InstalledModule: Sendable, Equatable {
    public var url: URL
    public var manifest: ModuleManifest
}

public enum ModuleBundles {
    /// The one extension point every Thermo module attaches to.
    public static let extensionPoint = "dev.thermo.module"

    /// The modules inside `app`, by id, and what is wrong with the ones that were refused.
    /// Only this app's own bundle is read: a module elsewhere on the Mac is never loaded.
    public static func installed(in app: URL) -> (modules: [InstalledModule], problems: [String]) {
        let folder = app.appendingPathComponent("Contents/Extensions")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".appex") }.sorted()
        var modules: [InstalledModule] = [], problems: [String] = []
        for name in names {
            let url = folder.appendingPathComponent(name)
            switch read(url) {
            case .success(let module):
                if modules.contains(where: { $0.manifest.id == module.manifest.id }) { problems.append("\(name): id \(module.manifest.id) is used by another module") }
                else { modules.append(module) }
            case .failure(let invalid): problems.append("\(name): \(invalid)")
            }
        }
        return (modules, problems)
    }

    public static func read(_ appex: URL) -> Result<InstalledModule, ModuleManifest.Invalid> {
        let contents = appex.appendingPathComponent("Contents")
        guard let data = FileManager.default.contents(atPath: contents.appendingPathComponent("Resources/module.json").path) else {
            return .failure(.init(problems: ["no Contents/Resources/module.json"]))
        }
        let manifest: ModuleManifest
        do { manifest = try ModuleManifest.load(data) }
        catch let invalid as ModuleManifest.Invalid { return .failure(invalid) }
        catch { return .failure(.init(problems: ["\(error)"])) }
        guard let plist = FileManager.default.contents(atPath: contents.appendingPathComponent("Info.plist").path),
              let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else {
            return .failure(.init(problems: ["unreadable Info.plist"]))
        }
        var problems: [String] = []
        let bundleID = info["CFBundleIdentifier"] as? String ?? ""
        if bundleID != manifest.id { problems.append("bundle id \(bundleID) differs from manifest id \(manifest.id)") }
        let point = (info["EXAppExtensionAttributes"] as? [String: Any])?["EXExtensionPointIdentifier"] as? String ?? ""
        if point != extensionPoint { problems.append("extension point \(point) is not \(extensionPoint)") }
        return problems.isEmpty ? .success(InstalledModule(url: appex, manifest: manifest)) : .failure(.init(problems: problems))
    }
}
