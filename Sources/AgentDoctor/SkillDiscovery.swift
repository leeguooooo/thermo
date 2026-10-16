import Foundation
import ThermoL10n

extension ConfigChecks {
    /// Only the explicitly selected project and its ancestors to a Git root.
    /// Outside a repository, inspect that directory alone, not unrelated parents.
    func projectSkillRoots() -> [(URL, String, String)] {
        guard let selected = env.project?.standardizedFileURL else { return [] }
        var directories: [URL] = []
        var current = selected
        var repository = false
        for _ in 0..<64 {
            directories.append(current)
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { repository = true; break }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return (repository ? directories : [selected]).flatMap { directory in
            [(directory.appendingPathComponent(".agents/skills"), "codex", "project " + env.short(directory.path)),
             (directory.appendingPathComponent(".claude/skills"), "claude", "project " + env.short(directory.path))]
        }
    }

    /// Cache inventory is deliberately separate from effective enabled-plugin truth.
    /// Old versions can coexist and desktop-managed plugins may have no local setting.
    mutating func codexCacheSkillRoots() -> [(URL, String, String)] {
        let fm = FileManager.default
        let cache = env.url(".codex/plugins/cache")
        let settings = (try? String(contentsOf: env.url(".codex/config.toml"), encoding: .utf8)) ?? ""
        let enabled = Self.codexPluginFlags(settings)
        var roots: [(URL, String, String)] = []
        var budget = 4096
        var incomplete = false
        func directories(_ parent: URL) -> [URL] {
            guard !env.cancelled(), budget > 0 else { incomplete = true; return [] }
            do {
                let names = try fm.contentsOfDirectory(atPath: parent.path).filter { !$0.hasPrefix(".") }.sorted()
                if names.count > budget { incomplete = true }
                let candidates = names.prefix(budget)
                budget -= candidates.count
                return candidates.compactMap {
                    let url = parent.appendingPathComponent($0)
                    var directory: ObjCBool = false
                    return fm.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue ? url : nil
                }
            } catch { if fm.fileExists(atPath: parent.path) { incomplete = true }; return [] }
        }
        for market in directories(cache) {
            for plugin in directories(market) {
                let namespace = plugin.lastPathComponent + "@" + market.lastPathComponent
                for version in directories(plugin) {
                    guard !env.cancelled() else { return roots }
                    let manifests = [version.appendingPathComponent("plugin.json"), version.appendingPathComponent(".codex-plugin/plugin.json"), version.appendingPathComponent(".claude-plugin/plugin.json")]
                    guard let manifest = manifests.first(where: { fm.fileExists(atPath: $0.path) }),
                          let text = Self.readSkill(manifest),
                          let data = text.data(using: .utf8),
                          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { incomplete = true; continue }
                    let paths: [String]
                    if manifest.deletingLastPathComponent() == version { paths = ["./skills"] }
                    else if let path = object["skills"] as? String { paths = [path] }
                    else if let list = object["skills"] as? [String] { paths = list }
                    else { paths = ["./skills"] }
                    for path in paths.prefix(64) {
                        let root = version.appendingPathComponent(path).standardizedFileURL
                        let base = version.resolvingSymlinksInPath().standardizedFileURL.path
                        let resolved = root.resolvingSymlinksInPath().standardizedFileURL.path
                        guard !path.hasPrefix("/"), resolved.hasPrefix(base + "/") else { incomplete = true; continue }
                        // Missing optional skill directories mean the plugin has no cached skills.
                        guard fm.fileExists(atPath: root.path) else { continue }
                        cacheSkillSources[root.path] = (namespace, enabled[namespace])
                        roots.append((root, "codex-cache", "cache " + namespace + " / " + version.lastPathComponent))
                    }
                    if paths.count > 64 { incomplete = true }
                }
            }
        }
        if incomplete {
            currentItem = nil
            add(Finding(.warning, .skills, agent: "codex-cache", subject: env.short(cache.path),
                        tr("Codex plugin cache inspection is incomplete; a manifest, path or discovery limit could not be verified."), source: env.short(cache.path)))
        }
        return roots
    }

    static func codexPluginFlags(_ text: String) -> [String: Bool] {
        var flags: [String: Bool] = [:]
        var plugin: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                let parts = tomlKeyPath(header)
                plugin = parts.count == 2 && parts[0] == "plugins" ? parts[1] : nil
            } else if let plugin, let equal = line.firstIndex(of: "="), line[..<equal].trimmingCharacters(in: .whitespaces) == "enabled" {
                let value = line[line.index(after: equal)...].split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
                if value == "true" { flags[plugin] = true }
                if value == "false" { flags[plugin] = false }
            }
        }
        return flags
    }
}
