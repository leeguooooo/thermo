import Foundation
import CleanKit

/// Opt-in grouping only. The app must be running; it never closes tabs. The workspace lock
/// also covers CLI/manual operations. Each cycle reads fresh metadata and native group state.
@MainActor
final class TabAutomation: ObservableObject {
    static let shared = TabAutomation()
    @Published private(set) var running = false
    @Published private(set) var lastResult: String?
    private var timer: Timer?
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in self.tick() } }
    }
    func tick() {
        guard !running, let config = try? TabOrganizer.configuration(), config.enabled else { return }
        running = true
        Task {
            defer { running = false }
            do {
                let batch = try await Task.detached { () -> TabOrganizer.Batch? in
                    let inventory = try await TabWorkspace.inventory()
                    let plan = TabOrganizer.plan(inventory, rules: config.rules)
                    guard plan.count > 0 else { return nil }
                    return try await TabOrganizer.organize(plan)
                }.value
                if let batch { lastResult = "\(batch.grouped)" }
            } catch { lastResult = error.localizedDescription }
        }
    }
}
