import Foundation

/// The forgiving reads of org.json's `opt*`: drives vary field types, so strict decoding would fail.
struct LenientJSON {
    let object: [String: Any]

    init(_ object: [String: Any]) { self.object = object }

    init?(data: Data) {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        object = parsed
    }

    func has(_ key: String) -> Bool { object[key] != nil && !(object[key] is NSNull) }

    func string(_ key: String) -> String {
        switch object[key] {
        case let value as String: return value
        case let value as NSNumber:
            return isBool(value) ? (value.boolValue ? "true" : "false") : value.stringValue
        default: return ""
        }
    }

    func int(_ key: String) -> Int { Int(clamping: int64(key)) }

    func int64(_ key: String) -> Int64 {
        switch object[key] {
        case let value as NSNumber: return isBool(value) ? 0 : value.int64Value
        case let value as String: return Int64(value) ?? 0
        default: return 0
        }
    }

    func bool(_ key: String) -> Bool {
        switch object[key] {
        case let value as NSNumber: return isBool(value) && value.boolValue
        case let value as String: return value.lowercased() == "true"
        default: return false
        }
    }

    func child(_ key: String) -> LenientJSON? { (object[key] as? [String: Any]).map(LenientJSON.init) }
    func array(_ key: String) -> [Any]? { object[key] as? [Any] }
    func objects(_ key: String) -> [LenientJSON] { (array(key) ?? []).compactMap { ($0 as? [String: Any]).map(LenientJSON.init) } }

    private func isBool(_ value: NSNumber) -> Bool { CFGetTypeID(value) == CFBooleanGetTypeID() }
}
