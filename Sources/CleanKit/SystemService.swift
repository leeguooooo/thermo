import AgentCore
import Darwin
import Foundation

/// The one kind of system process Thermo acts on: an XPC service inside a system framework that
/// launchd started for this user and starts again when a client next connects. It is restarted,
/// never just ended: the point is to hand back what it piled up (issue #138, a leaking
/// `CursorUIViewService`). Everything else under /System stays untouchable.
public enum SystemService {
    /// Only bundles in Apple's framework folders: an app's own XPC services (Dock, Finder) are part of that app.
    static let roots = ["/System/Library/Frameworks/", "/System/Library/PrivateFrameworks/"]

    /// Services where "it comes back by itself" is not the whole story: killing one loses a page,
    /// an export, audio, a call, an unlock prompt, a purchase, a download or an install in progress,
    /// or interrupts something that writes a database or guards the system. Matched against the
    /// lowercased path, so a framework or a service name can rule it out. Ruling out too much only
    /// leaves a service as "cannot be ended", so the words are broad on purpose.
    static let excluded = ["webkit", "safari", "videotoolbox", "audio", "coremedia", "speech", "camera", "facetime", "conversation",
                           "security", "auth", "keychain", "crypto", "xprotect", "passkit", "accounts",
                           "fileprovider", "cloud", "sync", "backup", "timemachine", "diskimage", "storagekit",
                           "install", "softwareupdate", "packagekit", "streamingzip", "migration", "appstore", "store",
                           "coredata", "persistence", "database", "imd", "messages", "mail", "contacts", "calendar", "photos", "notes",
                           "geod", "geoservices", "bkagent", "virtualization", "hypervisor", "openandsavepanel"]

    /// `…/XPCServices/<Name>.xpc/Contents/MacOS/<executable>` under a system framework, with no
    /// excluded word in it. Says nothing about who runs it; see `restartable`.
    public static func isOnDemandBundle(_ executable: String) -> Bool {
        guard roots.contains(where: { executable.hasPrefix($0) }) else { return false }
        let parts = executable.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 7 else { return false }
        let tail = parts.suffix(5)
        let i = tail.startIndex
        guard tail[i] == "XPCServices", tail[i + 1].hasSuffix(".xpc"), tail[i + 1].count > 4,
              tail[i + 2] == "Contents", tail[i + 3] == "MacOS", !tail[i + 4].isEmpty,
              parts.dropLast(5).contains(where: { $0.hasSuffix(".framework") }),
              !parts.contains(".."), !parts.contains(".") else { return false }
        let lower = executable.lowercased()
        return !excluded.contains { lower.contains($0) }
    }

    /// May be restarted from Thermo: the bundle rule above, running as this (non-root) user, and a
    /// direct child of launchd, which is what starts it again. A copy started by anything else, or
    /// owned by root, is left alone.
    public static func restartable(executable: String?, pid: Int32, ppid: Int32, uid: UInt32,
                                   user: UInt32 = getuid(), me: Int32 = getpid()) -> Bool {
        guard let executable, pid > 1, pid != me, ppid == 1, uid == user, uid != 0 else { return false }
        if SlowdownDiagnosis.systemNames.contains((executable as NSString).lastPathComponent) { return false }
        return isOnDemandBundle(executable)
    }

    public static func restartable(_ p: SlowdownProcess, user: UInt32 = getuid(), me: Int32 = getpid()) -> Bool {
        restartable(executable: p.executable, pid: p.pid, ppid: p.ppid, uid: p.uid, user: user, me: me)
    }

    /// Whether a row is worth a Restart button of its own: below this a service holds too little
    /// to bother anyone with, and the action stays in the context menu and the command line.
    public static let buttonFloorKB = 200 * 1024

    public enum Outcome: String, Codable, Sendable {
        /// Gone, and launchd has already started a new copy.
        case relaunched
        /// Gone; nothing needs it right now, so launchd starts it on the next use.
        case exited
        case stillRunning, changed, refused, notDelivered
    }

    public struct Result: Codable, Sendable, Equatable {
        public var pid: Int32
        public var name: String
        public var outcome: Outcome
        /// SIGTERM was ignored and SIGKILL was sent.
        public var forced: Bool
        public var newPID: Int32?
        public var freedKB: Int

        public var done: Bool { outcome == .relaunched || outcome == .exited }

        public var summary: String {
            switch outcome {
            case .relaunched, .exited:
                let ended = forced ? tr("%1$@ (PID %2$@) ignored the request to stop and was forced to quit (SIGKILL).", name, String(pid))
                                   : tr("%1$@ (PID %2$@) stopped after being asked.", name, String(pid))
                let back = newPID.map { tr("macOS has started it again as PID %1$@.", String($0)) }
                    ?? tr("macOS starts it again the next time it is needed.")
                let freed = freedKB > 0 ? tr("About %1$@ freed.", MemoryFormat.string(kibibytes: freedKB)) : ""
                return MachinePulse.sentences(MachinePulse.sentences(ended, back), freed)
            case .stillRunning:
                return tr("%1$@ (PID %2$@) is still running after SIGTERM and SIGKILL. Thermo cannot end it; it may need an administrator.", name, String(pid))
            case .changed: return tr("PID %1$@ is no longer the process that was checked; nothing was sent.", String(pid))
            case .refused: return tr("%1$@ (PID %2$@) is not an on-demand system service; Thermo does not restart it.", name, String(pid))
            case .notDelivered: return tr("The signal could not be delivered to PID %1$@.", String(pid))
            }
        }
    }

    /// Every running copy of one executable for one user. Several can exist (one per client app).
    public static func instances(of executable: String, uid: UInt32) -> [ProcessIdentity] {
        ProcessTable.current(.init(cpu: false)).entries.compactMap { p in
            p.executable == executable && p.uid == uid ? p.sampledIdentity ?? ProcessTable.identity(p.pid) : nil
        }
    }

    /// SIGTERM, wait, SIGKILL if the very same process is still there, then look for the copy launchd
    /// started in its place. Each signal goes through the gate, which rechecks the identity and the
    /// rule against the live process, so a PID that was reused in between is never signalled.
    public static func restart(_ identity: ProcessIdentity, memoryKB: Int = 0, grace: TimeInterval = 3, relaunchWait: TimeInterval = 2,
                               record: Bool = true,
                               attempt: (ProcessIdentity, Int32) -> ProcessActionGate.Outcome = { identity, sig in
                                   ProcessActionGate.attempt(identity, allowApplication: false, allowSystemService: true) { kill($0.pid, sig) == 0 }
                               },
                               alive: (ProcessIdentity) -> Bool = { ProcessTable.identity($0.pid) == $0 },
                               instances: (String, UInt32) -> [ProcessIdentity] = SystemService.instances) -> Result {
        let bundle = identity.executable.split(separator: "/").map(String.init).last { $0.hasSuffix(".xpc") }
        var result = Result(pid: identity.pid, name: bundle.map { String($0.dropLast(4)) } ?? (identity.executable as NSString).lastPathComponent,
                            outcome: .refused, forced: false, newPID: nil, freedKB: 0)
        func finish() -> Result {
            if record, result.outcome != .changed, result.outcome != .refused {
                OperationJournal.record(OperationRecord(feature: "pulse", action: "restart-service", subject: result.name,
                                                        items: [.init(target: "\(result.name) · PID \(result.pid)", bytes: Int64(result.freedKB) * 1024,
                                                                      status: result.done ? "done" : "failed",
                                                                      detail: result.outcome.rawValue + (result.forced ? " (SIGKILL)" : "")
                                                                          + (result.newPID.map { " → PID \($0)" } ?? ""))]))
            }
            return result
        }
        func outcome(_ o: ProcessActionGate.Outcome) -> Outcome? {
            switch o {
            case .requested: return nil
            case .declined: return .notDelivered
            case .protected: return .refused
            case .changed, .unavailable: return .changed
            }
        }
        let before = Set(instances(identity.executable, identity.uid).map(\.pid))
        let sent = Date()
        if let failed = outcome(attempt(identity, SIGTERM)) { result.outcome = failed; return finish() }
        func wait(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline, alive(identity) { usleep(100_000) }
        }
        wait(grace)
        if alive(identity) {
            // Still the process that was checked: the gate compares pid, start time and executable again.
            let hard = attempt(identity, SIGKILL)
            if hard == .changed || hard == .unavailable, !alive(identity) {
                // It went between the check and the signal: that is the outcome that was asked for.
            } else if let failed = outcome(hard) { result.outcome = failed == .refused ? .stillRunning : failed; return finish() }
            else { result.forced = true; wait(grace) }
        }
        guard !alive(identity) else { result.outcome = .stillRunning; return finish() }
        result.freedKB = memoryKB
        // launchd starts an on-demand service only when a client connects, so no new copy is not a failure.
        let deadline = Date().addingTimeInterval(relaunchWait)
        repeat {
            if let fresh = instances(identity.executable, identity.uid)
                .first(where: { !before.contains($0.pid) && $0.started >= sent.addingTimeInterval(-1) }) {
                result.newPID = fresh.pid
                break
            }
            if relaunchWait > 0 { usleep(200_000) }
        } while Date() < deadline
        result.outcome = result.newPID != nil ? .relaunched : .exited
        return finish()
    }
}

/// Footprint far above resident memory: the difference is not resident. Resident memory counts shared
/// pages, so it only bounds the resident part of the footprint from above; the rest is compressed
/// (still in RAM, but squeezed) or in swap, and the two cannot be told apart per process.
public enum MemoryGap {
    public static let floorKB = 200 * 1024

    /// KiB of the footprint that is certainly not resident, when that is at least three quarters of it.
    public static func outOfRAMKB(footprintKB: Int, residentKB: Int?, metric: MachinePulse.MemoryMetric?) -> Int? {
        guard metric == nil || metric == .footprint, let residentKB, residentKB >= 0, footprintKB >= floorKB,
              residentKB <= footprintKB / 4 else { return nil }
        return footprintKB - residentKB
    }

    public static func text(footprintKB: Int, residentKB: Int, swapUsed: UInt64? = nil, swapFiles: UInt64? = nil) -> String {
        let gap = tr("Footprint %1$@, resident %2$@: most of this memory is not resident. macOS has compressed it or moved it to swap on the disk, where it still takes up space until the program lets go of it.",
                     MemoryFormat.string(kibibytes: footprintKB), MemoryFormat.string(kibibytes: residentKB))
        guard let swapUsed, let swapFiles, swapFiles > 0 else { return gap }
        return MachinePulse.sentences(gap, tr("Swap in use now: %1$@ of %2$@.", MemoryFormat.string(bytes: swapUsed), MemoryFormat.string(bytes: swapFiles)))
    }
}
