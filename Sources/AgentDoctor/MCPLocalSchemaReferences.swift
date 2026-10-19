import Foundation

/// Conservative document-local JSON Pointer check. Does not fetch, expand references or rewrite schemas.
enum MCPLocalSchemaReferences {
    static func unresolvedCount(in schema: [String: Any]) -> Int? {
        let maps = ["$defs", "definitions", "properties", "patternProperties", "dependentSchemas", "dependencies"]
        let arrays = ["allOf", "anyOf", "oneOf", "prefixItems"]
        let singles = ["additionalProperties", "additionalItems", "contains", "contentSchema", "else", "if", "items", "not", "propertyNames", "then", "unevaluatedProperties", "unevaluatedItems"]
        var references: [String] = [], visited = 0, skipped = false
        func walk(_ value: Any, depth: Int) {
            guard !skipped else { return }
            visited += 1
            guard visited <= 4096, depth <= 64 else { skipped = true; return }
            guard let node = value as? [String: Any] else { return }
            // Resource identifiers change the base of fragment resolution. Defer those documents.
            guard node["$id"] == nil, node["id"] == nil else { skipped = true; return }
            if let ref = node["$ref"] as? String {
                guard references.count < 128, ref.utf8.count <= 4096 else { skipped = true; return }
                references.append(ref)
            }
            for key in maps {
                if let children = node[key] as? [String: Any] {
                    for child in children.values { walk(child, depth: depth + 1) }
                }
            }
            for key in arrays {
                if let children = node[key] as? [Any] {
                    for child in children { walk(child, depth: depth + 1) }
                }
            }
            for key in singles {
                guard let child = node[key] else { continue }
                if key == "items", let children = child as? [Any] {
                    for child in children { walk(child, depth: depth + 1) }
                } else { walk(child, depth: depth + 1) }
            }
        }
        walk(schema, depth: 0)
        guard !skipped else { return nil }
        return references.reduce(0) { count, ref in
            guard ref.hasPrefix("#"), let pointer = String(ref.dropFirst()).removingPercentEncoding,
                  pointer.isEmpty || pointer.hasPrefix("/"), let tokens = tokens(pointer) else { return count }
            var target: Any = schema
            for token in tokens {
                // Swift String equality normalizes Unicode; JSON Pointer member matching must not.
                if let object = target as? [String: Any], let index = object.index(forKey: token),
                   object[index].key.utf8.elementsEqual(token.utf8) { target = object[index].value }
                else if let array = target as? [Any],
                        token == "0" || token.first.map({ ("1"..."9").contains(String($0)) }) == true,
                        token.utf8.allSatisfy({ (48...57).contains($0) }),
                        let index = Int(token), index < array.count { target = array[index] }
                else { return count + 1 }
            }
            return count
        }
    }

    private static func tokens(_ pointer: String) -> [String]? {
        if pointer.isEmpty { return [] }
        let raw = pointer.dropFirst().components(separatedBy: "/")
        guard raw.count <= 64 else { return nil }
        var result: [String] = []
        for token in raw {
            let chars = Array(token)
            var i = 0
            while i < chars.count {
                if chars[i] == "~" {
                    guard i + 1 < chars.count, chars[i + 1] == "0" || chars[i + 1] == "1" else { return nil }
                    i += 1
                }
                i += 1
            }
            result.append(token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~"))
        }
        return result
    }
}
