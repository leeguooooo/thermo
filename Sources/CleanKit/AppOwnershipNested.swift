import AgentCore
import Darwin
import Foundation

extension AppOwnershipSnapshot {
    struct NestedDeclaration: Equatable {
        let path: String
        let container: String
    }

    /// Known code-bundle locations only. Never follows a link outside its host,
    /// launches code, or recursively walks arbitrary resources and user data.
    static func nestedDeclarations(in hosts: [String], issues: inout [String]) -> [NestedDeclaration] {
        let suffixes = [".app", ".appex", ".xpc", ".framework", ".bundle", ".systemextension"]
        let locations = ["Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/PlugIns",
                         "Contents/XPCServices", "Contents/Helpers", "Contents/Frameworks", "Contents/Extensions",
                         "Contents/Library/SystemExtensions", "Frameworks", "PlugIns", "Helpers", "XPCServices",
                         "Versions/Current/Frameworks", "Versions/Current/Helpers", "Versions/Current/XPCServices", "Versions/Current/PlugIns"]
        var queue = hosts.map { path in
            let outer = hosts.filter { path.hasPrefix($0 + "/") }.min { $0.count < $1.count } ?? path
            return (path, outer, 0)
        }, cursor = 0
        var visited = Set<String>(), declarations: [String: NestedDeclaration] = [:]
        while cursor < queue.count {
            let (bundle, host, depth) = queue[cursor]; cursor += 1
            if ScanCancellation.current?.isCancelled == true { issues.append(bundle); break }
            let physical = URL(fileURLWithPath: bundle).resolvingSymlinksInPath().path
            guard visited.insert(physical).inserted else { continue }
            let boundary = URL(fileURLWithPath: host).resolvingSymlinksInPath().path + "/"
            for relative in locations {
                let directory = bundle + "/" + relative
                var link = stat(), actual = stat()
                guard lstat(directory, &link) == 0 else { if errno != ENOENT { issues.append(directory) }; continue }
                guard URL(fileURLWithPath: directory).resolvingSymlinksInPath().path.hasPrefix(boundary),
                      stat(directory, &actual) == 0, actual.st_mode & S_IFMT == S_IFDIR else { issues.append(directory); continue }
                var unreadable = false
                let names = AppUninstaller.names(in: directory, onFailure: { unreadable = true }) ?? []
                if unreadable { issues.append(directory) }
                for name in names.sorted() where suffixes.contains(where: name.hasSuffix) {
                    let path = directory + "/" + name
                    guard declarations.count < 4096 else { issues.append(directory); return declarations.values.sorted { $0.path < $1.path } }
                    var entry = stat()
                    guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(boundary),
                          stat(path, &entry) == 0, entry.st_mode & S_IFMT == S_IFDIR else { issues.append(path); continue }
                    if !hosts.contains(path) { declarations[path] = .init(path: path, container: host) }
                    if depth < 8 { queue.append((path, host, depth + 1)) } else { issues.append(path) }
                }
            }
        }
        return declarations.values.sorted { $0.path < $1.path }
    }

    static func readDeclaration(_ declaration: NestedDeclaration) -> Claim? {
        let path = declaration.path
        let relatives = path.hasSuffix(".framework")
            ? ["Resources/Info.plist", "Versions/Current/Resources/Info.plist", "Contents/Info.plist", "Info.plist"]
            : ["Contents/Info.plist", "Info.plist", "Resources/Info.plist"]
        for relative in relatives {
            let file = path + "/" + relative
            var info = stat()
            guard lstat(file, &info) == 0 else { if errno != ENOENT { return nil }; continue }
            let boundary = URL(fileURLWithPath: declaration.container).resolvingSymlinksInPath().path + "/"
            guard URL(fileURLWithPath: file).resolvingSymlinksInPath().path.hasPrefix(boundary),
                  let claim = read(path, metadata: file) else { return nil }
            // Resource bundles may have no executable identity. Preserve their
            // metadata fingerprint without inventing an application identifier.
            return claim.bundleID != nil || path.hasSuffix(".bundle") || path.hasSuffix(".framework") ? claim : nil
        }
        return path.hasSuffix(".bundle") || path.hasSuffix(".framework") ? read(path) : nil
    }

    // Declared IDs in shipped bundles need not use three reverse-DNS components.
    // Keep this separate from the stricter orphan-directory discovery heuristic.
    static func validDeclaredID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 255 && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }
}
