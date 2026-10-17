import Foundation
import CoreFoundation
import CryptoKit

/// Retains identifiers, timestamps and measurements, never arguments or result text.
struct ToolUsageParser {
    struct Call {
        var host: String
        var kind: String?
        var groupID: String?
        var server: String?
        var name: String?
        var started: Date?
        var ended: Date?
        var startSeen = false
        var endSeen = false
        var isError: Bool?
        var textBytes = 0
        var estimatedTokens = 0
        var nonText = 0
        var referenceTokens: Int?
    }
    struct Usage {
        var date: Date
        var input: Int
        var cached: Int?
        var write: Int?
        var output: Int
    }
    let since: Date
    let until: Date
    var encoding: TextEncoding = .heuristic
    var coverage = ToolUsageCoverage()
    var calls: [String: Call] = [:]
    var usage: [String: (host: String, value: Usage)] = [:]
    let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    let plain = ISO8601DateFormatter()

    func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
    func inWindow(_ date: Date?) -> Bool { date.map { $0 >= since && $0 <= until } ?? false }
    static func label(_ value: String) -> String {
        String(Redact.text(value).unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(200).map(String.init).joined())
    }
    static func identity(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    func milliseconds(_ value: Any?) -> Date? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= 253_402_300_799_000 else { return nil }
        return Date(timeIntervalSince1970: value.doubleValue / 1000)
    }
    static func mcpName(_ name: String) -> (server: String, tool: String)? {
        let name = name.hasPrefix("functions.") ? String(name.dropFirst(10)) : name
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = String(name.dropFirst(5)).components(separatedBy: "__")
        let tool = parts.dropFirst().joined(separator: "__")
        guard parts.count >= 2, !parts[0].isEmpty, !tool.isEmpty else { return nil }
        return (parts[0], tool)
    }
    func classification(_ name: String, input: Any?) -> (String, String?, String)? {
        if let mcp = Self.mcpName(name) { return ("mcp", Self.label(mcp.server), Self.label(mcp.tool)) }
        let name = name.hasPrefix("functions.") ? String(name.dropFirst(10)) : name
        if name == "Skill", let skill = (input as? [String: Any])?["skill"] as? String,
           skill.range(of: #"^[A-Za-z0-9_.:@/-]{1,200}$"#, options: .regularExpression) != nil {
            return ("skill", nil, Self.label(skill))
        }
        return nil
    }
    mutating func start(host: String, session: String, id: String, name: String, input: Any?, time: Date?, nativeMCP: (server: String, tool: String)? = nil) {
        guard id.count <= 512, !id.isEmpty else { coverage.limitReached = true; return }
        let key = host + "|" + session + "|" + id
        if calls[key]?.startSeen == true { coverage.duplicateRecords += 1; return }
        guard calls.count < 100_000 || calls[key] != nil else { coverage.limitReached = true; return }
        var call = calls[key] ?? Call(host: host)
        let mcp = nativeMCP ?? Self.mcpName(name)
        let classification: (String, String?, String)? = mcp.map { ("mcp", Self.label($0.server), Self.label($0.tool)) } ?? classification(name, input: input)
        call.kind = classification?.0; call.server = classification?.1; call.name = classification?.2
        if let classification {
            let normalized = name.hasPrefix("functions.") ? String(name.dropFirst(10)) : name
            let skill = classification.0 == "skill" ? ((input as? [String: Any])?["skill"] as? String ?? "") : ""
            if let mcp {
                // Explicit server/tool fields may themselves contain delimiters.
                // Length framing also gives legacy and native records the same grouping.
                call.groupID = Self.identity(host + "|mcp|" + String(mcp.server.utf8.count) + ":" + mcp.server + String(mcp.tool.utf8.count) + ":" + mcp.tool)
            } else { call.groupID = Self.identity(host + "|" + classification.0 + "|" + normalized + "|" + skill) }
        }
        call.started = time; call.startSeen = true
        if time == nil { coverage.missingTimestamps += 1 }
        calls[key] = call
    }
    /// JSON strings are text as logged, not reinterpreted as arbitrary status prose.
    static func result(_ value: Any?, encoding: TextEncoding = .heuristic) -> (TextFootprint, Int, Bool?) {
        if let text = value as? String {
            if text.first == "{", let data = text.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               object["content"] is [[String: Any]] || object["structuredContent"] != nil { return result(object, encoding: encoding) }
            return (TextFootprint(text, encoding: encoding), 0, nil)
        }
        if let blocks = value as? [[String: Any]] {
            let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            return (TextFootprint(texts.joined(separator: "\n"), encoding: encoding), blocks.filter { $0["type"] as? String != "text" }.count, nil)
        }
        if let object = value as? [String: Any] {
            if let content = object["content"] {
                let measured = result(content, encoding: encoding)
                return (measured.0, measured.1, boolean(object["isError"]))
            }
            if let structured = object["structuredContent"],
               let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys, .fragmentsAllowed]) {
                return (TextFootprint(String(decoding: data, as: UTF8.self), encoding: encoding), 0, boolean(object["isError"]))
            }
        }
        return (TextFootprint("", encoding: encoding), 0, nil)
    }
    mutating func end(host: String, session: String, id: String, value: Any?, error: Bool?, time: Date?) {
        guard id.count <= 512, !id.isEmpty else { coverage.limitReached = true; return }
        let key = host + "|" + session + "|" + id
        if calls[key]?.endSeen == true { coverage.duplicateRecords += 1; return }
        guard calls.count < 100_000 || calls[key] != nil else { coverage.limitReached = true; return }
        var call = calls[key] ?? Call(host: host)
        let measured = call.startSeen && call.kind == nil ? (TextFootprint(""), 0, nil as Bool?) : Self.result(value, encoding: encoding)
        call.ended = time; call.endSeen = true
        if error == true || measured.2 == true { call.isError = true }
        else if error != nil || measured.2 != nil { call.isError = false }
        else { call.isError = nil }
        call.referenceTokens = measured.0.referenceTokens
        call.textBytes = measured.0.bytes; call.estimatedTokens = measured.0.estimatedTokens; call.nonText = measured.1
        if time == nil { coverage.missingTimestamps += 1 }
        calls[key] = call
    }
    mutating func tokens(host: String, session: String, id: String?, object: [String: Any]?, time: Date?) {
        guard let object else { return }
        guard let time else { coverage.unsupportedUsageRecords += 1; return }
        guard inWindow(time) else { return }
        guard let id, !id.isEmpty, id.count <= 512 else { coverage.unsupportedUsageRecords += 1; return }
        func integer(_ key: String) -> Int? {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue < Double(Int.max / 1_000_000),
                  value.doubleValue.rounded() == value.doubleValue else { return nil }
            return value.intValue
        }
        guard let input = integer("input_tokens"), let output = integer("output_tokens") else { coverage.unsupportedUsageRecords += 1; return }
        let value = Usage(date: time, input: input,
                          cached: integer(host == "claude" ? "cache_read_input_tokens" : "cached_input_tokens"),
                          write: integer(host == "claude" ? "cache_creation_input_tokens" : "cache_write_input_tokens"), output: output)
        let native = (host == "claude" && id.hasPrefix("msg_")) || (host == "codex" && id.hasPrefix("resp_"))
        let key = host + "|" + (native ? "native" : session) + "|" + id
        guard usage.count < 50_000 || usage[key] != nil else { coverage.limitReached = true; return }
        // Claude may append several content blocks for one message with progressive counters.
        if let previous = usage[key], previous.value.date > time { return }
        usage[key] = (host, value)
    }
    mutating func consume(_ object: [String: Any], host: String, session: String) {
        let time = date(object["timestamp"])
        if host == "claude", let message = object["message"] as? [String: Any] {
            guard ["assistant", "user"].contains(object["type"] as? String ?? "") else { return }
            for block in message["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String {
                    start(host: host, session: session, id: id, name: name, input: block["input"], time: time)
                } else if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String {
                    end(host: host, session: session, id: id, value: block["content"], error: Self.boolean(block["is_error"]), time: time)
                }
            }
            tokens(host: host, session: session, id: message["id"] as? String, object: message["usage"] as? [String: Any], time: time)
        } else if host == "codex", let payload = object["payload"] as? [String: Any] {
            let type = payload["type"] as? String ?? ""
            if object["type"] as? String == "response_item" {
                if ["function_call", "custom_tool_call"].contains(type), let id = payload["call_id"] as? String, let name = payload["name"] as? String {
                    start(host: host, session: session, id: id, name: name, input: nil, time: time)
                } else if ["function_call_output", "custom_tool_call_output"].contains(type), let id = payload["call_id"] as? String {
                    end(host: host, session: session, id: id, value: payload["output"], error: nil, time: time)
                }
            } else if object["type"] as? String == "event_msg", type == "item_completed",
                      let item = payload["item"] as? [String: Any], item["type"] as? String == "McpToolCall",
                      let id = item["id"] as? String, let server = item["server"] as? String, !server.isEmpty,
                      let tool = item["tool"] as? String, !tool.isEmpty {
                start(host: host, session: session, id: id, name: "", input: nil,
                      time: milliseconds(payload["started_at_ms"]), nativeMCP: (server, tool))
                if let result = item["result"], !(result is NSNull) {
                    // "completed" is a lifecycle status, never Boolean isError=false.
                    end(host: host, session: session, id: id, value: result, error: nil,
                        time: milliseconds(payload["completed_at_ms"]))
                }
            } else if object["type"] as? String == "token_usage_record" {
                tokens(host: host, session: session, id: payload["response_id"] as? String, object: payload["usage"] as? [String: Any], time: time)
            } else if type == "token_count" { coverage.unsupportedUsageRecords += 1 }
        }
    }
    func report() -> ToolUsageReport {
        var coverage = self.coverage
        var rows: [String: ToolUsageRow] = [:]
        var timings: [String: [Double]] = [:]
        for call in calls.values {
            if !call.startSeen, inWindow(call.ended) { coverage.unmatchedResults += 1; continue }
            guard call.startSeen, inWindow(call.started) else { continue }
            guard let kind = call.kind, let name = call.name else { coverage.otherToolCalls += 1; continue }
            let key = call.groupID ?? Self.identity(call.host + "|" + kind + "|" + (call.server ?? "") + "|" + name)
            var row = rows[key] ?? ToolUsageRow(id: key, host: call.host, kind: kind, server: call.server, name: name)
            row.referenceEncoding = encoding == .heuristic ? nil : encoding.rawValue
            if encoding != .heuristic, row.unavailableReferenceResults == nil { row.unavailableReferenceResults = 0 }
            row.calls += 1
            if call.endSeen, inWindow(call.ended) {
                if encoding != .heuristic {
                    if row.completed == 0 { row.referenceReturnedTextTokens = call.referenceTokens }
                    else if let sum = row.referenceReturnedTextTokens, let count = call.referenceTokens { row.referenceReturnedTextTokens = sum + count }
                    else { row.referenceReturnedTextTokens = nil }
                    if call.referenceTokens == nil { row.unavailableReferenceResults = (row.unavailableReferenceResults ?? 0) + 1 }
                }
                row.completed += 1
                if call.isError == true { row.reportedErrors += 1 }
                if call.isError == nil { row.unknownErrorStatus += 1 }
                row.returnedTextBytes += call.textBytes; row.returnedTextEstimatedTokens += call.estimatedTokens; row.nonTextBlocks += call.nonText
                if let start = call.started, let end = call.ended, end >= start { timings[key, default: []].append(end.timeIntervalSince(start)) }
            } else { row.missingResults += 1 }
            rows[key] = row
        }
        for (key, samples) in timings {
            let sorted = samples.sorted()
            rows[key]?.timingSamples = sorted.count
            rows[key]?.totalObservedSeconds = sorted.reduce(0, +)
            rows[key]?.medianSeconds = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            if sorted.count >= 20 { rows[key]?.p95Seconds = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1] }
        }
        var totals: [String: LoggedTokenUsage] = [:]
        for entry in usage.values {
            var total = totals[entry.host] ?? LoggedTokenUsage(host: entry.host, semantics: "Raw host counters; cache overlap is not normalized or added to input")
            total.requests += 1; total.inputTokens += entry.value.input
            if let current = total.cachedInputTokens, let value = entry.value.cached { total.cachedInputTokens = current + value } else { total.cachedInputTokens = nil }
            if let current = total.cacheWriteInputTokens, let value = entry.value.write { total.cacheWriteInputTokens = current + value } else { total.cacheWriteInputTokens = nil }
            total.outputTokens += entry.value.output
            totals[entry.host] = total
        }
        let complete = !coverage.cancelled && !coverage.limitReached && coverage.clippedFiles == 0 && coverage.unreadableFiles == 0 && coverage.malformedLines == 0 && coverage.oversizedLines == 0 && coverage.missingTimestamps == 0 && coverage.unmatchedResults == 0
        return ToolUsageReport(generated: until, since: since, until: until, complete: complete, coverage: coverage,
                               tools: rows.values.sorted { $0.returnedTextBytes == $1.returnedTextBytes ? $0.id < $1.id : $0.returnedTextBytes > $1.returnedTextBytes },
                               sessionTokens: totals.values.sorted { $0.host < $1.host }, note: ToolUsageReport.explanation, referenceEncoding: encoding == .heuristic ? nil : encoding.rawValue, referenceEngine: encoding == .heuristic ? nil : ReferenceTokenizer.engine)
    }
}
