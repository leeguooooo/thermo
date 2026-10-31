// Ported from YunX-Desktop (AGPL-3.0): ILanzouApi.aesHex.
import CommonCrypto
import Foundation

enum ILanzouCrypto {
    /// AES/ECB/PKCS5Padding with the fixed site key, as lowercase hex. The site expects ECB.
    static func aesHex(_ plain: String) -> String {
        let key = Array(ILanzouConstants.aesKey.utf8)
        let input = Array(plain.utf8)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                             key, key.count, nil, input, input.count, &output, output.count, &written)
        precondition(status == kCCSuccess, "AES failed")
        return output.prefix(written).map { String(format: "%02x", $0) }.joined()
    }
}
