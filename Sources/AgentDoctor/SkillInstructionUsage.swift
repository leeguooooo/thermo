import Foundation

/// Explicitly source-linked instruction messages, separate from tool acknowledgments.
/// These counters retain neither the instruction text nor its source path.
public struct SkillInstructionUsage: Codable, Sendable {
    public var events = 0
    public var textBytes = 0
    public var estimatedTokens = 0
    public var referenceTokens: Int?
    public var nonTextBlocks = 0
    public var incompleteEvents = 0

    init(encoding: TextEncoding) {
        self.init(referenceEncoding: encoding == .heuristic ? nil : encoding.rawValue)
    }

    init(referenceEncoding: String?) { referenceTokens = referenceEncoding == nil ? nil : 0 }

    mutating func record(_ text: TextFootprint, nonText: Int, complete: Bool) {
        events += 1; textBytes += text.bytes; estimatedTokens += text.estimatedTokens
        nonTextBlocks += nonText
        if !complete { incompleteEvents += 1 }
        if complete, let total = referenceTokens, let count = text.referenceTokens {
            referenceTokens = total + count
        } else { referenceTokens = nil }
    }

    mutating func merge(_ other: Self) {
        events += other.events; textBytes += other.textBytes; estimatedTokens += other.estimatedTokens
        nonTextBlocks += other.nonTextBlocks; incompleteEvents += other.incompleteEvents
        if let total = referenceTokens, let count = other.referenceTokens { referenceTokens = total + count }
        else { referenceTokens = nil }
    }
}

extension ToolUsageParser {
    struct InstructionObservation {
        let callKey: String
        let text: TextFootprint
        let nonText: Int
        let complete: Bool
    }

    mutating func instruction(host: String, session: String, sourceID: String, eventID: String?, content: Any?, time: Date?) {
        guard let time else { coverage.missingTimestamps += 1; return }
        guard inWindow(time) else { return }
        guard !sourceID.isEmpty, sourceID.count <= 512, let eventID, let uuid = UUID(uuidString: eventID) else {
            coverage.unmatchedInstructionEvents = (coverage.unmatchedInstructionEvents ?? 0) + 1; return
        }
        let callKey = host + "|" + session + "|" + sourceID
        let key = callKey + "|" + uuid.uuidString
        guard instructions[key] == nil else { coverage.duplicateRecords += 1; return }
        guard instructions.count < 100_000 else { coverage.limitReached = true; return }
        let measured: (TextFootprint, Int, Bool)
        if let text = content as? String { measured = (TextFootprint(text, encoding: encoding), 0, true) }
        else if let blocks = content as? [[String: Any]] {
            let textBlocks = blocks.filter { $0["type"] as? String == "text" }
            let texts = textBlocks.compactMap { $0["text"] as? String }
            let known = ["text", "image", "audio", "resource", "resource_link"]
            measured = (TextFootprint(texts.joined(separator: "\n"), encoding: encoding), blocks.count - textBlocks.count,
                        textBlocks.count == texts.count && blocks.allSatisfy { known.contains($0["type"] as? String ?? "") })
        } else { measured = (TextFootprint("", encoding: encoding), 0, false) }
        instructions[key] = InstructionObservation(callKey: callKey, text: measured.0, nonText: measured.1, complete: measured.2)
    }
}
