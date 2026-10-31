import Foundation

/// Reader matching the `org.json` behaviour YunX's parsers rely on, which `JSONSerialization`
/// cannot give: object key order (Kuaishou takes the first entry holding a photo), text after the
/// root value (inline `window.X = {...};` blocks), and the lenient `opt*` accessors.
enum VideoJSON {
    indirect enum Value: Equatable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case array(VideoJSONArray)
        case object(VideoJSONObject)
    }

    static func parseObject(_ text: String) -> VideoJSONObject? {
        var reader = Reader(bytes: Array(text.utf8))
        guard case .object(let object)? = try? reader.value(depth: 0) else { return nil }
        return object
    }

    private struct Malformed: Error {}

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        private mutating func skipWhitespace() {
            while let byte = peek, byte <= 0x20 { index += 1 }
        }

        mutating func value(depth: Int) throws -> Value {
            guard depth < 512 else { throw Malformed() }
            skipWhitespace()
            switch peek {
            case UInt8(ascii: "{"): return .object(try object(depth: depth))
            case UInt8(ascii: "["): return .array(try array(depth: depth))
            case UInt8(ascii: "\""), UInt8(ascii: "'"): return .string(try string())
            case nil: throw Malformed()
            default: return try bareToken()
            }
        }

        private mutating func object(depth: Int) throws -> VideoJSONObject {
            index += 1
            var object = VideoJSONObject()
            while true {
                skipWhitespace()
                if peek == UInt8(ascii: "}") {
                    index += 1
                    return object
                }
                let key: String
                switch try value(depth: depth + 1) {
                case .string(let text): key = text
                case .int(let number): key = String(number)
                default: throw Malformed()
                }
                skipWhitespace()
                guard peek == UInt8(ascii: ":") else { throw Malformed() }
                index += 1
                object.set(key, try value(depth: depth + 1))
                skipWhitespace()
                switch peek {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "}"): break
                default: throw Malformed()
                }
            }
        }

        private mutating func array(depth: Int) throws -> VideoJSONArray {
            index += 1
            var items: [Value] = []
            while true {
                skipWhitespace()
                if peek == UInt8(ascii: "]") {
                    index += 1
                    return VideoJSONArray(items: items)
                }
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                switch peek {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "]"): break
                default: throw Malformed()
                }
            }
        }

        private mutating func string() throws -> String {
            let quote = bytes[index]
            index += 1
            var out: [UInt8] = []
            while let byte = peek {
                index += 1
                if byte == quote { return String(decoding: out, as: UTF8.self) }
                guard byte == UInt8(ascii: "\\") else {
                    out.append(byte)
                    continue
                }
                guard let escape = peek else { throw Malformed() }
                index += 1
                switch escape {
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "u"): out.append(contentsOf: try unicodeEscape())
                default: out.append(escape)
                }
            }
            throw Malformed()
        }

        private mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let unit = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw Malformed()
            }
            index += 4
            return unit
        }

        private mutating func unicodeEscape() throws -> [UInt8] {
            var scalar = try hex4()
            if (0xD800...0xDBFF).contains(scalar), index + 1 < bytes.count,
               bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                let saved = index
                index += 2
                let low = try hex4()
                if (0xDC00...0xDFFF).contains(low) {
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                } else {
                    index = saved
                }
            }
            return Array(String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8)
        }

        private mutating func bareToken() throws -> Value {
            let start = index
            while let byte = peek, byte > 0x20, !",:]}/\\\"[{;=#".utf8.contains(byte) { index += 1 }
            guard index > start else { throw Malformed() }
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            switch token.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: break
            }
            if let number = Int64(token) { return .int(number) }
            if let first = token.first, first.isNumber || first == "-" || first == ".", let number = Double(token) {
                return .double(number)
            }
            return .string(token)
        }
    }
}

struct VideoJSONObject: Equatable {
    private(set) var keys: [String] = []
    private var values: [String: VideoJSON.Value] = [:]

    mutating func set(_ key: String, _ value: VideoJSON.Value) {
        if values.updateValue(value, forKey: key) == nil { keys.append(key) }
    }

    func isNull(_ key: String) -> Bool {
        guard let value = values[key] else { return true }
        return value == .null
    }

    func optObject(_ key: String) -> VideoJSONObject? {
        if case .object(let object)? = values[key] { return object }
        return nil
    }

    func optArray(_ key: String) -> VideoJSONArray? {
        if case .array(let array)? = values[key] { return array }
        return nil
    }

    /// Missing and JSON null both give the fallback.
    func optString(_ key: String, _ fallback: String = "") -> String {
        values[key].flatMap(VideoJSONArray.string) ?? fallback
    }

    /// `optString` with a literal "null" treated as absent, as YunX's `str` did.
    func str(_ key: String) -> String {
        let text = optString(key)
        return text == "null" ? "" : text
    }

    func optInt(_ key: String, _ fallback: Int = 0) -> Int {
        values[key].flatMap(VideoJSONArray.integer).map(Int.init) ?? fallback
    }

    func optLong(_ key: String, _ fallback: Int64 = 0) -> Int64 {
        values[key].flatMap(VideoJSONArray.integer) ?? fallback
    }

    func optBoolean(_ key: String) -> Bool {
        switch values[key] {
        case .bool(let flag)?: return flag
        case .string(let text)?: return text.lowercased() == "true"
        default: return false
        }
    }
}

struct VideoJSONArray: Equatable {
    var items: [VideoJSON.Value]

    var count: Int { items.count }

    func optObject(_ index: Int) -> VideoJSONObject? {
        guard items.indices.contains(index), case .object(let object) = items[index] else { return nil }
        return object
    }

    func optString(_ index: Int) -> String {
        guard items.indices.contains(index) else { return "" }
        return Self.string(items[index]) ?? ""
    }

    func optInt(_ index: Int, _ fallback: Int = 0) -> Int {
        guard items.indices.contains(index) else { return fallback }
        return Self.integer(items[index]).map(Int.init) ?? fallback
    }

    fileprivate static func string(_ value: VideoJSON.Value) -> String? {
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return String(flag)
        case .null, .array, .object: return nil
        }
    }

    fileprivate static func integer(_ value: VideoJSON.Value) -> Int64? {
        switch value {
        case .int(let number):
            return number
        case .double(let number):
            return Int64(exactly: number.rounded(.towardZero))
        case .string(let text):
            return Int64(text) ?? Double(text).flatMap { Int64(exactly: $0.rounded(.towardZero)) }
        default:
            return nil
        }
    }
}

enum VideoFileName {
    /// Same rules as YunX's `DownloadPathPolicy.sanitizeName`.
    static func sanitize(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let illegal = scalar.value < 0x20 || "\\/:*?\"<>|".unicodeScalars.contains(scalar)
            scalars.append(illegal ? "_" : scalar)
        }
        var cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 120 {
            if let dot = cleaned.lastIndex(of: ".") {
                let ext = String(cleaned[cleaned.index(after: dot)...].prefix(10))
                cleaned = ext.isBlank ? String(cleaned.prefix(120)) : "\(cleaned[..<dot].prefix(100)).\(ext)"
            } else {
                cleaned = String(cleaned.prefix(120))
            }
        }
        return cleaned
    }

    static func base(_ title: String, fallback: @autoclosure () -> String) -> String {
        String(sanitize(title).prefix(80)).ifBlank(fallback())
    }
}
