import AppKit
import Foundation
import ThermoKit

/// A snapshot of the executable on disk at launch, before either Sparkle or a manual install replaces it.
struct AppExecutableStamp: Equatable {
    let file: UInt64
    let modified: Date
    let size: UInt64

    init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let file = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        self.file = file.uint64Value; self.modified = modified; self.size = size.uint64Value
    }
}

@MainActor final class AppInstallationMonitor: ObservableObject {
    static let shared = AppInstallationMonitor()
    @Published private(set) var needsRestart = false
    @Published private(set) var restarting = false
    @Published private(set) var issue: String?
    private let executable: URL?
    private let launched: AppExecutableStamp?
    private var timer: Timer?
    private var announced = false

    init(executable: URL? = Bundle.main.executableURL) {
        self.executable = executable
        launched = executable.flatMap(AppExecutableStamp.init)
    }

    func start() {
        guard timer == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        check()
    }

    func check() {
        guard let executable, let launched, let current = AppExecutableStamp(url: executable), current != launched else { return }
        needsRestart = true
        guard !announced else { return }
        announced = true
        // Persistent settings banner plus the visible settings page: never silently run stale code.
        MainWindow.show(.settings)
    }

    func restart() {
        guard !restarting, needsRestart else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The App's ordinary termination flow can cancel or defer. Only relaunch after it really exits.
        // A cancelled quit times out without opening a second instance or sending any signals.
        process.arguments = ["-c", Self.relaunchScript, "thermo-relaunch", String(getpid()), Bundle.main.bundleURL.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.restarting = false }
        }
        do {
            try process.run()
            restarting = true; issue = nil
            NSApp.terminate(nil)
        } catch { issue = error.localizedDescription }
    }

    static let relaunchScript = """
    n=0
    while kill -0 "$1" 2>/dev/null; do
        n=$((n+1))
        [ "$n" -lt 60 ] || exit 1
        sleep 1
    done
    exec /usr/bin/open "$2"
    """
}
