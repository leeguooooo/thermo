import CryptoKit
import Foundation

/// SHA-256 of a part, compared on resume and again during the merge.
enum PartHash {
    private static let bufferSize = 1 << 20

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(of file: URL, length: Int64) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var digest = SHA256()
        var left = length
        while left > 0 {
            guard let data = try input.read(upToCount: Int(min(left, Int64(bufferSize)))), !data.isEmpty else {
                throw DownloadError.sizeMismatch(expected: length, actual: length - left)
            }
            digest.update(data: data)
            left -= Int64(data.count)
        }
        return hex(digest.finalize())
    }
}
