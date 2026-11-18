import Foundation
import ThermoL10n

/// `~/Library/Developer/Xcode/<platform> DeviceSupport/<model> <version> (<build>)`: debug symbols Xcode copies
/// from a device the first time it connects with a new OS build. Only the folder matching a device's current build
/// is ever read again, so age says little; a folder another build replaced is dead weight on the day it is replaced.
enum DeviceSupport {
    static let roots = ["~/Library/Developer/Xcode/iOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport",
                        "~/Library/Developer/Xcode/tvOS DeviceSupport", "~/Library/Developer/Xcode/visionOS DeviceSupport"]

    struct Paired: Hashable { var model: String; var build: String }

    struct Folder {
        var path: String
        var model: String?
        var version: String
        var build: String?
        var size: TreeSize
        var touched: Date?
    }

    /// "iPhone14,7 27.2.1 (24B156)" → model iPhone14,7, version 27.2.1, build 24B156. Xcode before 15 wrote
    /// "16.0 (20A362)" without the model.
    static func parse(_ name: String) -> (model: String?, version: String, build: String?) {
        var rest = Substring(name)
        var model: String?
        if let space = rest.firstIndex(of: " "), rest[..<space].contains(",") {
            model = String(rest[..<space]); rest = rest[rest.index(after: space)...]
        }
        var build: String?
        if let open = rest.lastIndex(of: "("), rest.hasSuffix(")") {
            build = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
            rest = rest[..<open]
        }
        return (model, rest.trimmingCharacters(in: .whitespaces), build)
    }

    /// Model and current build of each device paired with this Mac; nil when devicectl is missing or fails.
    static func pairedDevices(cancellation: ScanCancellation?) -> Set<Paired>? {
        guard FS.exists("/Applications/Xcode.app") || FS.exists("/Library/Developer/CommandLineTools") else { return nil }
        let result = Shell.exec(["/usr/bin/xcrun", "devicectl", "list", "devices", "--quiet", "--json-output", "/dev/stdout"],
                                timeout: 15, cancellation: cancellation)
        guard result.0 == 0 else { return nil }
        return paired(fromJSON: result.1)
    }

    static func paired(fromJSON text: String) -> Set<Paired>? {
        guard let start = text.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any],
              let devices = (obj["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return nil }
        var out = Set<Paired>()
        for d in devices {
            let props = d["properties"] as? [String: Any]
            let hardware = (props?["hardware"] ?? d["hardwareProperties"]) as? [String: Any]
            let software = props?["software"] as? [String: Any]
            let build = ((software?["osBuildVersions"] as? [String: Any])?["buildVersion"] as? [String: Any])?["name"] as? String
                ?? (d["deviceProperties"] as? [String: Any])?["osBuildUpdate"] as? String
            if let model = hardware?["productType"] as? String, let build { out.insert(.init(model: model, build: build)) }
        }
        return out
    }

    static func scan(_ ctx: ScanContext) -> [CleanItem] {
        let roots = roots.map(ctx.path).filter(FS.isDirectory)
        guard !roots.isEmpty else { return [] }
        let paired = pairedDevices(cancellation: ScanCancellation.current)
        var folders: [Folder] = []
        for root in roots {
            for c in FS.children(root) where FS.isDirectory(c) {
                guard ScanCancellation.current?.isCancelled != true else { return [] }
                let s = FS.size(c, trackNewest: true)
                let p = parse((c as NSString).lastPathComponent)
                let touched = [s.newest, FS.mtime(c)].compactMap { $0 }.max()
                folders.append(.init(path: c, model: p.model, version: p.version, build: p.build, size: s, touched: touched))
            }
        }
        return item(folders, paired: paired, ctx: ctx).map { [$0] } ?? []
    }

    /// Why each folder can go, or nil to keep it.
    static func reasons(_ folders: [Folder], paired: Set<Paired>?, ctx: ScanContext) -> [(Folder, String)] {
        var out: [(Folder, String)] = []
        let byModel = Dictionary(grouping: folders.filter { $0.model != nil }, by: { $0.model! })
        for (model, group) in byModel {
            let current = paired.map { p in Set(p.filter { $0.model == model }.map(\.build)) }
            let newest = group.max { ($0.touched ?? .distantPast) < ($1.touched ?? .distantPast) }
            for f in group {
                if let current, !current.isEmpty {
                    // The device runs another build now; this one is never read again.
                    if let b = f.build, !current.contains(b) { out.append((f, tr("this device runs a newer build now"))) }
                } else if f.path != newest?.path {
                    out.append((f, tr("a newer build for this device exists")))
                } else if (f.touched ?? .distantPast) < ctx.staleBefore {
                    out.append((f, paired == nil ? tr("untouched for %1$@ days", String(ctx.options.olderThanDays))
                                                 : tr("no paired device uses it")))
                }
            }
        }
        // Folders without a model: keep the two most recent, the rest only once untouched.
        let bare = folders.filter { $0.model == nil }.sorted { ($0.touched ?? .distantPast) > ($1.touched ?? .distantPast) }
        for f in bare.dropFirst(2) where (f.touched ?? .distantPast) < ctx.staleBefore {
            out.append((f, tr("untouched for %1$@ days", String(ctx.options.olderThanDays))))
        }
        return out.sorted { $0.0.path < $1.0.path }
    }

    static func item(_ folders: [Folder], paired: Set<Paired>?, ctx: ScanContext) -> CleanItem? {
        let removable = reasons(folders, paired: paired, ctx: ctx)
        let bytes = removable.reduce(Int64(0)) { $0 + $1.0.size.bytes }
        guard bytes > 0 else { return nil }
        let kept = folders.count - removable.count
        let parts = removable.map { f, why in
            CleanPart(id: (f.path as NSString).lastPathComponent,
                      title: [f.model, f.version, f.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ") + " · " + why,
                      bytes: f.size.bytes, lastUsed: f.touched, paths: [f.path])
        }
        var notes = [tr("symbols copied from devices; recreated when a device connects")]
        if kept > 0 {
            notes.append(paired == nil ? tr("the newest build of each device is kept")
                                       : tr("%1$@ folder(s) matching a paired device's current build are kept", String(kept)))
        }
        return CleanItem(id: "xcode-device-support", category: .xcode, title: tr("iOS / watchOS device support"),
                         detail: ctx.tilde(roots.map(ctx.path).first { p in removable.contains { $0.0.path.hasPrefix(p + "/") } } ?? ctx.path(roots[0])),
                         safety: .safe, bytes: bytes, files: removable.reduce(0) { $0 + $1.0.size.files },
                         lastUsed: removable.compactMap(\.0.touched).max(), paths: removable.map(\.0.path),
                         note: notes.joined(separator: tr("; ")), parts: parts)
    }
}
