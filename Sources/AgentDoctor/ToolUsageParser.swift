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
        // CLI completion-only events can be placed in the window without inventing a start.
        var observedAt: Date?
        var startSeen = false
        var endSeen = false
        var isError: Bool?
        var outerError: Bool?
        var invocationFailed = false
        var textBytes = 0
        var estimatedTokens = 0
        var nonText = 0
        var textObservation = ToolResultTextObservation()
        var referenceTokens: Int?
        var unattributed: (text: TextFootprint, nonText: Int, measured: Bool)?
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
    var instructions: [String: InstructionObservation] = [:]
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
    static func durationSeconds(_ value: Any?) -> Double? {
        guard let object = value as? [String: Any] else { return nil }
        func integer(_ key: String, maximum: Double) -> Double? {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= maximum,
                  value.doubleValue.rounded() == value.doubleValue else { return nil }
            return value.doubleValue
        }
        guard let seconds = integer("secs", maximum: 253_402_300_799),
              let nanos = integer("nanos", maximum: 999_999_999) else { return nil }
        return seconds + nanos / 1_000_000_000
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
        } else {
            let normalized = name.hasPrefix("functions.") ? String(name.dropFirst(10)) : name
            // Group only protocol tool names. Never inspect shell commands or retain arguments.
            let safeName = normalized.range(of: #"^[A-Za-z0-9_.:-]{1,200}$"#, options: .regularExpression) != nil
                ? Self.label(normalized) : "Unidentified outer tool"
            call.name = safeName
            call.groupID = Self.identity(host + "|outer|" + safeName)
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
    /// Codex code-mode outputs use model input blocks, sometimes JSON-encoded.
    /// Never tokenize image/audio data or infer which nested tools produced it.
    static func unattributedResult(_ value: Any?, host: String, encoding: TextEncoding) -> (text: TextFootprint, nonText: Int, measured: Bool) {
        var blocks = value as? [[String: Any]]
        if host == "codex", let string = value as? String, string.drop(while: { $0.isWhitespace }).first == "[",
           let data = string.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !parsed.isEmpty,
           parsed.allSatisfy({ ($0["type"] as? String)?.hasPrefix("input_") == true }),
           parsed.contains(where: { ["input_text", "input_image", "input_audio", "input_file", "input_video"].contains($0["type"] as? String ?? "") }) {
            blocks = parsed
        }
        if let blocks {
            let textTypes = host == "codex" ? ["text", "input_text"] : ["text"]
            let supportedTypes = textTypes + ["image", "audio", "resource", "resource_link"] + (host == "codex" ? ["input_image", "input_audio", "input_file", "input_video"] : [])
            let textBlocks = blocks.filter { textTypes.contains($0["type"] as? String ?? "") }
            let texts = textBlocks.compactMap { $0["text"] as? String }
            return (TextFootprint(texts.joined(separator: "\n"), encoding: encoding), blocks.count - textBlocks.count,
                    texts.count == textBlocks.count && blocks.allSatisfy { supportedTypes.contains($0["type"] as? String ?? "") })
        }
        let measured = result(value, encoding: encoding)
        let supported = value is String || (value as? [String: Any]).map { $0["content"] is [[String: Any]] || $0["structuredContent"] != nil } == true
        return (measured.0, measured.1, supported)
    }
    mutating func end(host: String, session: String, id: String, value: Any?, error: Bool?, time: Date?, invocationFailed: Bool = false) {
        guard id.count <= 512, !id.isEmpty else { coverage.limitReached = true; return }
        let key = host + "|" + session + "|" + id
        if calls[key]?.endSeen == true { coverage.duplicateRecords += 1; return }
        guard calls.count < 100_000 || calls[key] != nil else { coverage.limitReached = true; return }
        var call = calls[key] ?? Call(host: host)
        if call.kind == nil { call.unattributed = Self.unattributedResult(value, host: host, encoding: encoding) }
        let measured = call.startSeen && call.kind == nil ? (TextFootprint(""), 0, nil as Bool?) : Self.result(value, encoding: encoding)
        call.ended = time; call.endSeen = true
        call.invocationFailed = invocationFailed
        // An inner result's isError is not the outer tool's status, including out-of-order events.
        call.outerError = error
        if error == true || measured.2 == true { call.isError = true }
        else if error != nil || measured.2 != nil { call.isError = false }
        else { call.isError = nil }
        call.textObservation = ToolResultTextObservation(value, codexInputBlocks: host == "codex" && call.kind == nil)
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
            if object["type"] as? String == "user", Self.boolean(object["isMeta"]) == true,
               let source = object["sourceToolUseID"] as? String {
                instruction(host: host, session: session, sourceID: source, eventID: object["uuid"] as? String,
                            content: message["content"], time: time)
            }
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
            } else if object["type"] as? String == "event_msg", ["mcp_tool_call_begin", "mcp_tool_call_end"].contains(type),
                      let id = payload["call_id"] as? String,
                      let invocation = payload["invocation"] as? [String: Any],
                      let server = invocation["server"] as? String, !server.isEmpty,
                      let tool = invocation["tool"] as? String, !tool.isEmpty {
                let key = host + "|" + session + "|" + id
                let duration = Self.durationSeconds(payload["duration"])
                let started = type == "mcp_tool_call_begin" ? time : time.flatMap { end in
                    duration.flatMap { seconds in seconds <= end.timeIntervalSince1970 ? end.addingTimeInterval(-seconds) : nil }
                }
                if calls[key]?.startSeen != true {
                    start(host: host, session: session, id: id, name: "", input: nil,
                          time: started, nativeMCP: (server, tool))
                }
                if type == "mcp_tool_call_end" {
                    calls[key]?.observedAt = time
                    if let result = payload["result"] as? [String: Any] {
                        if let value = result["Ok"] as? [String: Any], result["Err"] == nil {
                            end(host: host, session: session, id: id, value: value, error: nil, time: time)
                        } else if result["Ok"] == nil, let message = result["Err"] as? String,
                                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            end(host: host, session: session, id: id, value: nil, error: nil, time: time, invocationFailed: true)
                        }
                    }
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
                } else if item["status"] as? String == "failed", let error = item["error"] as? [String: Any],
                          let message = error["message"] as? String, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // A typed host error closes the call, but is not an MCP result.isError.
                    end(host: host, session: session, id: id, value: nil, error: nil,
                        time: milliseconds(payload["completed_at_ms"]), invocationFailed: true)
                }
            } else if object["type"] as? String == "token_usage_record" {
                tokens(host: host, session: session, id: payload["response_id"] as? String, object: payload["usage"] as? [String: Any], time: time)
            } else if type == "token_count" { coverage.unsupportedUsageRecords += 1 }
        }
    }
    func report() -> ToolUsageReport {
        var coverage = self.coverage
        var unattributed = UnattributedToolResults()
        if encoding != .heuristic { unattributed.referenceReturnedTextTokens = 0 }
        var rows: [String: ToolUsageRow] = [:]
        var outerRows: [String: ToolUsageRow] = [:]
        var timings: [String: [Double]] = [:]
        var loads: [String: SkillInstructionUsage] = [:]
        coverage.unmatchedInstructionEvents = coverage.unmatchedInstructionEvents ?? 0
        for observation in instructions.values {
            guard let call = calls[observation.callKey] else {
                coverage.unmatchedInstructionEvents! += 1; continue
            }
            guard call.kind == "skill" else { continue }
            guard inWindow(call.started ?? call.observedAt) else {
                coverage.unmatchedInstructionEvents! += 1; continue
            }
            var total = loads[observation.callKey] ?? SkillInstructionUsage(encoding: encoding)
            total.record(observation.text, nonText: observation.nonText, complete: observation.complete)
            loads[observation.callKey] = total
        }
        for (callKey, call) in calls {
            if !call.startSeen, inWindow(call.ended) { coverage.unmatchedResults += 1; continue }
            guard call.startSeen, inWindow(call.started ?? call.observedAt) else { continue }
            guard let kind = call.kind, let name = call.name else {
                coverage.otherToolCalls += 1
                let key = call.groupID ?? Self.identity(call.host + "|outer|Unidentified outer tool")
                var row = outerRows[key] ?? ToolUsageRow(id: key, host: call.host, kind: "outer",
                                                         name: call.name ?? "Unidentified outer tool")
                row.referenceEncoding = encoding == .heuristic ? nil : encoding.rawValue
                row.unmeasuredResults = row.unmeasuredResults ?? 0
                row.serializedMediaTextResults = row.serializedMediaTextResults ?? 0
                row.truncationMarkerResults = row.truncationMarkerResults ?? 0
                if encoding != .heuristic {
                    row.unavailableReferenceResults = row.unavailableReferenceResults ?? 0
                    if row.calls == 0 { row.referenceReturnedTextTokens = 0 }
                }
                row.calls += 1
                if call.endSeen, inWindow(call.ended) {
                    unattributed.completed += 1
                    row.completed += 1
                    if call.textObservation.serializedMedia { row.serializedMediaTextResults! += 1 }
                    if call.textObservation.truncationMarker { row.truncationMarkerResults! += 1 }
                    if call.outerError == true { row.reportedErrors += 1 }
                    if call.outerError == nil { row.unknownErrorStatus += 1 }
                    if let start = call.started, let end = call.ended, end >= start {
                        timings[key, default: []].append(end.timeIntervalSince(start))
                    }
                    if let measured = call.unattributed {
                        unattributed.returnedTextBytes += measured.text.bytes
                        unattributed.returnedTextEstimatedTokens += measured.text.estimatedTokens
                        unattributed.nonTextBlocks += measured.nonText
                        row.returnedTextBytes += measured.text.bytes
                        row.returnedTextEstimatedTokens += measured.text.estimatedTokens
                        row.nonTextBlocks += measured.nonText
                        if !measured.measured {
                            unattributed.unmeasuredResults += 1
                            row.unmeasuredResults! += 1
                        }
                        if encoding != .heuristic {
                            if measured.measured, let tokens = measured.text.referenceTokens {
                                if let total = unattributed.referenceReturnedTextTokens { unattributed.referenceReturnedTextTokens = total + tokens }
                                if let total = row.referenceReturnedTextTokens { row.referenceReturnedTextTokens = total + tokens }
                            } else {
                                unattributed.unavailableReferenceResults += 1
                                unattributed.referenceReturnedTextTokens = nil
                                row.unavailableReferenceResults! += 1
                                row.referenceReturnedTextTokens = nil
                            }
                        }
                    } else {
                        unattributed.unmeasuredResults += 1; unattributed.referenceReturnedTextTokens = nil
                        row.unmeasuredResults! += 1
                        if encoding != .heuristic {
                            row.unavailableReferenceResults! += 1
                            row.referenceReturnedTextTokens = nil
                        }
                    }
                } else { unattributed.missingResults += 1; row.missingResults += 1 }
                outerRows[key] = row
                continue
            }
            let key = call.groupID ?? Self.identity(call.host + "|" + kind + "|" + (call.server ?? "") + "|" + name)
            var row = rows[key] ?? ToolUsageRow(id: key, host: call.host, kind: kind, server: call.server, name: name)
            if kind == "skill" {
                if row.skillInstructions == nil { row.skillInstructions = SkillInstructionUsage(encoding: encoding) }
                if let observed = loads[callKey] { row.skillInstructions?.merge(observed) }
            }
            row.serializedMediaTextResults = row.serializedMediaTextResults ?? 0
            row.truncationMarkerResults = row.truncationMarkerResults ?? 0
            if row.invocationFailures == nil { row.invocationFailures = 0 }
            row.referenceEncoding = encoding == .heuristic ? nil : encoding.rawValue
            if encoding != .heuristic, row.unavailableReferenceResults == nil { row.unavailableReferenceResults = 0 }
            row.calls += 1
            if call.endSeen, inWindow(call.ended) {
                if call.invocationFailed {
                    row.invocationFailures = (row.invocationFailures ?? 0) + 1
                } else {
                    if encoding != .heuristic {
                        if row.completed == 0 { row.referenceReturnedTextTokens = call.referenceTokens }
                        else if let sum = row.referenceReturnedTextTokens, let count = call.referenceTokens { row.referenceReturnedTextTokens = sum + count }
                        else { row.referenceReturnedTextTokens = nil }
                        if call.referenceTokens == nil { row.unavailableReferenceResults = (row.unavailableReferenceResults ?? 0) + 1 }
                    }
                    row.completed += 1
                    if call.textObservation.serializedMedia { row.serializedMediaTextResults! += 1 }
                    if call.textObservation.truncationMarker { row.truncationMarkerResults! += 1 }
                    if call.isError == true { row.reportedErrors += 1 }
                    if call.isError == nil { row.unknownErrorStatus += 1 }
                    row.returnedTextBytes += call.textBytes; row.returnedTextEstimatedTokens += call.estimatedTokens; row.nonTextBlocks += call.nonText
                }
                if let start = call.started, let end = call.ended, end >= start { timings[key, default: []].append(end.timeIntervalSince(start)) }
            } else { row.missingResults += 1 }
            rows[key] = row
        }
        for (key, samples) in timings {
            let sorted = samples.sorted()
            guard var row = rows[key] ?? outerRows[key] else { continue }
            row.timingSamples = sorted.count
            row.totalObservedSeconds = sorted.reduce(0, +)
            row.medianSeconds = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            if sorted.count >= 20 { row.p95Seconds = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1] }
            if rows[key] != nil { rows[key] = row } else { outerRows[key] = row }
        }
        unattributed.byTool = outerRows.values.sorted {
            func count(_ row: ToolUsageRow) -> Int {
                encoding == .heuristic ? row.returnedTextEstimatedTokens : row.referenceReturnedTextTokens ?? -1
            }
            return count($0) == count($1) ? $0.id < $1.id : count($0) > count($1)
        }
        coverage.unattributedResults = unattributed
        var totals: [String: LoggedTokenUsage] = [:]
        for entry in usage.values {
            var total = totals[entry.host] ?? LoggedTokenUsage(host: entry.host, semantics: "Raw host counters; cache overlap is not normalized or added to input")
            total.requests += 1; total.inputTokens += entry.value.input
            if let current = total.cachedInputTokens, let value = entry.value.cached { total.cachedInputTokens = current + value } else { total.cachedInputTokens = nil }
            if let current = total.cacheWriteInputTokens, let value = entry.value.write { total.cacheWriteInputTokens = current + value } else { total.cacheWriteInputTokens = nil }
            total.outputTokens += entry.value.output
            totals[entry.host] = total
        }
        let complete = !coverage.cancelled && !coverage.limitReached && coverage.clippedFiles == 0 && coverage.unreadableFiles == 0 && coverage.malformedLines == 0 && coverage.oversizedLines == 0 && coverage.missingTimestamps == 0 && coverage.unmatchedResults == 0 && coverage.unmatchedInstructionEvents == 0
        return ToolUsageReport(generated: until, since: since, until: until, complete: complete, coverage: coverage,
                               tools: rows.values.sorted { $0.returnedTextBytes == $1.returnedTextBytes ? $0.id < $1.id : $0.returnedTextBytes > $1.returnedTextBytes },
                               sessionTokens: totals.values.sorted { $0.host < $1.host }, note: ToolUsageReport.explanation, referenceEncoding: encoding == .heuristic ? nil : encoding.rawValue, referenceEngine: encoding == .heuristic ? nil : ReferenceTokenizer.engine)
    }
}
