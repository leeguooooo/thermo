import Foundation

/// Inspect ZIP32/ZIP64 before asking the system's bsdtar to extract it. All 64-bit
/// values are bounded before conversion, arithmetic, allocation or file access.
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
        var entries = try number(end + 10, 2), directoryOffset = try number(end + 16, 4), directorySize = try number(end + 12, 4)
        var directoryEnd = end
        if end >= 20, try number(end - 20, 4) == 0x07064b50 {
            let locator = end - 20, zip64 = try number(locator + 8, 8)
            guard locator >= 56, try number(locator + 4, 4) == 0, try number(locator + 16, 4) == 1, zip64 <= UInt64(locator - 56) else { throw fail() }
            let record = Int(zip64), recordSize = try number(record + 4, 8)
            guard try number(record, 4) == 0x06064b50, recordSize >= 44, recordSize <= UInt64(locator - record - 12),
                  record + 12 + Int(recordSize) == locator, try number(record + 16, 4) == 0, try number(record + 20, 4) == 0 else { throw fail() }
            let n = try number(record + 32, 8), s = try number(record + 40, 8), o = try number(record + 48, 8)
            guard try number(record + 24, 8) == n, entries == 0xffff || entries == n,
                  directoryOffset == 0xffffffff || directoryOffset == o, directorySize == 0xffffffff || directorySize == s else { throw fail() }
            entries = n; directorySize = s; directoryOffset = o; directoryEnd = record
        } else {
            guard entries != 0xffff, directoryOffset != 0xffffffff, directorySize != 0xffffffff else { throw fail() }
        }
        let diskEntries = try number(end + 8, 2)
        guard entries > 0, entries <= 100_000, diskEntries == entries || (directoryEnd != end && diskEntries == 0xffff),
              directoryOffset <= UInt64(directoryEnd), directorySize == UInt64(directoryEnd) - directoryOffset else { throw fail() }
        let count = Int(entries), offset = Int(directoryOffset)
        var cursor = offset, total: UInt64 = 0, seen = Set<String>(), spans: [(Int, Int)] = []
        for _ in 0..<count {
            guard try number(cursor, 4) == 0x02014b50 else { throw fail() }
            let flags = try number(cursor + 8, 2), method = try number(cursor + 10, 2)
            var compressedBytes = try number(cursor + 20, 4), expanded = try number(cursor + 24, 4), localOffset = try number(cursor + 42, 4)
            let nameCount = Int(try number(cursor + 28, 2)), extra = Int(try number(cursor + 30, 2)), comment = Int(try number(cursor + 32, 2))
            let next = cursor + 46 + nameCount + extra + comment
            guard flags & 0x2041 == 0, [0, 8].contains(method),
                  nameCount > 0, nameCount <= 4096, next <= directoryEnd else { throw fail() }
            let extraStart = cursor + 46 + nameCount, extraEnd = extraStart + extra
            var at = extraStart, wide: Range<Int>?
            while at < extraEnd {
                guard at + 4 <= extraEnd else { throw fail() }
                let tag = try number(at, 2), length = Int(try number(at + 2, 2))
                guard at + 4 + length <= extraEnd else { throw fail() }
                if tag == 1 { guard wide == nil else { throw fail() }; wide = (at + 4)..<(at + 4 + length) }
                at += 4 + length
            }
            var wideCursor = wide?.lowerBound ?? 0
            func extended(_ size: Int) throws -> UInt64 {
                guard let wide, wideCursor <= wide.upperBound - size else { throw fail() }
                defer { wideCursor += size }
                return try number(wideCursor, size)
            }
            if expanded == 0xffffffff { expanded = try extended(8) }
            if compressedBytes == 0xffffffff { compressedBytes = try extended(8) }
            if localOffset == 0xffffffff { localOffset = try extended(8) }
            let disk = try number(cursor + 34, 2)
            let actualDisk = disk == 0xffff ? try extended(4) : disk
            guard actualDisk == 0, compressedBytes <= UInt64(data.count),
                  localOffset < UInt64(offset), expanded <= UInt64(8 * 1024 * 1024 * 1024) - total else { throw fail() }
            let compressed = Int(compressedBytes), local = Int(localOffset)
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
        guard cursor == directoryEnd else { throw fail() }
        let sorted = spans.sorted { $0.0 < $1.0 }
        for i in sorted.indices.dropFirst() where sorted[i].0 < sorted[i - 1].1 { throw fail() }
        return Int64(total)
    }
}
