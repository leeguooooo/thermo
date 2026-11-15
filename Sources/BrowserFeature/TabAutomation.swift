import Foundation
import CleanKit

/// Opt-in grouping only. The app must be running; it never closes tabs. The workspace lock
/// also covers CLI/manual operations. Each cycle reads fresh metadata and native group state.
@MainActor
final class TabAutomation: ObservableObject {
    private let enabled:()->Bool
    private let configuration:()->TabOrganizer.Configuration?
    private var active=false
    init(enabled:@escaping ()->Bool={true},configuration:@escaping ()->TabOrganizer.Configuration?={try? TabOrganizer.configuration()}) {
        self.enabled=enabled;self.configuration=configuration
    }
    @Published private(set) var running = false
    @Published private(set) var lastResult: String?
    private var timer: Timer?
    func start() {
        guard enabled(),timer == nil else { return }
        active=true
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in self.tick() } }
    }
    func tick() {
        guard active,enabled(),!running,let config=configuration(),config.enabled else{return}
        running = true
        Task {
            defer { running = false }
            do {
                let batch = try await Task.detached { () -> TabOrganizer.Batch? in
                    let inventory = try await TabWorkspace.inventory()
                    let plan = TabOrganizer.plan(inventory, rules: config.rules, batches: ((try? TabOrganizer.batches()) ?? []).filter { $0.app == inventory.app }, auto: true)
                    guard plan.count > 0 else { return nil }
                    return try await TabOrganizer.organize(plan)
                }.value
                if let batch { lastResult = "\(batch.grouped)" }
            } catch { lastResult = error.localizedDescription }
        }
    }
    func stop() {active=false;timer?.invalidate();timer=nil}

}
