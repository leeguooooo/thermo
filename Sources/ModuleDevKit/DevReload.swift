import Foundation
import ModuleKit

/// How `thermo dev run` reaches a running Thermo: it points the development directory at the build
/// output, switches the module on, and posts one distributed notification. The app only re-reads the
/// development directory it already trusts, so the notification carries no data.
public enum DevReload {
    public static let notification = Notification.Name("dev.thermo.modules.reload")
    public static let directoryKey = "modules.developmentDirectory"

    public struct Target: Sendable {
        public let point: @Sendable (_ directory: URL, _ moduleID: String) -> Void
        public let post: @Sendable () -> Void
        public init(point: @escaping @Sendable (URL, String) -> Void, post: @escaping @Sendable () -> Void) { self.point = point; self.post = post }

        /// The installed app's preferences and the distributed notification center.
        public static let app = Target(
            point: { directory, id in
                let defaults = UserDefaults(suiteName: ModulePreferences.appDomain)
                defaults?.set(directory.path, forKey: DevReload.directoryKey)
                defaults?.set(true, forKey: ModulePreferences.key(id))
                defaults?.synchronize()
            },
            post: { DistributedNotificationCenter.default().postNotificationName(DevReload.notification, object: nil, userInfo: nil, deliverImmediately: true) })
    }
}

/// Polls a source folder for changes (module.json, src/, views/, strings/). Polling keeps it simple and
/// identical on every macOS; at twice a second it costs nothing measurable.
public final class FolderWatcher: @unchecked Sendable {
    private let source: ModuleSource
    private var last: [String: Date]
    public init(_ source: ModuleSource) { self.source = source; last = Self.fingerprint(source) }

    static func fingerprint(_ source: ModuleSource) -> [String: Date] {
        var result: [String: Date] = [:]
        let roots = [source.manifestURL, source.folder.appendingPathComponent("src"), source.viewsURL, source.stringsURL]
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            let files = isDirectory.boolValue
                ? ((FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])?.allObjects as? [URL]) ?? [])
                : [root]
            for file in files {
                result[file.path] = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            }
        }
        return result
    }

    /// True once per change since the last call.
    public func changed() -> Bool {
        let now = Self.fingerprint(source)
        defer { last = now }
        return now != last
    }
}

/// One build-and-reload step of `thermo dev run`; the CLI loops it.
public struct DevSession: Sendable {
    public let source: ModuleSource
    public let builder: ModuleBuilder
    public let target: DevReload.Target
    public init(source: ModuleSource, builder: ModuleBuilder, target: DevReload.Target = .app) {
        self.source = source; self.builder = builder; self.target = target
    }

    /// Builds; on success points the app at the output and asks it to reload. A failed build leaves
    /// the last good module loaded and returns the reason.
    @discardableResult public func rebuild() -> Result<ModuleBuilder.Output, ModuleSource.Failure> {
        do {
            let output = try builder.build(source)
            target.point(source.outputRoot, output.manifest.id)
            target.post()
            return .success(output)
        } catch let failure as ModuleSource.Failure {
            return .failure(failure)
        } catch {
            return .failure(.init("\(error)"))
        }
    }
}
