import Foundation

/// Magnet links are not URLs: no authority, and a `dn` that can hold spaces. Plain string
/// handling only; the real name comes from a torrent engine, which Thermo does not have yet.
public enum MagnetLink {
    private static let scheme = "magnet:"
    static let maxNameLength = 80

    public static func isMagnet(_ url: String) -> Bool {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > scheme.count && text.prefix(scheme.count).lowercased() == scheme
    }

    /// `dn=`, else a placeholder from the info hash. Only for display before metadata arrives.
    public static func displayName(_ url: String) -> String {
        let name = collapseBlanks(param(url, "dn")).trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return String(name.prefix(maxNameLength)) }
        let hash = infoHash(url)
        return hash.count >= 8 ? "磁力_\(hash.prefix(8))" : "磁力任务"
    }

    /// Uppercased; empty when absent. For display and logs, not for de-duplication.
    public static func infoHash(_ url: String) -> String {
        guard let found = url.range(of: "xt=urn:btih:[A-Za-z0-9]+", options: [.regularExpression, .caseInsensitive]) else {
            return ""
        }
        return String(url[found].dropFirst("xt=urn:btih:".count)).uppercased()
    }

    /// The first match wins. `+` stays literal: it is common in file names.
    private static func param(_ url: String, _ key: String) -> String {
        guard let mark = url.firstIndex(of: "?") else { return "" }
        for part in url[url.index(after: mark)...].split(separator: "&", omittingEmptySubsequences: false) {
            guard let equals = part.firstIndex(of: "="), equals > part.startIndex,
                  part[..<equals].lowercased() == key.lowercased() else { continue }
            let value = String(part[part.index(after: equals)...])
            return (value.removingPercentEncoding ?? value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    static func collapseBlanks(_ text: String) -> String {
        text.replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
    }
}

/// `ed2k://|file|<name>|<bytes>|<hash>|/`. Only the `file` type creates a download.
public enum Ed2kLink {
    private static let scheme = "ed2k://"

    public static func isEd2k(_ url: String) -> Bool { parts(url)?.first == "file" }

    public static func fileName(_ url: String) -> String {
        guard let parts = parts(url), parts.first == "file", parts.count > 1 else { return "" }
        let name = MagnetLink.collapseBlanks(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(name.prefix(MagnetLink.maxNameLength))
    }

    /// -1 when absent or invalid.
    public static func fileSize(_ url: String) -> Int64 {
        guard let parts = parts(url), parts.first == "file", parts.count > 2,
              let size = Int64(parts[2].trimmingCharacters(in: .whitespaces)), size > 0 else { return -1 }
        return size
    }

    /// Element 0 is the lowercased type. The empty piece before the first `|` is dropped.
    private static func parts(_ url: String) -> [String]? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > scheme.count, text.prefix(scheme.count).lowercased() == scheme else { return nil }
        var pieces = text.dropFirst(scheme.count).split(separator: "|").map(String.init)
        guard !pieces.isEmpty else { return [""] }
        pieces[0] = pieces[0].lowercased()
        return pieces
    }
}

/// Everything the HTTP engine must refuse, decided in one place.
public enum P2PLink {
    private static let torrentSuffix = ".torrent"

    public static func matches(_ url: String) -> Bool {
        MagnetLink.isMagnet(url) || Ed2kLink.isEd2k(url) || isTorrentFile(url)
    }

    /// A local `.torrent` path. An http link to one is an ordinary download.
    public static func isTorrentFile(_ url: String) -> Bool {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.contains("://") && text.count > torrentSuffix.count && text.lowercased().hasSuffix(torrentSuffix)
    }

    public static func platform(for url: String) -> String {
        Ed2kLink.isEd2k(url) ? "ed2k" : "magnet"
    }

    public static func displayName(_ url: String) -> String {
        if MagnetLink.isMagnet(url) { return MagnetLink.displayName(url) }
        if Ed2kLink.isEd2k(url) { return Ed2kLink.fileName(url) }
        guard isTorrentFile(url) else { return "" }
        let path = url.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        let base = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
        return base.count > torrentSuffix.count ? String(base.dropLast(torrentSuffix.count)) : base
    }

    public static func knownSize(_ url: String) -> Int64 {
        Ed2kLink.isEd2k(url) ? Ed2kLink.fileSize(url) : -1
    }
}
