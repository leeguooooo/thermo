import Foundation
import ThermoKit
import AgentCore
import Sparkle

/// Sparkle wrapper. Disabled when the build has no SUFeedURL (APPCAST_URL unset at build time).
final class Updates: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?
    private var availabilityObservation: NSKeyValueObservation?
    @Published private(set) var canCheck = false

    static var feedURL: String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !s.isEmpty, !s.hasPrefix("__") else { return nil }
        return s
    }

    override init() {
        super.init()
        if Self.feedURL != nil {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
            availabilityObservation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let available = updater.canCheckForUpdates
                DispatchQueue.main.async { self?.canCheck = available }
            }
        }
    }

    var enabled: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { objectWillChange.send(); controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        guard controller?.updater.canCheckForUpdates == true else { return }
        controller?.checkForUpdates(nil)
    }

    // Menu bar (LSUIElement) apps should not steal focus for scheduled update alerts.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}

enum AppInfo {
    static let buildMetadata = AppBuildMetadata(info: Bundle.main.infoDictionary ?? [:])
    static var workingTreeLabel: String {
        switch buildMetadata.workingTree {
        case .clean: return "Working tree clean"
        case .dirty: return "Working tree dirty"
        case .unknown: return "Working tree unknown"
        }
    }
    static var version: String {
        // The bundle on disk can already belong to the next release; the compiled constant cannot.
        let v = ThermoVersion.string
        return buildMetadata.version == v ? buildMetadata.build.map { "\(v) (\($0))" } ?? v : v
    }
}
