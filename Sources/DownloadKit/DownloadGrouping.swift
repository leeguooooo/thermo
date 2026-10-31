import Foundation

/// Keys for folder groups on a downloads list. A group needs the save root as well as the top
/// folder name: one folder saved to two places has identical relative names. Strings only, as
/// this runs on every progress refresh and must not stat the disk.
public enum DownloadGrouping {
    public struct Item: Sendable, Equatable {
        /// May be a relative path such as `Folder/Sub/file.mp4`.
        public var fileName: String
        /// Final path, empty until finished.
        public var savePath: String
        public var saveDirectory: String

        public init(fileName: String, savePath: String = "", saveDirectory: String = "") {
            self.fileName = fileName
            self.savePath = savePath
            self.saveDirectory = saveDirectory
        }
    }

    /// Derived from the final path when there is one, so later settings changes do not move it.
    public static func saveRoot(_ item: Item, globalRoot: String?) -> String {
        let name = item.fileName.replacingOccurrences(of: "\\", with: "/")
        if !blank(item.savePath), let slash = name.lastIndex(of: "/") {
            var directory = parent(item.savePath)
            for piece in name[..<slash].split(separator: "/") where !blank(String(piece)) {
                directory = directory.flatMap(parent)
            }
            if let directory { return absolute(directory) }
        }
        return blank(item.saveDirectory) ? (globalRoot ?? "") : item.saveDirectory
    }

    public static func groupKey(_ item: Item, globalRoot: String?) -> (root: String, folder: String) {
        let name = item.fileName.replacingOccurrences(of: "\\", with: "/")
        let folder = name.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        return (normalizeRoot(saveRoot(item, globalRoot: globalRoot)), folder)
    }

    /// Absolute, without trailing separators. Comparison only; display the original path.
    public static func normalizeRoot(_ root: String) -> String {
        if blank(root) { return "" }
        var path = absolute(root)
        while path.hasSuffix("/") || path.hasSuffix("\\") { path.removeLast() }
        return path
    }

    private static func blank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }

    private static func absolute(_ path: String) -> String {
        URL(fileURLWithPath: path).path
    }

    private static func parent(_ path: String) -> String? {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard trimmed != "/", let slash = trimmed.lastIndex(of: "/") else { return nil }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }
}
