import Foundation

enum MediaFindings {
    static let extensions: Set<String> = ["mp4", "mov", "webm", "mkv", "wav", "mp3", "flac", "png", "jpg", "jpeg", "psd", "blend"]
    static func note(in paths: [String]) -> String {
        var found: [(String, Int64)] = []
        var inspected = 0
        for path in paths {
            guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
            for case let file as URL in walk {
                inspected += 1
                guard inspected <= 4096, ScanCancellation.current?.isCancelled != true else { break }
                let value = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if value?.isSymbolicLink == true { walk.skipDescendants(); continue }
                if value?.isRegularFile == true, extensions.contains(file.pathExtension.lowercased()), let size = value?.fileSize, size >= 50 * 1024 * 1024 {
                    found.append((file.lastPathComponent, Int64(size)))
                }
            }
            if inspected > 4096 { break }
        }
        let names = found.sorted { $0.1 > $1.1 }.prefix(5).map { $0.0 + " (" + ByteFormat.string($0.1) + ")" }
        return names.isEmpty ? tr("; review contents before removal (scratchpads may contain work products)") : tr("; media to review: %1$@", names.joined(separator: ", "))
    }
}
