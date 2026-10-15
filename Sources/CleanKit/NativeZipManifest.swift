import Foundation

/// Inspect ZIP32 before asking the system's bsdtar to extract it. ZIP64/encrypted formats
/// stay with the original updater until an equivalent bounded path is available.
enum NativeZipManifest {
    static func validate(_ url: URL) throws -> Int64 {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func fail() -> ArchiveFailure { ArchiveFailure("The ZIP directory is unsafe or unsupported") }
        func number(_ at: Int, _ size: Int) throws -> UInt64 {
            guard at >= 0, at <= data.count - size else { throw fail() }
            var value: UInt64 = 0
            for i in 0..<size { value |= UInt64(data[at + i]) << (i * 8) }
            return value
        }
        guard data.count >= 22, data.count <= 2 * 1024 * 1024 * 1024 else { throw fail() }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try number(i, 4) == 0x06054b50, i + 22 + Int(try number(i + 20, 2)) == data.count { end = i; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else { throw fail() }
        let count = Int(try number(end + 10, 2)), offset = Int(try number(end + 16, 4)), size = Int(try number(end + 12, 4))
        guard count > 0, count < 65_535, try number(end + 8, 2) == UInt64(count), offset + size == end else { throw fail() }
        var cursor = offset, total: UInt64 = 0, seen = Set<String>(), spans: [(Int, Int)] = []
        for _ in 0..<count {
            guard try number(cursor, 4) == 0x02014b50 else { throw fail() }
            let flags = try number(cursor + 8, 2), method = try number(cursor + 10, 2)
            let compressed = Int(try number(cursor + 20, 4)), expanded = try number(cursor + 24, 4)
            let nameCount = Int(try number(cursor + 28, 2)), extra = Int(try number(cursor + 30, 2)), comment = Int(try number(cursor + 32, 2))
            let local = Int(try number(cursor + 42, 4)), next = cursor + 46 + nameCount + extra + comment
            guard flags & 1 == 0, [0, 8].contains(method), expanded != 0xffffffff, compressed != 0xffffffff,
                  nameCount > 0, nameCount <= 4096, next <= end else { throw fail() }
            let nameData = data[(cursor + 46)..<(cursor + 46 + nameCount)]
            guard let name = String(data: nameData, encoding: .utf8), !name.hasPrefix("/"), !name.contains("\\"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw fail() }
            let components = name.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.contains("..") else { throw fail() }
            let canonical = components.filter { $0 != "." }.joined(separator: "/")
            guard !canonical.isEmpty, seen.insert(canonical).inserted else { throw fail() }
            total += expanded
            guard total <= 8 * 1024 * 1024 * 1024, local >= 0, local < offset,
                  try number(local, 4) == 0x04034b50, try number(local + 8, 2) == method,
                  try number(local + 6, 2) == flags else { throw fail() }
            let localName = Int(try number(local + 26, 2)), localExtra = Int(try number(local + 28, 2))
            let start = local + 30 + localName + localExtra, stop = start + compressed
            guard localName == nameCount, start <= offset, stop <= offset,
                  data[(local + 30)..<(local + 30 + localName)].elementsEqual(nameData) else { throw fail() }
            spans.append((local, stop)); cursor = next
        }
        guard cursor == end else { throw fail() }
        let sorted = spans.sorted { $0.0 < $1.0 }
        for i in sorted.indices.dropFirst() where sorted[i].0 < sorted[i - 1].1 { throw fail() }
        return Int64(total)
    }
}
