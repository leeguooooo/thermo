import Foundation
import Sparkle

/// Sparkle wrapper. Disabled when the build has no SUFeedURL (APPCAST_URL unset at build time).
final class Updates: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    static var feedURL: String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !s.isEmpty, !s.hasPrefix("__") else { return nil }
        return s
    }

    override init() {
        super.init()
        if Self.feedURL != nil {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        }
    }

    var enabled: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    // Menu bar (LSUIElement) apps should not steal focus for scheduled update alerts.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}

enum AppInfo {
    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return b.map { "\(v) (\($0))" } ?? v
    }
}
