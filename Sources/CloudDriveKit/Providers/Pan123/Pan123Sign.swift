// Ported from YunX-Desktop (MIT): Pan123Api.makeSign and crc32Hex.
import Foundation

enum Pan123Sign {
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB88320 : value >> 1 }
        return value
    }

    /// Standard CRC-32 as lowercase hex without zero padding, like java.lang.Long.toHexString.
    static func crc32Hex(_ text: String) -> String {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in text.utf8 { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return String(crc ^ 0xFFFFFFFF, radix: 16)
    }

    /// `auth-key` and `auth-value` headers. `path` includes any /b prefix, with no host or query.
    /// The sign always uses OS web and version 3, whatever the platform headers say.
    static func make(path: String, timestamp: Int64, random: Int) -> (key: String, value: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let shifted = Date(timeIntervalSince1970: TimeInterval(timestamp + Pan123Constants.signOffsetSeconds))
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: shifted)
        let minute = String(format: "%04d%02d%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        let substituted = String(minute.compactMap { char in
            char.wholeNumberValue.map { Pan123Constants.signTable[$0] }
        })
        let authKey = crc32Hex(substituted)
        let data = "\(timestamp)|\(random)|\(path)|\(Pan123Constants.signOS)|\(Pan123Constants.signVersion)|\(authKey)"
        return (authKey, "\(timestamp)-\(random)-\(crc32Hex(data))")
    }
}
