import Foundation

/// A read can contain several keys or only part of an escape sequence.
struct TerminalInput {
    private var bytes: [UInt8] = []
    var awaitingEscape: Bool { bytes.first == 0x1b }

    mutating func append(_ incoming: [UInt8]) { bytes.append(contentsOf: incoming) }

    mutating func next(expireEscape: Bool = false) -> String? {
        guard let first = bytes.first else { return nil }
        guard first == 0x1b else {
            bytes.removeFirst()
            return String(decoding: [first], as: UTF8.self)
        }
        guard bytes.count > 1 else {
            if expireEscape { bytes.removeFirst(); return "\u{1B}" }
            return nil
        }
        guard bytes[1] == 0x5b || bytes[1] == 0x4f else {
            bytes.removeFirst()
            return "\u{1B}"
        }
        if let end = bytes.indices.dropFirst(2).first(where: { (0x40...0x7e).contains(bytes[$0]) }) {
            let sequence = Array(bytes.prefix(end + 1))
            bytes.removeFirst(end + 1)
            // SS3 application-cursor arrows have the same meaning as CSI arrows.
            if sequence.count == 3, sequence[1] == 0x4f, (0x41...0x44).contains(sequence[2]) {
                return String(decoding: [0x1b, 0x5b, sequence[2]], as: UTF8.self)
            }
            return String(decoding: sequence, as: UTF8.self)
        }
        if expireEscape || bytes.count > 64 { bytes.removeAll() }
        return nil
    }
}
