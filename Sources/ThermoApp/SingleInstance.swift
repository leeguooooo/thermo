import AppKit
import Darwin

/// An OS-held lock also covers copies of the app launched from different paths.
/// The kernel releases it on exit or crash; the file's existence is not a lock.
final class SingleInstanceLock {
    private let descriptor: Int32

    init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func acquire() -> Bool { flock(descriptor, LOCK_EX | LOCK_NB) == 0 }
    deinit { close(descriptor) }
}

@MainActor
enum SingleInstance {
    private static var lock: SingleInstanceLock?
    private static var observer: NSObjectProtocol?
    private static let showWindow = Notification.Name("dev.thermo.showExistingWindow")

    static func claim() throws -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Thermo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidate = try SingleInstanceLock(url: directory.appendingPathComponent("app.lock"))
        guard candidate.acquire() else {
            DistributedNotificationCenter.default().postNotificationName(showWindow, object: nil, userInfo: ["search": CommandLine.arguments.contains("--search")], deliverImmediately: true)
            return false
        }
        lock = candidate
        observer = DistributedNotificationCenter.default().addObserver(forName: showWindow, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                if notification.userInfo?["search"] as? Bool == true { LocalSearchPanel.shared.show() }
                else { MainWindow.show() }
            }
        }
        return true
    }
}
