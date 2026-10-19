import AgentDoctor
import Foundation
import SwiftUI

@MainActor final class MCPBatchInspectionModel: ObservableObject {
    struct Request: Sendable {
        let id: String
        let encoding: TextEncoding
        let timeout: TimeInterval
        let protocolMode: MCPInspectionProtocol
        let cancelled: @Sendable () -> Bool
    }
    struct Item: Sendable { let id: String; let name: String; let agent: String }
    struct ResultID: Hashable, Sendable { let configuration: String }
    struct Row: Identifiable, Sendable {
        let id: String
        let name: String
        let agent: String
        let complete: Bool
        let state: MCPInspection.State
        let message: String
        var displayID: ResultID { ResultID(configuration: id) }
    }
    enum EndReason: Equatable, Sendable { case finished, cancelled, budgetExpired }
    typealias Inspector = @Sendable (Request) -> MCPInspection
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published private(set) var total = 0
    @Published private(set) var current: String?
    @Published private(set) var rows: [Row] = []
    @Published private(set) var reason: EndReason?
    @Published private(set) var elapsed: TimeInterval = 0
    var runningChanged: ((Bool) -> Void)?
    var notStarted: Int { max(0, total - rows.count - (current == nil ? 0 : 1)) }
    private let store: MCPDefinitionStore
    private let inspector: Inspector
    private let clock: @Sendable () -> TimeInterval
    private var cancellation: DoctorCancellation?
    private var discardResults = false

    init(store: MCPDefinitionStore, inspector: Inspector? = nil,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store
        self.inspector = inspector ?? { request in
            AgentDoctor.inspectMCP(request.id, timeout: request.timeout,
                                  protocolMode: request.protocolMode,
                                  env: DoctorEnvironment(tokenEncoding: request.encoding, cancelled: request.cancelled))
        }
        self.clock = clock
        store.onReset = { [weak self] in self?.invalidate() }
    }

    @discardableResult func start(items: [AgentItem], encoding: TextEncoding, timeout: TimeInterval = 10,
                                  totalBudget: TimeInterval = 120, protocolMode: MCPInspectionProtocol = .handshake) -> Bool {
        guard !running, store.pending.isEmpty, timeout.isFinite, timeout > 0, timeout <= 120,
              totalBudget.isFinite, totalBudget > 0, totalBudget <= 120 else { return false }
        var seen = Set<String>()
        let queue = items.filter { $0.area == .mcp && $0.enabled && seen.insert($0.id).inserted }
            .sorted { ($0.agent, $0.name, $0.id) < ($1.agent, $1.name, $1.id) }
            .map { Item(id: $0.id, name: $0.name, agent: $0.agent) }
        guard !queue.isEmpty else { return false }
        store.removeMeasurements(for: queue.map(\.id))
        let cancellation = DoctorCancellation()
        self.cancellation = cancellation
        discardResults = false
        total = queue.count; rows = []; reason = nil; elapsed = 0; current = nil
        running = true; stopping = false; runningChanged?(true)
        let clock = clock, inspector = inspector
        let started = clock(), deadline = started + totalBudget
        Task.detached(priority: .userInitiated) {
            var end = EndReason.finished
            for item in queue {
                if cancellation.isCancelled { end = .cancelled; break }
                if clock() >= deadline { end = .budgetExpired; break }
                let ticket = await MainActor.run {
                    self.current = item.name
                    return self.store.begin(item.id)
                }
                let remaining = deadline - clock()
                if remaining <= 0 || cancellation.isCancelled {
                    await MainActor.run { self.store.abandon(item.id, ticket: ticket) }
                    end = cancellation.isCancelled ? .cancelled : .budgetExpired
                    break
                }
                let result = inspector(Request(id: item.id, encoding: encoding, timeout: min(timeout, remaining),
                                               protocolMode: protocolMode,
                                               cancelled: { cancellation.isCancelled || clock() >= deadline }))
                await MainActor.run {
                    self.store.accept(result, id: item.id, encoding: encoding, ticket: ticket)
                    if !self.discardResults {
                        self.rows.append(Row(id: item.id, name: item.name, agent: item.agent,
                                             complete: result.complete && result.state == .ready && result.definitions != nil && result.instructions != nil,
                                             state: result.state, message: String(Redact.text(result.message).prefix(500))))
                    }
                    self.current = nil
                }
                if clock() >= deadline && !result.complete { end = .budgetExpired; break }
            }
            if cancellation.isCancelled { end = .cancelled }
            else if end == .finished, clock() >= deadline {
                // A fully returned final check is still fully processed, even if cleanup exceeded the budget.
                let processed = await MainActor.run { self.rows.count }
                if processed < queue.count { end = .budgetExpired }
            }
            let finished = end
            let elapsed = max(0, clock() - started)
            await MainActor.run {
                self.current = nil; self.reason = finished; self.elapsed = elapsed
                self.running = false; self.stopping = false; self.cancellation = nil
                if self.discardResults { self.clearProgress() }
                self.runningChanged?(false)
            }
        }
        return true
    }
    func cancel() {
        guard running else { return }
        stopping = true
        cancellation?.cancel()
    }
    private func clearProgress() { total = 0; current = nil; rows = []; reason = nil; elapsed = 0 }
    private func invalidate() {
        if running { discardResults = true; cancel() }
        else { clearProgress() }
    }
}
