import Foundation

enum FanModeReader {
    static func manual(mode: Double?, hasModeKey: Bool, forceBits: Double?, hasForceKey: Bool, fan: Int) -> Bool? {
        var evidence: [Bool?] = []
        if hasModeKey {
            switch mode {
            case 1: evidence.append(true)
            case 0, 3: evidence.append(false)
            default: evidence.append(nil)
            }
        }
        if hasForceKey {
            if let bits = forceBits, bits.isFinite, bits >= 0, bits <= 65535, bits.rounded() == bits,
               (0..<16).contains(fan) {
                evidence.append(Int(bits) & (1 << fan) != 0)
            } else { evidence.append(nil) }
        }
        if evidence.contains(where: { $0 == true }) { return true }
        guard !evidence.isEmpty, evidence.allSatisfy({ $0 == false }) else { return nil }
        return false
    }
}
