import CommonCrypto
import CryptoKit
import Foundation

public enum AuthCryptoError: Error, Equatable, Sendable {
    case passwordTooShort
    case notABackup
    case corrupted
    /// Wrong password or tampered file; GCM cannot tell the two apart.
    case decryptionFailed
    case keyDerivationFailed
}

/// Byte-compatible with YunX: Base64(magic + salt(16) + iv(12) + ciphertext + tag(16)),
/// AES-256-GCM under PBKDF2-HMAC-SHA256. Writes V2 only; V1 is read so old backups still restore.
public enum AuthCrypto {
    private static let magicV1 = Data("YUNX_AUTH_V1".utf8)
    private static let magicV2 = Data("YUNX_AUTH_V2".utf8)
    private static let iterationsV1: UInt32 = 10_000
    private static let iterationsV2: UInt32 = 210_000
    private static let saltSize = 16
    private static let ivSize = 12
    private static let tagSize = 16

    public static func encrypt(_ plain: String, password: String) throws -> String {
        guard password.utf16.count >= 8 else { throw AuthCryptoError.passwordTooShort }
        let salt = randomBytes(saltSize)
        let key = try deriveKey(password: password, salt: salt, iterations: iterationsV2)
        let sealed = try AES.GCM.seal(Data(plain.utf8), using: key)
        var payload = magicV2
        payload.append(salt)
        payload.append(contentsOf: sealed.nonce)
        payload.append(sealed.ciphertext)
        payload.append(sealed.tag)
        return payload.base64EncodedString()
    }

    public static func decrypt(_ content: String, password: String) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = Data(base64Encoded: trimmed) else { throw AuthCryptoError.notABackup }
        let magic: Data
        let iterations: UInt32
        if payload.starts(with: magicV2) {
            (magic, iterations) = (magicV2, iterationsV2)
        } else if payload.starts(with: magicV1) {
            (magic, iterations) = (magicV1, iterationsV1)
        } else {
            throw AuthCryptoError.notABackup
        }
        guard payload.count >= magic.count + saltSize + ivSize + tagSize else { throw AuthCryptoError.corrupted }
        let bytes = Data(payload)
        let saltEnd = magic.count + saltSize
        let ivEnd = saltEnd + ivSize
        let tagStart = bytes.count - tagSize
        let key = try deriveKey(password: password, salt: bytes[magic.count..<saltEnd], iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: bytes[saltEnd..<ivEnd]), ciphertext: bytes[ivEnd..<tagStart], tag: bytes[tagStart...])
            let plain = try AES.GCM.open(box, using: key)
            guard let text = String(data: plain, encoding: .utf8) else { throw AuthCryptoError.corrupted }
            return text
        } catch let error as AuthCryptoError {
            throw error
        } catch {
            throw AuthCryptoError.decryptionFailed
        }
    }

    public static func isEncrypted(_ content: String) -> Bool {
        guard let payload = Data(base64Encoded: content.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return payload.starts(with: magicV1) || payload.starts(with: magicV2)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array(salt)
        var derived = [UInt8](repeating: 0, count: kCCKeySizeAES256)
        let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            passwordBuffer.withMemoryRebound(to: CChar.self) { passwordChars in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passwordChars.baseAddress, passwordChars.count, saltBytes, saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw AuthCryptoError.keyDerivationFailed }
        defer { derived.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return SymmetricKey(data: derived)
    }
}
