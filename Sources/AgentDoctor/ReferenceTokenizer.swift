import Foundation
import CryptoKit
@_implementationOnly import CTokenData

public enum TextEncoding: String, Codable, CaseIterable, Sendable {
    case heuristic
    case cl100k = "cl100k_base"
    case o200k = "o200k_base"
}

/// Ordinary text only: control-token strings stay literal. No model mapping,
/// prompt framing, image accounting, Python runtime or network requests.
final class ReferenceTokenizer: @unchecked Sendable {
    static let engine = "thermo-bpe-v1/tiktoken-0.14.0/ICU/ordinary"
    enum Failure: String, Error { case vocabulary, pattern, inputLimit = "input_limit", pieceLimit = "piece_limit", unmatchedText = "unmatched_text" }
    let ranks: [ArraySlice<UInt8>: UInt32]
    let regex: NSRegularExpression
    let longest: Int
    static let cl100k = Result { try ReferenceTokenizer(.cl100k) }
    static let o200k = Result { try ReferenceTokenizer(.o200k) }

    init(_ encoding: TextEncoding) throws {
        let code: Int32 = encoding == .cl100k ? 0 : 1
        guard encoding != .heuristic, let pointer = thermo_token_data(code),
              let compressed = Data(base64Encoded: String(cString: pointer)) else { throw Failure.vocabulary }
        var length = Int(thermo_token_uncompressed_size(code))
        guard (1...8_388_608).contains(length) else { throw Failure.vocabulary }
        var data = Data(count: length)
        let result = data.withUnsafeMutableBytes { output in
            compressed.withUnsafeBytes { input in
                thermo_token_inflate(input.bindMemory(to: UInt8.self).baseAddress, compressed.count,
                                     output.bindMemory(to: UInt8.self).baseAddress, &length)
            }
        }
        guard result == 0, length == data.count,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == (code == 0 ? TokenVocabulary.cl100kHash : TokenVocabulary.o200kHash) else { throw Failure.vocabulary }
        let bytes = [UInt8](data)
        guard Array(bytes.prefix(4)) == Array("TTB1".utf8) else { throw Failure.vocabulary }
        func integer(_ index: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | (Int(bytes[index + $1]) << (8 * $1)) }
        }
        let count = integer(4, 4)
        guard count == (code == 0 ? 100_256 : 199_998) else { throw Failure.vocabulary }
        var dictionary: [ArraySlice<UInt8>: UInt32] = [:]
        dictionary.reserveCapacity(count)
        var offset = 8, longest = 0
        for _ in 0..<count {
            guard offset + 6 <= bytes.count else { throw Failure.vocabulary }
            let rank = integer(offset, 4), size = integer(offset + 4, 2)
            offset += 6
            guard size > 0, offset + size <= bytes.count else { throw Failure.vocabulary }
            dictionary[bytes[offset..<(offset + size)]] = UInt32(rank)
            longest = max(longest, size); offset += size
        }
        guard offset == bytes.count, dictionary.count == count,
              (0...255).allSatisfy({ dictionary[ArraySlice([UInt8($0)])] != nil }) else { throw Failure.vocabulary }
        ranks = dictionary; self.longest = longest
        regex = try NSRegularExpression(pattern: code == 0 ? TokenVocabulary.cl100kPattern : TokenVocabulary.o200kPattern)
    }

    static func measure(_ text: String, encoding: TextEncoding) -> (count: Int?, error: String?) {
        guard encoding != .heuristic else { return (nil, "heuristic_mode") }
        do {
            let tokenizer = try (encoding == .cl100k ? cl100k : o200k).get()
            return (try tokenizer.tokens(text).count, nil)
        } catch let error as Failure { return (nil, error.rawValue) }
        catch { return (nil, "tokenizer_unavailable") }
    }

    func tokens(_ text: String) throws -> [UInt32] {
        guard text.utf8.count <= 1_048_576 else { throw Failure.inputLimit }
        let source = text as NSString
        var end = 0
        var output: [UInt32] = []
        var failure: Error?
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, stop in
            guard let match, match.range.location == end else { failure = Failure.unmatchedText; stop.pointee = true; return }
            end = match.range.location + match.range.length
            do { output += try self.piece([UInt8](source.substring(with: match.range).utf8)) }
            catch { failure = error; stop.pointee = true }
        }
        if let failure { throw failure }
        guard end == source.length else { throw Failure.unmatchedText }
        return output
    }

    struct Edge {
        var rank: UInt32
        var left: Int
        var right: Int
        var leftVersion: Int
        var rightVersion: Int
        func precedes(_ other: Edge) -> Bool { rank == other.rank ? left < other.left : rank < other.rank }
    }
    struct Heap {
        var values: [Edge] = []
        mutating func push(_ edge: Edge) {
            values.append(edge)
            var index = values.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard values[index].precedes(values[parent]) else { break }
                values.swapAt(index, parent); index = parent
            }
        }
        mutating func pop() -> Edge? {
            guard !values.isEmpty else { return nil }
            let first = values[0], last = values.removeLast()
            if !values.isEmpty {
                values[0] = last
                var index = 0
                while index * 2 + 1 < values.count {
                    var child = index * 2 + 1
                    if child + 1 < values.count, values[child + 1].precedes(values[child]) { child += 1 }
                    guard values[child].precedes(values[index]) else { break }
                    values.swapAt(child, index); index = child
                }
            }
            return first
        }
    }

    func piece(_ bytes: [UInt8]) throws -> [UInt32] {
        if bytes.isEmpty { return [] }
        if let rank = ranks[bytes[...]] { return [rank] }
        guard bytes.count <= 65_536 else { throw Failure.pieceLimit }
        let count = bytes.count
        var next = (1...count).map { $0 == count ? -1 : $0 }
        var previous = (-1..<(count - 1)).map { $0 }
        var end = (1...count).map { $0 }
        var version = [Int](repeating: 0, count: count)
        var alive = [Bool](repeating: true, count: count)
        var heap = Heap()
        func edge(_ left: Int, _ right: Int) -> Edge? {
            guard left >= 0, right >= 0, end[right] - left <= longest,
                  let rank = ranks[bytes[left..<end[right]]] else { return nil }
            return Edge(rank: rank, left: left, right: right, leftVersion: version[left], rightVersion: version[right])
        }
        for left in 0..<(count - 1) { if let value = edge(left, left + 1) { heap.push(value) } }
        while let value = heap.pop() {
            let left = value.left, right = value.right
            guard alive[left], alive[right], next[left] == right,
                  version[left] == value.leftVersion, version[right] == value.rightVersion else { continue }
            end[left] = end[right]; next[left] = next[right]
            if next[right] >= 0 { previous[next[right]] = left }
            alive[right] = false; version[left] += 1; version[right] += 1
            if let value = edge(previous[left], left) { heap.push(value) }
            if let value = edge(left, next[left]) { heap.push(value) }
        }
        var output: [UInt32] = [], index = 0
        while index >= 0 {
            guard let rank = ranks[bytes[index..<end[index]]] else { throw Failure.vocabulary }
            output.append(rank); index = next[index]
        }
        return output
    }
}
