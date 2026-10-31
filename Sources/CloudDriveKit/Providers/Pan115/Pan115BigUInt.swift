// Support for Pan115Crypto: the 115 download protocol needs `modPow` on a 1024-bit modulus, which
// Foundation and CryptoKit do not offer (the server "encrypts" with its private key, so the client
// has to apply the public exponent to recover data, which SecKey cannot do).
import Foundation

/// Minimal unsigned big integer: little-endian 32-bit limbs, just enough for `modPow`.
struct Pan115BigUInt: Equatable {
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) {
        self.limbs = limbs
        trim()
    }

    init(_ value: UInt32) { self.init(limbs: [value]) }

    /// Big-endian bytes.
    init(bytes: [UInt8]) {
        var limbs = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (index, byte) in bytes.reversed().enumerated() {
            limbs[index / 4] |= UInt32(byte) << UInt32(8 * (index % 4))
        }
        self.init(limbs: limbs)
    }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes: bytes)
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    /// Big-endian, left-padded with zeros (or truncated from the left) to `length`.
    func bytes(length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        for index in 0..<length {
            let limb = index / 4
            guard limb < limbs.count else { break }
            out[length - 1 - index] = UInt8(truncatingIfNeeded: limbs[limb] >> UInt32(8 * (index % 4)))
        }
        return out
    }

    private mutating func trim() {
        while limbs.last == 0 { limbs.removeLast() }
    }

    private func bit(_ index: Int) -> Bool {
        let limb = index / 32
        return limb < limbs.count && (limbs[limb] >> UInt32(index % 32)) & 1 == 1
    }

    static func < (lhs: Pan115BigUInt, rhs: Pan115BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    static func * (lhs: Pan115BigUInt, rhs: Pan115BigUInt) -> Pan115BigUInt {
        if lhs.isZero || rhs.isZero { return Pan115BigUInt(limbs: []) }
        var result = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for (i, a) in lhs.limbs.enumerated() {
            var carry: UInt64 = 0
            for (j, b) in rhs.limbs.enumerated() {
                let total = UInt64(a) * UInt64(b) + UInt64(result[i + j]) + carry
                result[i + j] = UInt32(truncatingIfNeeded: total)
                carry = total >> 32
            }
            result[i + rhs.limbs.count] = UInt32(truncatingIfNeeded: carry)
        }
        return Pan115BigUInt(limbs: result)
    }

    /// `self - other`, requires `other <= self`.
    private mutating func subtract(_ other: Pan115BigUInt) {
        var borrow: Int64 = 0
        for index in 0..<limbs.count {
            var value = Int64(limbs[index]) - borrow - (index < other.limbs.count ? Int64(other.limbs[index]) : 0)
            if value < 0 {
                value += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            limbs[index] = UInt32(value)
        }
        trim()
    }

    private mutating func shiftLeftOne(adding low: Bool) {
        var carry: UInt32 = low ? 1 : 0
        for index in 0..<limbs.count {
            let next = limbs[index] >> 31
            limbs[index] = (limbs[index] << 1) | carry
            carry = next
        }
        if carry != 0 { limbs.append(carry) }
        if limbs.isEmpty, low { limbs.append(1) }
    }

    /// Binary long division remainder. Slow but dependency free, and 115 blocks are only 128 bytes.
    func remainder(dividingBy modulus: Pan115BigUInt) -> Pan115BigUInt {
        precondition(!modulus.isZero)
        var remainder = Pan115BigUInt(limbs: [])
        for index in stride(from: bitWidth - 1, through: 0, by: -1) {
            remainder.shiftLeftOne(adding: bit(index))
            if !(remainder < modulus) { remainder.subtract(modulus) }
        }
        return remainder
    }

    func modPow(_ exponent: Pan115BigUInt, modulus: Pan115BigUInt) -> Pan115BigUInt {
        let base = remainder(dividingBy: modulus)
        var result = Pan115BigUInt(1).remainder(dividingBy: modulus)
        for index in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            result = (result * result).remainder(dividingBy: modulus)
            if exponent.bit(index) { result = (result * base).remainder(dividingBy: modulus) }
        }
        return result
    }
}
