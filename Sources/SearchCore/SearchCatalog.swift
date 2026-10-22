import Foundation

public enum ApplicationCatalog {
    public struct Report: Sendable {
        public var items: [SearchItem]
        public var issues: [String]
        public var complete: Bool { issues.isEmpty }
    }
    public static var defaultRoots: [URL] {
        ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications",
         NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static func item(at url: URL) -> SearchItem? {
        guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent
        let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? fileName
        var names = [fileName]
        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable", "CFBundleIdentifier"] {
            if let value = info[key] as? String, !value.isEmpty { names.append(value) }
        }
        return SearchItem(path: SearchPaths.entry(url.path), name: display, kind: .application, alternateNames: Array(Set(names)).sorted())
    }
    public static func scan(roots: [URL] = defaultRoots, cancellation: SearchCancellation? = nil) -> Report {
        var items: [SearchItem] = [], issues: [String] = [], seen = Set<String>()
        let fm = FileManager.default
        func list(_ url: URL) -> [URL] {
            do { return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) }
            catch {
                if fm.fileExists(atPath: url.path) { issues.append("Could not read applications in " + url.path) }
                return []
            }
        }
        for root in roots {
            if cancellation?.isCancelled == true { issues.append("Application scan cancelled."); break }
            for child in list(root) {
                var candidates = [child]
                if child.pathExtension != "app", (try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true {
                    candidates = list(child).filter { $0.pathExtension == "app" }
                }
                for url in candidates where url.pathExtension == "app" && seen.insert(url.path).inserted {
                    if cancellation?.isCancelled == true { issues.append("Application scan cancelled."); return Report(items: items, issues: issues) }
                    guard let item = item(at: url) else { issues.append("Could not read application metadata: " + url.path); continue }
                    items.append(item)
                }
            }
        }
        return Report(items: items, issues: issues)
    }
}

/// An ignore rule is scoped to its containing directory. Excluded directories are not descended.
struct SearchIgnoreRule {
    let base: String
    let negated: Bool
    let directoryOnly: Bool
    let expression: NSRegularExpression
    init?(_ line: String, base: String) {
        var pattern = line.trimmingCharacters(in: .newlines)
        while pattern.hasSuffix(" ") {
            let prefix = pattern.dropLast()
            if prefix.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1 { break }
            pattern.removeLast()
        }
        guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return nil }
        self.base = base
        negated = pattern.hasPrefix("!"); if negated { pattern.removeFirst() }
        if pattern.hasPrefix("\\#") || pattern.hasPrefix("\\!") { pattern.removeFirst() }
        directoryOnly = pattern.hasSuffix("/"); if directoryOnly { pattern.removeLast() }
        let anchored = pattern.hasPrefix("/"); if anchored { pattern.removeFirst() }
        guard !pattern.isEmpty else { return nil }
        let containsSlash = pattern.contains("/")
        var regex = anchored || containsSlash ? "^" : "(?:^|/)"
        let chars = Array(pattern); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    i += 1
                    if i + 1 < chars.count, chars[i + 1] == "/" { regex += "(?:.*/)?"; i += 1 } else { regex += ".*" }
                } else { regex += "[^/]*" }
            } else if c == "?" { regex += "[^/]" }
            else if c == "[" {
                var end = i + 1
                if end < chars.count, chars[end] == "!" || chars[end] == "^" { end += 1 }
                if end < chars.count, chars[end] == "]" { end += 1 }
                while end < chars.count, chars[end] != "]" { end += chars[end] == "\\" && end + 1 < chars.count ? 2 : 1 }
                if end < chars.count {
                    var content = String(chars[(i + 1)..<end])
                    if content.hasPrefix("!") { content = "^" + content.dropFirst() }
                    regex += "[" + content.replacingOccurrences(of: "[", with: "\\[") + "]"
                    i = end
                } else { regex += "\\[" }
            }
            else if c == "\\", i + 1 < chars.count { i += 1; regex += NSRegularExpression.escapedPattern(for: String(chars[i])) }
            else { regex += NSRegularExpression.escapedPattern(for: String(c)) }
            i += 1
        }
        regex += "(?:/|$)"
        guard let expression = try? NSRegularExpression(pattern: regex) else { return nil }
        self.expression = expression
    }
    func matches(_ path: String, directory: Bool) -> Bool {
        let prefix = SearchPaths.childrenPrefix(base)
        guard path.hasPrefix(prefix), !directoryOnly || directory else { return false }
        let relative = String(path.dropFirst(prefix.count))
        return expression.firstMatch(in: relative, range: NSRange(relative.startIndex..., in: relative)) != nil
    }
}

public enum SearchFileScanner {
    public struct Report: Sendable {
        public var count: Int
        public var complete: Bool
        public var available: Bool
        public var issues: [String]
    }
    /// Reads names and filesystem metadata only. Never opens file contents or follows directory symlinks.
    public static func scan(root: URL, scope: URL? = nil, preferences: SearchPreferences, cancellation: SearchCancellation,
                            excludingPaths: [String] = [],
                            emit: ([SearchItem]) throws -> Void) throws -> Report {
        let root = URL(fileURLWithPath: SearchPaths.canonical(root.path), isDirectory: true)
        let scope = scope.map { URL(fileURLWithPath: SearchPaths.canonical($0.path), isDirectory: true) }
        let excludingPaths = excludingPaths.map(SearchPaths.canonical)
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .isPackageKey]
        var issues: [String] = [], count = 0, batch: [SearchItem] = []
        guard let rootInfo = try? root.resourceValues(forKeys: [.isDirectoryKey]), rootInfo.isDirectory == true,
              fm.isReadableFile(atPath: root.path) else {
            return Report(count: 0, complete: false, available: false, issues: ["Search folder is unavailable: " + root.path])
        }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !preferences.includeHiddenFiles { options.insert(.skipsHiddenFiles) }
        let scanRoot = scope ?? root
        guard SearchPaths.isWithin(scanRoot.path, root: root.path) else { throw SearchFailure("Search scope is outside its configured folder.") }
        guard let enumerator = fm.enumerator(at: scanRoot, includingPropertiesForKeys: Array(keys), options: options, errorHandler: { url, _ in
            if issues.count < 32 { issues.append("Could not read " + url.path) }
            return true
        }) else { return Report(count: 0, complete: false, available: false, issues: ["Could not read " + root.path]) }
        var scopedRules: [(String, [SearchIgnoreRule])] = []
        let defaults = preferences.excludedPatterns.compactMap { SearchIgnoreRule($0, base: root.path) }
        func rules(in directory: URL) -> [SearchIgnoreRule] {
            guard preferences.respectIgnoreFiles else { return [] }
            return [".gitignore", ".ignore", ".thermoignore"].flatMap { name -> [SearchIgnoreRule] in
                let file = directory.appendingPathComponent(name)
                // Ignore files must be regular non-symlink files, and bounded before reading.
                guard let attrs = try? fm.attributesOfItem(atPath: file.path), attrs[.type] as? FileAttributeType == .typeRegular,
                      let size = attrs[.size] as? NSNumber, size.intValue <= 65536,
                      let handle = try? FileHandle(forReadingFrom: file) else { return [] }
                defer { try? handle.close() }
                guard let data = try? handle.read(upToCount: 65537), data.count <= 65536, let text = String(data: data, encoding: .utf8) else { return [] }
                return text.components(separatedBy: "\n").compactMap { SearchIgnoreRule($0, base: directory.path) }
            }
        }
        scopedRules.append((root.path, rules(in: root)))
        if scanRoot.path != root.path {
            let relative = scanRoot.path.dropFirst(SearchPaths.childrenPrefix(root.path).count).split(separator: "/")
            var parent = root
            for component in relative {
                parent.appendPathComponent(String(component))
                var ignored = false
                for rule in defaults + scopedRules.flatMap(\.1) where rule.matches(parent.path, directory: true) { ignored = !rule.negated }
                if ignored { return Report(count: 0, complete: true, available: true, issues: []) }
                scopedRules.append((parent.path, rules(in: parent)))
            }
        }
        while let url = enumerator.nextObject() as? URL {
            if cancellation.isCancelled { return Report(count: count, complete: false, available: true, issues: issues + ["Search indexing cancelled."]) }
            if excludingPaths.contains(where: { SearchPaths.isWithin(url.path, root: $0) }) { enumerator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: keys) else {
                if issues.count < 32 { issues.append("Could not inspect " + url.path) }; continue
            }
            let directory = values.isDirectory == true
            while let last = scopedRules.last, !SearchPaths.isWithin(url.path, root: last.0) { scopedRules.removeLast() }
            var ignored = false
            for rule in defaults + scopedRules.flatMap(\.1) where rule.matches(url.path, directory: directory) { ignored = !rule.negated }
            if ignored || directory && values.isSymbolicLink == true {
                if directory { enumerator.skipDescendants() }; continue
            }
            if directory, url.pathExtension == "app" {
                enumerator.skipDescendants()
                if var app = ApplicationCatalog.item(at: url) {
                    app.modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                    batch.append(app)
                } else {
                    if issues.count < 32 { issues.append("Could not read application metadata: " + url.path) }
                    continue
                }
            } else {
                batch.append(SearchItem(path: url.path, name: url.lastPathComponent, kind: directory ? .folder : .file,
                                        modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
            count += 1
            if directory, values.isPackage != true, url.pathExtension != "app" { scopedRules.append((url.path, rules(in: url))) }
            if batch.count == 256 { try emit(batch); batch.removeAll(keepingCapacity: true) }
        }
        if !batch.isEmpty { try emit(batch) }
        return Report(count: count, complete: issues.isEmpty, available: true, issues: issues)
    }
}
