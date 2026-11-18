import Foundation
import UserNotifications

/// The reminder about left-behind tool processes carries a button. The app shell registers it once
/// and hands a pressed button back here; nothing opens, the processes are ended and a second
/// notification says what happened.
public enum ToolRescueNotifications {
    public static let category = "thermo.tools"
    public static let endAction = "thermo.tools.end"

    public static func register() {
        // UserNotifications throws outside an app bundle (bare dev builds).
        guard Bundle.main.bundleIdentifier != nil else { return }
        let end = UNNotificationAction(identifier: endAction, title: tr("End them"), options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [end], intentIdentifiers: [], options: [])])
    }

    /// True when `action` was the button and the work has been started.
    public static func handle(action: String) -> Bool {
        guard action == endAction else { return false }
        DispatchQueue.global(qos: .userInitiated).async {
            // Read again: only what still qualifies now is ended.
            let processes = SlowdownSampler().sample(window: 1)
            let identities = ToolProcesses.rescueIdentities(ToolProcesses.inventory(processes))
            let memory = Dictionary(processes.map { ($0.pid, $0.footprintKB) }, uniquingKeysWith: { a, _ in a })
            let outcome = ToolProcesses.end(identities, memoryKB: memory, subject: "rescue")
            post(title: tr("Left-behind tool processes"), body: outcome.summary, id: "thermo.tools.ended")
        }
        return true
    }

    public static func post(title: String, body: String, id: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
