// Ported from YunX-Desktop (AGPL-3.0): the signing and share-body encryption in data/network/C139Api.kt.
import CommonCrypto
import CryptoKit
import Foundation

/// The two transforms 139 asks for. Both are fixed by the service, so they live apart from the requests and can be
/// checked against known answers.
enum C139Crypto {
    /// `encodeURIComponent` as YunX built it: java.net.URLEncoder, then `+` to `%20` and `! ' ( ) *` restored.
    /// Unlike the JavaScript original it still escapes `~` (as `%7E`).
    static func encodeURIComponent(_ text: String) -> String {
        HTTPClient.encodeQueryValue(text)
            .replacingOccurrences(of: "+", with: "%20")
            .replacingOccurrences(of: "%21", with: "!")
            .replacingOccurrences(of: "%27", with: "'")
            .replacingOccurrences(of: "%28", with: "(")
            .replacingOccurrences(of: "%29", with: ")")
            .replacingOccurrences(of: "%2A", with: "*")
    }

    /// Lowercase hex MD5.
    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The characters of the encoded body in ascending order, base64, MD5, joined with MD5(ts:rand), MD5, upper case.
    /// Sorting makes the key order of the body irrelevant, but the body must be the plain JSON that is sent.
    static func calSign(bodyJSON: String, timestamp: String, nonce: String) -> String {
        let sorted = encodeURIComponent(bodyJSON).utf8.sorted()
        let base64 = Data(sorted).base64EncodedString()
        return md5(md5(base64) + md5("\(timestamp):\(nonce)")).uppercased()
    }

    /// `base64(IV(16) + AES-128-CBC/PKCS7(plaintext))`.
    static func encryptBody(_ plaintext: String, iv: [UInt8]) throws -> String {
        precondition(iv.count == kCCBlockSizeAES128)
        let output = try crypt(CCOperation(kCCEncrypt), Array(plaintext.utf8), iv: iv)
        return Data(iv + output).base64EncodedString()
    }

    /// Reverses `encryptBody`. A gzip result (1f 8b) is inflated, as alist's YunCrypto does.
    static func decryptBody(_ base64: String) throws -> String {
        guard let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count > kCCBlockSizeAES128 else { throw DriveError.api(message: "响应解密失败") }
        let bytes = [UInt8](raw)
        var plain = try crypt(CCOperation(kCCDecrypt), Array(bytes[16...]), iv: Array(bytes[..<16]))
        if plain.count > 2, plain[0] == 0x1f, plain[1] == 0x8b {
            guard let inflated = gunzip(Data(plain)) else { throw DriveError.api(message: "响应解压失败") }
            plain = [UInt8](inflated)
        }
        guard let text = String(bytes: plain, encoding: .utf8) else { throw DriveError.api(message: "响应解密失败") }
        return text
    }

    private static func crypt(_ operation: CCOperation, _ input: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        let key = Array(C139Constants.shareAESKey.utf8)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, input, input.count, &output, output.count, &written)
        guard status == kCCSuccess else { throw DriveError.api(message: "响应解密失败") }
        return Array(output[..<written])
    }

    /// RFC 1952 header and trailer around a raw deflate stream, which Apple's `.zlib` algorithm decodes.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            guard let end = bytes[min(offset, bytes.count)...].firstIndex(of: 0) else { return nil }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { return nil }
        let deflated = Data(bytes[offset..<(bytes.count - 8)])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }
}
