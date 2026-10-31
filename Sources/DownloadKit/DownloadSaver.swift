import Foundation

/// Path checks for names that come from remote listings.
public enum DownloadPathPolicy {
    public struct SafePath: Sendable, Equatable {
        public var fileName: String
        public var relativeDirectory: String
    }

    /// nil for an absolute path or any `.`/`..` piece. A trailing `/` means only a folder was
    /// given, so the last piece stays a folder and the file takes `fallbackName`.
    public static func sanitize(_ relativePath: String, fallbackName: String) -> SafePath? {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") { return nil }
        let raw = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if raw.contains(where: { $0 == "." || $0 == ".." }) { return nil }
        let parts = raw.filter { !$0.allSatisfy(\.isWhitespace) }
        let nameMissing = normalized.hasSuffix("/")
        let name = sanitizeName(nameMissing ? "" : parts.last ?? "")
        let directories = nameMissing ? parts : Array(parts.dropLast())
        return SafePath(
            fileName: name.isEmpty ? fallbackName : name,
            relativeDirectory: directories.map(sanitizeName).joined(separator: "/")
        )
    }

    public static func sanitizeName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "[\\\\/:*?\"<>|\\x00-\\x1f]", with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 120 {
            let pieces = cleaned.split(separator: ".", omittingEmptySubsequences: false)
            let suffix = pieces.count > 1 ? String(pieces.last!.prefix(10)) : ""
            if suffix.isEmpty {
                cleaned = String(cleaned.prefix(120))
            } else {
                cleaned = String(cleaned.dropLast(pieces.last!.count + 1).prefix(100)) + "." + suffix
            }
        }
        return cleaned
    }

    /// Strictly inside `base` after resolving symlinks, including those of existing parents.
    public static func isContained(base: URL, candidate: URL) -> Bool {
        let root = canonical(base.path)
        let path = canonical(candidate.path)
        return path != root && path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// Like Java's `canonicalFile`: resolves the deepest existing ancestor, keeps the rest.
    static func canonical(_ path: String) -> String {
        var head = URL(fileURLWithPath: path).standardizedFileURL.path
        var tail: [String] = []
        while true {
            if let resolved = realpath(head, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + tail.reversed()).joined(separator: "/")
            }
            guard head != "/", !head.isEmpty else { return path }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
    }
}

public enum DownloadSaver {
    /// The custom folder if set, else the user's Downloads folder.
    public static func resolveSaveDirectory(custom: String?) -> URL {
        if let custom, !custom.allSatisfy(\.isWhitespace) { return URL(fileURLWithPath: custom, isDirectory: true) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// Where a remote relative name lands under `directory`, creating its folders. Fails if the
    /// name escapes. Collisions are left to the engine's exclusive publish.
    public static func destination(for fileName: String, in directory: URL) throws -> URL {
        guard let safe = DownloadPathPolicy.sanitize(fileName, fallbackName: "download_\(Int(Date().timeIntervalSince1970 * 1000))") else {
            throw DownloadError.unsupportedURL("unsafe relative path")
        }
        var folder = directory
        if !safe.relativeDirectory.isEmpty {
            folder = directory.appendingPathComponent(safe.relativeDirectory, isDirectory: true)
            guard DownloadPathPolicy.isContained(base: directory, candidate: folder) else {
                throw DownloadError.unsupportedURL("path leaves the save folder")
            }
        }
        let file = folder.appendingPathComponent(safe.fileName)
        guard DownloadPathPolicy.isContained(base: directory, candidate: file) else {
            throw DownloadError.unsupportedURL("path leaves the save folder")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.io(error.localizedDescription)
        }
        return file
    }

    /// Moves a finished file in, never over an existing one. Returns the final location.
    public static func save(_ source: URL, as fileName: String, in directory: URL) throws -> URL {
        try DownloadFinalizer.publish(source, to: destination(for: fileName, in: directory))
    }

    /// Removes a saved file or folder: a multi-file torrent lands as a directory.
    @discardableResult
    public static func delete(_ path: String) -> Bool {
        guard !path.allSatisfy(\.isWhitespace) else { return false }
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }
}
