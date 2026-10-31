// Ported from YunX-Desktop (MIT): data/network/Pan115Crypto.kt.
// The request and response wrapping of 115's desktop download endpoint (proapi.115.com/app/chrome/downurl).
import Foundation

/// Seam so tests can run the download flow without the real server's private key.
protocol Pan115Cipher: Sendable {
    func newKey() -> [UInt8]
    func encode(_ payload: String, key: [UInt8]) throws -> String
    func decode(_ data: String, key: [UInt8]) throws -> String
}

/// Request: `base64(RSA(key16 || xorWrapped(payload)))` with 1024-bit RSA, exponent 65537, 117-byte blocks.
/// Response: `base64(RSA blocks)`; the first 16 bytes of the result are the server salt, and the rest is
/// unwrapped with salt and our key. The server applies its private key, so the public exponent recovers it.
struct Pan115Crypto: Pan115Cipher {
    /// 144-byte XOR key table; byte for byte the same as the source. Check before changing.
    static let keyTable: [UInt8] = [
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a,
        0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4,
        0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86,
        0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd,
        0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e,
        0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34,
        0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59,
        0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77,
        0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b,
        0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5,
    ]

    static let longKey: [UInt8] = [0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46]

    /// The 115 desktop client's built-in public key modulus (1024 bits).
    static let modulus = Pan115BigUInt(hex:
        "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021"
        + "36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633"
        + "8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1"
        + "0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683")!
    static let exponent = Pan115BigUInt(0x10001)

    static let rsaEncodeBlock = 117
    static let rsaBlock = 128

    func newKey() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    func encode(_ payload: String, key: [UInt8]) throws -> String {
        guard key.count == 16 else { throw DriveError.api(message: "115 下载协议要求 16 字节 key") }
        var body = Array(payload.utf8)
        Self.symmetricEncode(&body, key: key)
        return Data(Self.rsaEncrypt(key + body)).base64EncodedString()
    }

    func decode(_ data: String, key: [UInt8]) throws -> String {
        guard key.count == 16 else { throw DriveError.api(message: "115 下载协议要求 16 字节 key") }
        // Java's MIME decoder skips characters outside the alphabet; this option skips line breaks too.
        guard let raw = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else {
            throw DriveError.api(message: "115 下载响应无法解码")
        }
        return try Self.unwrap(try Self.rsaDecrypt([UInt8](raw)), key: key)
    }

    /// The part of `decode` after the RSA step.
    static func unwrap(_ decrypted: [UInt8], key: [UInt8]) throws -> String {
        guard decrypted.count > 16 else { throw DriveError.api(message: "115 下载响应长度异常") }
        let salt = Array(decrypted[0..<16])
        var body = Array(decrypted[16...])
        symmetricDecode(&body, key: key, salt: salt)
        return String(decoding: body, as: UTF8.self)
    }

    /// XOR, reverse, then XOR with the long key.
    static func symmetricEncode(_ data: inout [UInt8], key: [UInt8]) {
        xorTransform(&data, key: deriveKey(key, size: 4))
        data.reverse()
        xorTransform(&data, key: longKey)
    }

    /// Un-XOR with a key derived from the server salt, reverse, then XOR with our derived key.
    static func symmetricDecode(_ data: inout [UInt8], key: [UInt8], salt: [UInt8]) {
        xorTransform(&data, key: deriveKey(salt, size: 12))
        data.reverse()
        xorTransform(&data, key: deriveKey(key, size: 4))
    }

    /// out[i] = ((seed[i % seed.count] + table[size * i]) & 0xff) ^ table[size * (size - 1 - i)]
    static func deriveKey(_ seed: [UInt8], size: Int) -> [UInt8] {
        (0..<size).map { i in
            let left = keyTable[size * i]
            let right = keyTable[size * (size - 1 - i)]
            return (seed[i % seed.count] &+ left) ^ right
        }
    }

    /// The first `count % 4` bytes use the key from its start, and the rest are offset by that prefix length.
    static func xorTransform(_ data: inout [UInt8], key: [UInt8]) {
        let offset = data.count % 4
        for i in 0..<offset { data[i] ^= key[i % key.count] }
        for i in offset..<data.count { data[i] ^= key[(i - offset) % key.count] }
    }

    /// PKCS#1 v1.5 style blocks, but the padding is fixed 0xff (as in the source), raised to the public exponent.
    static func rsaEncrypt(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var offset = 0
        while offset < input.count {
            let size = min(rsaEncodeBlock, input.count - offset)
            var block = [UInt8](repeating: 0xff, count: rsaBlock)
            block[0] = 0
            block[1] = 2
            let separator = rsaBlock - size - 1
            block[separator] = 0
            block.replaceSubrange((separator + 1)..<(separator + 1 + size), with: input[offset..<(offset + size)])
            out += Pan115BigUInt(bytes: block).modPow(exponent, modulus: modulus).bytes(length: rsaBlock)
            offset += size
        }
        return out
    }

    static func rsaDecrypt(_ input: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        var offset = 0
        while offset < input.count {
            let size = min(rsaBlock, input.count - offset)
            let plain = Pan115BigUInt(bytes: Array(input[offset..<(offset + size)]))
                .modPow(exponent, modulus: modulus).bytes(length: rsaBlock)
            // 0x00 0x02 <padding> 0x00 <data>: the first 0x00 from index 2 ends the padding.
            guard let separator = plain[2...].firstIndex(of: 0), separator + 1 < plain.count else {
                throw DriveError.api(message: "115 下载响应缺少 RSA 分隔符")
            }
            out += plain[(separator + 1)...]
            offset += size
        }
        return out
    }
}
