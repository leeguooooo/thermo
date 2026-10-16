import AgentCore
import Darwin
import Foundation

/// A read-only observation, not an authorization to signal any PID.
public struct ProcessExplanation: Codable, Sendable {
    public enum Attribution: String, Codable, Sendable { case executableLocation, ancestorApplication, unknown }
    public struct Node: Codable, Sendable, Identifiable {
        public var id: Int32 { pid }
        public var pid: Int32
        public var parentPID: Int32
        public var uid: UInt32
        public var started: Date
        public var name: String
        public var executable: String
        public var args: [String]
        public var workingDirectory: String?
    }
    public var pid: Int32
    public var sampled: Date
    public var chain: [Node]
    public var chainComplete: Bool
    public var application: String?
    public var attribution: Attribution
    public var observedPaths: [String]?
    public var pathQueriesComplete: Bool
    public var pathsTruncated: Bool
    public var issues: [String]
    public var listeners: ProcessListeners? = nil
    public var sleepAssertions: ProcessSleepAssertions? = nil
    public var launchServices: ProcessLaunchServices? = nil

    public static func capture(_ pid: Int32, expected: ProcessIdentity? = nil) throws -> ProcessExplanation {
        guard pid > 0, expected.map({ $0.pid == pid }) ?? true else { throw Unavailable() }
        return try capture(pid, expected: expected, table: ProcessTable.current(.init(uid: nil, cpu: false, detailsUID: getuid())),
                    identity: ProcessTable.identity, parent: ProcessTable.parentPID, paths: { OpenFiles.observe($0) }, listeners: ProcessListeners.capture, sleepAssertions: ProcessSleepAssertions.capture, launchServices: ProcessLaunchServices.capture)
    }

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "The process changed, exited or could not be verified. Close details and choose a fresh process reading." }
    }

    static func displayed(_ value: String) -> String {
        Redact.text(value).unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? String(format: "\\u{%X}", $0.value) : String($0)
        }.joined()
    }

    static func capture(_ pid: Int32, expected: ProcessIdentity? = nil, table: ProcessTable,
                        identity: (Int32) -> ProcessIdentity?, parent: (Int32) -> Int32?,
                        paths: (Int32) -> OpenFiles.Observation, uid: UInt32 = getuid(), maximumDepth: Int = 32,
                        listeners: (Int32) -> ProcessListeners? = { _ in nil },
                        sleepAssertions: (Int32) -> ProcessSleepAssertions? = { _ in nil },
                        launchServices: (Int32) -> ProcessLaunchServices? = { _ in nil }) throws -> ProcessExplanation {
        guard pid > 0, maximumDepth > 0, maximumDepth <= 128, table.available,
              let target = table.entries.first(where: { $0.pid == pid }), let initial = target.sampledIdentity,
              expected.map({ $0 == initial }) ?? true, identity(pid) == initial else { throw Unavailable() }
        let byPID = Dictionary(table.entries.map { ($0.pid, $0) }, uniquingKeysWith: { a,_ in a })
        var captured: [AgentProcess] = [], seen = Set<Int32>(), current = pid, complete = false, issues: [String] = []
        for _ in 0..<maximumDepth {
            guard seen.insert(current).inserted else { issues.append("The parent chain contains a cycle; ancestry is incomplete"); break }
            guard let process = byPID[current], let snapshot = process.sampledIdentity, !process.executableFromArgv,
                  snapshot.pid == process.pid, snapshot.uid == process.uid, snapshot.executable == process.executable,
                  identity(current) == snapshot else {
                if captured.isEmpty { throw Unavailable() }
                issues.append("An ancestor could not be verified; the visible chain is incomplete"); break
            }
            captured.append(process)
            if process.ppid == 0 { complete = true; break }
            current = process.ppid
        }
        if !complete && captured.count == maximumDepth { issues.append("The parent-chain depth limit was reached") }
        let observation = target.uid == uid ? paths(pid) : nil
        let listening = target.uid == uid ? listeners(pid) : nil
        let sleep = target.uid == uid ? sleepAssertions(pid) : nil
        let services = target.uid == uid ? launchServices(pid) : nil
        // Verify relationships too: a live child can be reparented without changing its identity.
        for process in captured {
            guard let expected = process.sampledIdentity, identity(process.pid) == expected,
                  parent(process.pid) == process.ppid, identity(process.pid) == expected else { throw Unavailable() }
        }
        if captured.contains(where: { $0.uid != uid }) { issues.append("Arguments and working directories of other users are not inspected") }
        if observation == nil || observation?.complete == false { issues.append("Open-path inspection is incomplete; no empty-path guarantee is made") }
        if observation?.truncated == true || (observation?.paths.count ?? 0) > 100 { issues.append("Observed paths were limited to the inspection budget") }
        if captured.contains(where: { $0.uid == uid && ($0.argv.count > 64 || $0.argv.contains(where: { $0.count > 2048 })) }) {
            issues.append("Long argument lists were shortened")
        }
        let nodes = captured.map { process in
            Node(pid: process.pid, parentPID: process.ppid, uid: process.uid, started: process.sampledIdentity!.started,
                 name: displayed(process.name), executable: displayed(process.sampledIdentity!.executable),
                 args: process.uid == uid ? Redact.arguments(process.argv).prefix(64).map { displayed(String($0.prefix(2048))) } : [],
                 workingDirectory: process.uid == uid ? process.cwd.map(displayed) : nil)
        }
        var application: String?, attribution = Attribution.unknown
        for (index, process) in captured.enumerated() {
            guard let executable = process.executable, let end = executable.range(of: ".app/") else { continue }
            application = displayed(String(executable[..<end.lowerBound]) + ".app")
            attribution = index == 0 ? .executableLocation : .ancestorApplication
            break
        }
        let shortenedPaths = (observation?.paths.count ?? 0) > 100
        return .init(pid: pid, sampled: Date(), chain: nodes, chainComplete: complete, application: application,
                     attribution: attribution, observedPaths: observation.map { Array($0.paths.prefix(100)).map(displayed) },
                     pathQueriesComplete: (observation?.complete ?? false) && !shortenedPaths,
                     pathsTruncated: (observation?.truncated ?? false) || shortenedPaths, issues: issues, listeners: listening, sleepAssertions: sleep, launchServices: services)
    }
}
