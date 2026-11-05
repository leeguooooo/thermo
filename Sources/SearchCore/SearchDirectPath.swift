import Foundation

/// Explicit local paths bypass the name index without adding folders or scanning their contents.
public enum SearchDirectPath {
    public static func path(from query: String) -> String? {
        var value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 16_384, !value.contains("\0") else { return nil }
        if let first = value.first, (first == "\"" || first == "'"), value.last == first, value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        if value.lowercased().hasPrefix("file:") {
            guard let url = URL(string: value), url.isFileURL,
                  url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
                  url.query == nil, url.fragment == nil else { return nil }
            value = url.path
        } else if value == "~" || value.hasPrefix("~/") {
            value = (value as NSString).expandingTildeInPath
        }
        guard value.hasPrefix("/"), !value.contains("\0") else { return nil }
        // Prefer the literal name: a backslash is legal in a Unix filename.
        if !FileManager.default.fileExists(atPath: value) {
            value = value.replacingOccurrences(of: "\\ ", with: " ")
                .replacingOccurrences(of: "\\(", with: "(").replacingOccurrences(of: "\\)", with: ")")
        }
        return (value as NSString).standardizingPath
    }

    public static func item(at path: String) -> SearchItem? {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { return nil }
        let url = URL(fileURLWithPath: path)
        let kind: SearchItemKind = directory.boolValue ? (url.pathExtension.lowercased() == "app" ? .application : .folder) : .file
        return SearchItem(path: path, name: path == "/" ? "/" : url.lastPathComponent, kind: kind)
    }
}
