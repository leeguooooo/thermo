import AgentDoctor
import SwiftUI
import ThermoL10n

/// Retains only measurements and the largest ten rows per configuration, never definition text.
@MainActor final class MCPDefinitionStore: ObservableObject {
    struct Ticket: Equatable { let generation: UUID; let run: UUID }
    struct Entry {
        let name: String
        let agent: String
        let generated: Date
        let encoding: TextEncoding
        let complete: Bool
        let definitions: TextFootprint?
        let instructions: TextFootprint?
        let tools: Int
        let toolsWithIssues: Int
        let uncountedTools: Int
        let largest: [MCPToolFootprint]
    }
    struct RankedTool: Identifiable {
        let id: String
        let server: String
        let agent: String
        let tool: MCPToolFootprint
    }
    struct Summary {
        var configured = 0
        var disabled = 0
        var completed = 0
        var incomplete = 0
        var running = 0
        var tools = 0
        var toolsWithIssues = 0
        var uncountedTools = 0
        var definitionBytes = 0
        var definitionTokens: Int?
        var instructionTokens: Int?
        var largest: [RankedTool] = []
    }
    @Published private(set) var entries: [String: Entry] = [:]
    @Published private(set) var pending: [String: Ticket] = [:]
    private var generation = UUID()

    func reset() { generation = UUID(); entries = [:]; pending = [:] }
    func begin(_ id: String) -> Ticket {
        let ticket = Ticket(generation: generation, run: UUID())
        entries.removeValue(forKey: id)
        pending[id] = ticket
        return ticket
    }
    func accept(_ report: MCPInspection, id: String, encoding: TextEncoding, ticket: Ticket) {
        guard ticket.generation == generation, pending[id] == ticket else { return }
        pending.removeValue(forKey: id)
        let complete = report.complete && report.state == .ready && report.definitions != nil && report.instructions != nil
        let tools = complete ? report.tools : []
        let ranked = tools.filter { Self.tokens($0.definition, encoding: encoding) != nil }.sorted {
            let a = Self.tokens($0.definition, encoding: encoding)!, b = Self.tokens($1.definition, encoding: encoding)!
            return a == b ? $0.name < $1.name : a > b
        }
        entries[id] = Entry(name: report.name, agent: report.agent, generated: report.generated, encoding: encoding,
                            complete: complete, definitions: complete ? report.definitions : nil,
                            instructions: complete ? report.instructions : nil, tools: tools.count,
                            toolsWithIssues: tools.filter { !$0.issues.isEmpty }.count,
                            uncountedTools: tools.count - ranked.count, largest: Array(ranked.prefix(10)))
    }
    static func tokens(_ footprint: TextFootprint?, encoding: TextEncoding) -> Int? {
        guard let footprint, footprint.referenceEncoding == (encoding == .heuristic ? nil : encoding.rawValue) else { return nil }
        return footprint.comparisonTokens
    }
    func summary(items: [AgentItem], encoding: TextEncoding) -> Summary {
        let enabled = Dictionary(items.filter { $0.area == .mcp && $0.enabled }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = Summary(configured: enabled.count, disabled: Set(items.filter { $0.area == .mcp && !$0.enabled }.map(\.id)).count)
        var definitions = 0, instructions = 0, definitionsKnown = true, instructionsKnown = true
        for id in enabled.keys.sorted() {
            if pending[id] != nil { result.running += 1 }
            guard let entry = entries[id], entry.encoding == encoding else { continue }
            guard entry.complete else { result.incomplete += 1; continue }
            result.completed += 1
            result.tools += entry.tools; result.toolsWithIssues += entry.toolsWithIssues; result.uncountedTools += entry.uncountedTools
            result.definitionBytes += entry.definitions?.bytes ?? 0
            if let value = Self.tokens(entry.definitions, encoding: encoding) { definitions += value } else { definitionsKnown = false }
            if let value = Self.tokens(entry.instructions, encoding: encoding) { instructions += value } else { instructionsKnown = false }
            for (index, tool) in entry.largest.enumerated() {
                result.largest.append(RankedTool(id: id + "/" + String(index), server: entry.name, agent: entry.agent, tool: tool))
            }
        }
        // Zero inspected configurations is unknown; a complete empty tool array is measured.
        result.definitionTokens = result.completed > 0 && definitionsKnown ? definitions : nil
        result.instructionTokens = result.completed > 0 && instructionsKnown ? instructions : nil
        result.largest = Array(result.largest.sorted {
            let a = Self.tokens($0.tool.definition, encoding: encoding)!, b = Self.tokens($1.tool.definition, encoding: encoding)!
            return a == b ? $0.id < $1.id : a > b
        }.prefix(10))
        return result
    }
}
