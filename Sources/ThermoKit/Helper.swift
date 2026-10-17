import Foundation
import Security

public enum AWDLClientError: LocalizedError, CustomStringConvertible {
    case notStarted(String)
    public var errorDescription: String? { switch self { case .notStarted(let message): return message } }
    public var description: String { errorDescription ?? "AWDL request was not started" }
}

public enum HelperConstants {
    public static let label = "dev.thermo.helper"
    public static let machService = "dev.thermo.helper"
    public static let installedBinary = "/Library/PrivilegedHelperTools/dev.thermo.helper"
    public static let launchdPlist = "/Library/LaunchDaemons/dev.thermo.helper.plist"
    public static let protocolVersion = "8"
    /// Reported by the helper: "<protocol>/<app version>".
    public static var version: String { "\(protocolVersion)/\(ThermoVersion.string)" }
    /// Plist bundled at Contents/Library/LaunchDaemons for SMAppService registration.
    public static let bundledPlistName = "dev.thermo.helper.plist"

    static let identifiers = #"(identifier "dev.thermo.cli" or identifier "dev.thermo.app")"#

    /// XPC client requirement. When this process is Developer ID signed, clients must be
    /// signed by the same team; ad-hoc builds fall back to identifier matching only.
    public static var clientRequirement: String {
        guard let team = CodeSignature.teamIdentifier() else { return identifiers }
        return #"anchor apple generic and certificate leaf[subject.OU] = ""# + team + #"" and "# + identifiers
    }
}

public enum CodeSignature {
    /// Team ID of the running process's signature, or nil for unsigned / ad-hoc code.
    public static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// A helper installed with the administrator password runs from a root-owned copy in
/// /Library/PrivilegedHelperTools, so app updates would leave it behind. It keeps itself current
/// instead: when the helper inside the app (`--source`) differs from the running copy and is
/// signed by the same team, it is copied in, checked again, and swapped in atomically; the helper
/// then exits and launchd starts the new one. One password, ever. Ad-hoc builds never update.
public enum HelperSelfUpdate {
    /// Only our own Developer ID helper may replace the running one.
    public static func requirement(team: String) -> String {
        #"anchor apple generic and identifier "dev.thermo.helper" and certificate leaf[subject.OU] = ""# + team + #"""#
    }

    public static func satisfies(_ path: String, team: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement(team: team) as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req) == errSecSuccess
    }

    /// The app's helper may only come from an Applications folder, as a real file (no symlink).
    public static func acceptableSource(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        let r = String(cString: real)
        let ok = r.hasPrefix("/Applications/") || r.range(of: #"^/Users/[^/]+/Applications/"#, options: .regularExpression) != nil
        return ok && !r.contains("/AppTranslocation/") ? r : nil
    }

    /// Asks a (verified, root-owned) helper binary for its version.
    static func version(of binary: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["--print-version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        let v = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !v.isEmpty ? v : nil
    }

    public enum Outcome: Equatable { case unchanged, updated(String), rejected(String) }

    /// Replaces `installed` with the app's helper when that is a strictly newer build signed by
    /// `team`. Every check runs on the root-owned staged copy that would actually run.
    public static func update(from source: String, to installed: String, team: String, current: String) -> Outcome {
        let fm = FileManager.default
        // Reported (once per reason by the helper) so a slow update shows where the time went.
        guard let src = acceptableSource(source) else { return .rejected("\(source) is not usable right now (missing, a link, or not in Applications)") }
        guard !fm.contentsEqual(atPath: src, andPath: installed) else { return .unchanged }
        let staged = installed + ".new"
        try? fm.removeItem(atPath: staged)
        defer { try? fm.removeItem(atPath: staged) }
        guard (try? fm.copyItem(atPath: src, toPath: staged)) != nil,
              chown(staged, 0, 0) == 0, chmod(staged, 0o755) == 0 else { return .rejected("could not stage \(src)") }
        guard satisfies(staged, team: team) else { return .rejected("\(src) is not signed by team \(team)") }
        // No downgrades: an older signed helper could bring back a fixed bug.
        guard let v = version(of: staged) else { return .rejected("\(src) did not report a version") }
        guard v.compare(current, options: .numeric) == .orderedDescending else {
            return .rejected("\(src) is version \(v), not newer than \(current)")
        }
        return rename(staged, installed) == 0 ? .updated(v) : .rejected("could not replace \(installed)")
    }
}

/// XPC interface exported by the root helper. Policies travel as JSON.
@objc public protocol ThermoHelperProtocol {
    func version(reply: @escaping (String) -> Void)
    /// fan == -1 applies to every fan. Reply carries an error message or nil.
    func setPolicy(fan: Int, policy: Data, reply: @escaping (String?) -> Void)
    /// JSON-encoded [Int: FanPolicy].
    func policies(reply: @escaping (Data) -> Void)
    /// Keep the Mac awake with the lid closed (protocol 2). Reply carries an error message or nil.
    func setLidAwake(_ on: Bool, reply: @escaping (String?) -> Void)
    /// Protocol 3: the same, choosing whether heat turns it off.
    func setLidAwake(_ on: Bool, heatGuard: Bool, reply: @escaping (String?) -> Void)
    /// JSON-encoded LidAwakeState.
    func lidAwakeState(reply: @escaping (Data) -> Void)
    /// Protocol 4: confirm automatic fan control and fence manual requests for removal.
    func prepareRemoval(_ prepare: Bool, token: String, reply: @escaping (String?) -> Void)
    /// Protocol 5: desired policies, last hardware observations and suspension/fault state.
    func fanControlState(reply: @escaping (Data) -> Void)
    /// Protocol 6. Fixed awdl0 only, owned by this XPC connection.
    func beginAWDL(seconds: Int,sessionID: String,reply: @escaping (String?) -> Void)
    func endAWDL(reply: @escaping (String?) -> Void)
    func awdlState(reply: @escaping (Data) -> Void)
    /// Protocol 7 legacy selector. New clients use protocol 8's public session ID.
    func setBatteryChargePolicy(_ policy: String, reply: @escaping (String?) -> Void)
    /// Protocol 8. Charging policies are held only for this XPC connection.
    func setBatteryChargePolicy(_ policy: String, sessionID: String, reply: @escaping (String?) -> Void)
    func batteryChargeState(reply: @escaping (Data) -> Void)
}

/// The helper's fan policies on disk, so a helper restart (update, reboot) keeps what the user
/// chose. Root-owned: only the helper writes it.
public enum PolicyStore {
    public static let path = "/Library/Application Support/dev.thermo/fan-policies.json"

    public static func save(_ policies: [Int: FanPolicy], to path: String = PolicyStore.path) throws {
        for policy in policies.values { try policy.validate() }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let data = try PolicyCoding.encoder().encode(Dictionary(uniqueKeysWithValues: policies.map { (String($0.key), $0.value) }))
        try data.write(to: url, options: .atomic)
        chmod(path, 0o644)
    }

    /// Saved policies; empty when there are none or the file cannot be read.
    public static func load(from path: String = PolicyStore.path) -> [Int: FanPolicy] {
        guard let data = FileManager.default.contents(atPath: path),
              let raw = try? PolicyCoding.decoder().decode([String: FanPolicy].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, policy -> (Int, FanPolicy)? in
            guard let id = Int(key), id >= 0, String(id) == key,
                  (try? policy.validate()) != nil else { return nil }
            return (id, policy)
        })
    }
}

public enum PolicyCoding {
    static func validatePolicies(_ policies: [Int: FanPolicy]) throws {
        guard policies.keys.allSatisfy({ $0 >= 0 }) else { throw FanControlError.helper("helper returned an invalid fan identifier") }
        for policy in policies.values { try policy.validate() }
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }
}

/// Client for the privileged helper.
public final class HelperClient: @unchecked Sendable {
    /// Made on first use and dropped when invalidated: an invalidated connection never works
    /// again, and it is invalidated whenever the helper's launchd job is replaced (install,
    /// reinstall, switching from Login Items to the password install).
    private var connection: NSXPCConnection?
    private let lock = NSLock()
    private let makeConnection: @Sendable () -> NSXPCConnection

    public init() {
        makeConnection = { NSXPCConnection(machServiceName: HelperConstants.machService, options: .privileged) }
    }

    /// Package tests may use an owned anonymous endpoint; normal clients always use launchd.
    init(makeConnection: @escaping @Sendable () -> NSXPCConnection) { self.makeConnection = makeConnection }

    deinit { connection?.invalidate() }

    private func current() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let c = connection { return c }
        let c = makeConnection()
        c.remoteObjectInterface = NSXPCInterface(with: ThermoHelperProtocol.self)
        c.invalidationHandler = { [weak self, weak c] in self?.drop(c) }
        // Interrupted means the helper exited (update, restart); reconnect on the next call too.
        c.interruptionHandler = { [weak self, weak c] in self?.drop(c) }
        c.resume()
        connection = c
        return c
    }

    private func drop(_ c: NSXPCConnection?) {
        lock.lock(); defer { lock.unlock() }
        if connection === c { connection = nil }
    }

    /// Forget the connection so the next call starts fresh.
    public func reset() {
        lock.lock(); let c = connection; connection = nil; lock.unlock()
        c?.invalidate()
    }

    private func proxy(_ onError: @escaping (Error) -> Void) -> ThermoHelperProtocol? {
        current().remoteObjectProxyWithErrorHandler(onError) as? ThermoHelperProtocol
    }

    /// launchd holds messages for a registered service it will not start (e.g. a Login Items
    /// registration that was never approved), so a call could otherwise wait forever.
    private func deadline(_ seconds: TimeInterval, _ once: Once, _ fail: @escaping () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            once.run {
                // A connection stuck on a job launchd will not start stays stuck; start over next time.
                self?.reset()
                fail()
            }
        }
    }

    // MARK: async

    public func version() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let once = Once()
            guard let p = proxy({ e in once.run { cont.resume(throwing: FanControlError.helperUnavailable(e.localizedDescription)) } }) else {
                return once.run { cont.resume(throwing: FanControlError.helperUnavailable("no proxy")) }
            }
            deadline(3, once) { cont.resume(throwing: FanControlError.helperUnavailable("no answer within 3 s")) }
            p.version { v in once.run { cont.resume(returning: v) } }
        }
    }

    public func setPolicy(_ policy: FanPolicy, fan: Int) async throws {
        let data = try PolicyCoding.encoder().encode(policy)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            guard let p = proxy({ e in once.run { cont.resume(throwing: FanControlError.helperUnavailable(e.localizedDescription)) } }) else {
                return once.run { cont.resume(throwing: FanControlError.helperUnavailable("no proxy")) }
            }
            // Unlocking manual fan control on Apple Silicon can take ~5 s.
            deadline(10, once) { cont.resume(throwing: FanControlError.helperUnavailable("no answer within 10 s")) }
            p.setPolicy(fan: fan, policy: data) { err in
                once.run {
                    if let err { cont.resume(throwing: FanControlError.helper(err)) } else { cont.resume() }
                }
            }
        }
    }

    public func policies() async throws -> [Int: FanPolicy] {
        let data: Data = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            guard let p = proxy({ e in once.run { cont.resume(throwing: FanControlError.helperUnavailable(e.localizedDescription)) } }) else {
                return once.run { cont.resume(throwing: FanControlError.helperUnavailable("no proxy")) }
            }
            deadline(3, once) { cont.resume(throwing: FanControlError.helperUnavailable("no answer within 3 s")) }
            p.policies { d in once.run { cont.resume(returning: d) } }
        }
        return try FanPolicyReply.decode(data)
    }

    public func setLidAwake(_ on: Bool, heatGuard: Bool = true) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            guard let p = proxy({ e in once.run { cont.resume(throwing: FanControlError.helperUnavailable(e.localizedDescription)) } }) else {
                return once.run { cont.resume(throwing: FanControlError.helperUnavailable("no proxy")) }
            }
            deadline(5, once) { cont.resume(throwing: FanControlError.helperUnavailable("no answer within 5 s")) }
            p.setLidAwake(on, heatGuard: heatGuard) { err in
                once.run { if let err { cont.resume(throwing: FanControlError.helper(err)) } else { cont.resume() } }
            }
        }
    }

    public func lidAwakeState() async throws -> LidAwakeState {
        let data: Data = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            guard let p = proxy({ e in once.run { cont.resume(throwing: FanControlError.helperUnavailable(e.localizedDescription)) } }) else {
                return once.run { cont.resume(throwing: FanControlError.helperUnavailable("no proxy")) }
            }
            deadline(3, once) { cont.resume(throwing: FanControlError.helperUnavailable("no answer within 3 s")) }
            p.lidAwakeState { d in once.run { cont.resume(returning: d) } }
        }
        return try PolicyCoding.decoder().decode(LidAwakeState.self, from: data)
    }

    public func fanControlState() async throws -> FanControlState {
        let v = try await version()
        guard let major = Int(v.split(separator: "/").first ?? ""), major >= 5 else {
            return FanControlState(policies: try await policies(), observationsSupported: false)
        }
        let data: Data = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            guard let p = proxy({ error in once.run { cont.resume(throwing: error) } }) else {
                return once.run { cont.resume(throwing: FanControlError.helperUnavailable("no proxy")) }
            }
            deadline(3, once) { cont.resume(throwing: FanControlError.helperUnavailable("fan state query timed out")) }
            p.fanControlState { data in once.run { cont.resume(returning: data) } }
        }
        let state = try PolicyCoding.decoder().decode(FanControlState.self, from: data)
        try PolicyCoding.validatePolicies(state.policies)
        return state
    }

    public func prepareRemoval(_ prepare: Bool, token: String) async throws {
        let v = try await version()
        guard let major = Int(v.split(separator: "/").first ?? ""), major >= 7 else {
            throw FanControlError.helper("helper cannot confirm safe removal; update the helper first")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            guard let p = proxy({ error in once.run { cont.resume(throwing: error) } }) else {
                return once.run { cont.resume(throwing: FanControlError.helperUnavailable("no proxy")) }
            }
            deadline(10, once) { cont.resume(throwing: FanControlError.helperUnavailable("removal preparation timed out")) }
            p.prepareRemoval(prepare, token: token) { error in
                once.run {
                    if let error { cont.resume(throwing: FanControlError.helper(error)) } else { cont.resume() }
                }
            }
        }
    }

    private func requireAWDL() async throws {
        let value=try await version()
        guard let major=Int(value.split(separator:"/").first ?? ""),major >= 6 else {
            throw AWDLError("Update Thermo's helper before using AWDL sessions.")
        }
    }
    private func requireBatteryCharge() async throws {
        let value = try await version()
        guard let major = Int(value.split(separator: "/").first ?? ""), major >= 8 else {
            throw BatteryGateError("Update Thermo's helper before using charging control")
        }
    }
    public func setBatteryChargePolicy(_ policy: BatteryChargePolicy, sessionID: String = UUID().uuidString) async throws {
        guard UUID(uuidString: sessionID) != nil else { throw BatteryChargeClientError.notStarted("Invalid charging session identifier") }
        do { try await requireBatteryCharge() }
        catch { throw BatteryChargeClientError.notStarted(error.localizedDescription) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            guard let p = proxy({ error in once.run { continuation.resume(throwing: error) } }) else {
                return once.run { continuation.resume(throwing: BatteryGateError("Charging helper is unavailable")) }
            }
            // deadline() invalidates the owning connection before reporting timeout.
            deadline(8, once) { continuation.resume(throwing: BatteryGateError("Charging request timed out; verify recovery before retrying")) }
            p.setBatteryChargePolicy(policy.rawValue, sessionID: sessionID) { error in once.run {
                if let error { continuation.resume(throwing: BatteryGateError(error)) } else { continuation.resume() }
            } }
        }
    }
    public func batteryChargeState() async throws -> BatteryChargeState {
        try await requireBatteryCharge()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            guard let p = proxy({ error in once.run { continuation.resume(throwing: error) } }) else {
                return once.run { continuation.resume(throwing: BatteryGateError("Charging helper is unavailable")) }
            }
            deadline(4, once) { continuation.resume(throwing: BatteryGateError("Charging state query timed out")) }
            p.batteryChargeState { data in once.run { continuation.resume(returning: data) } }
        }
        let state = try PolicyCoding.decoder().decode(BatteryChargeState.self, from: data)
        guard state.percent.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
              state.phase != .holding || (state.policy == .limit80 && state.gate == .inhibited && state.ownership == .owned),
              state.policy != .off || (!state.ownedByCaller && state.sessionID == nil),
              state.policy == .off || state.sessionID.flatMap(UUID.init(uuidString:)) != nil else { throw BatteryGateError("Invalid charging state reply") }
        return state
    }
    public func beginAWDL(seconds: Int,sessionID: String = UUID().uuidString) async throws {
        guard (60...3600).contains(seconds),UUID(uuidString:sessionID) != nil else { throw AWDLClientError.notStarted("Invalid AWDL session duration or identifier") }
        do { try await requireAWDL() }
        catch { throw AWDLClientError.notStarted((error as? FanControlError)?.description ?? error.localizedDescription) }
        try await awdlAction { $0.beginAWDL(seconds:seconds,sessionID:sessionID,reply:$1) }
    }
    public func endAWDL() async throws {
        try await requireAWDL()
        try await awdlAction { $0.endAWDL(reply:$1) }
    }
    private func awdlAction(_ send: @escaping (ThermoHelperProtocol,@escaping (String?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            let once=Once()
            guard let p=proxy({ error in once.run { continuation.resume(throwing:error) } }) else {
                return once.run { continuation.resume(throwing:FanControlError.helperUnavailable("no proxy")) }
            }
            deadline(8,once) { continuation.resume(throwing:FanControlError.helperUnavailable("AWDL request timed out; recovery must be checked")) }
            send(p) { error in once.run {
                if let error { continuation.resume(throwing:AWDLError(error)) } else { continuation.resume() }
            } }
        }
    }
    public func awdlState() async throws -> AWDLSessionState {
        try await requireAWDL()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let once=Once()
            guard let p=proxy({ error in once.run { continuation.resume(throwing:error) } }) else {
                return once.run { continuation.resume(throwing:FanControlError.helperUnavailable("no proxy")) }
            }
            deadline(4,once) { continuation.resume(throwing:FanControlError.helperUnavailable("AWDL state query timed out")) }
            p.awdlState { data in once.run { continuation.resume(returning:data) } }
        }
        let state=try PolicyCoding.decoder().decode(AWDLSessionState.self,from:data)
        guard state.interface.map({ $0.index > 0 }) ?? true,
              state.remainingSeconds.map({ (0...3600).contains($0) }) ?? true,
              state.phase != .active || state.remainingSeconds != nil,
              state.sessionID.map({ UUID(uuidString:$0) != nil }) ?? true,
              state.phase != .active || state.sessionID != nil,
              state.phase != .idle || state.sessionID == nil,
              state.phase == .active || (!state.ownedByCaller && state.remainingSeconds == nil),
              state.interfaceQueryComplete || state.interface == nil else { throw AWDLError("Invalid AWDL state reply") }
        return state
    }

    public func withRemovalPreparation(_ remove: () throws -> Void) throws {
        let token = UUID().uuidString
        try HelperRemovalOperation.run(
            prepare: { try self.blocking(timeout: 15) { try await $0.prepareRemoval(true, token: token) } },
            remove: remove,
            cancel: { try self.blocking(timeout: 15) { try await $0.prepareRemoval(false, token: token) } })
    }

    // MARK: blocking (CLI)

    public func blocking<T>(timeout: TimeInterval = 5, _ op: @escaping (HelperClient) async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error> = .failure(FanControlError.helperUnavailable("timed out"))
        let task = Task {
            do { result = .success(try await op(self)) } catch { result = .failure(error) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw FanControlError.helperUnavailable("timed out after \(Int(timeout))s")
        }
        return try result.get()
    }
}

/// Guards a continuation against double resume (XPC may call both reply and error handler).
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

/// Installs / removes the LaunchDaemon using an administrator prompt.
public enum HelperInstaller {
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: HelperConstants.installedBinary)
            && FileManager.default.fileExists(atPath: HelperConstants.launchdPlist)
    }

    /// Finds the helper binary shipped next to the running executable or inside Thermo.app.
    public static func locateHelperBinary() -> URL? {
        var candidates: [URL] = []
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let dir = exe.deletingLastPathComponent()
            candidates.append(dir.appendingPathComponent("thermo-helper"))
            candidates.append(dir.deletingLastPathComponent().appendingPathComponent("Helpers/thermo-helper"))
        }
        candidates.append(URL(fileURLWithPath: "/Applications/Thermo.app/Contents/Helpers/thermo-helper"))
        candidates.append(URL(fileURLWithPath: NSHomeDirectory() + "/Applications/Thermo.app/Contents/Helpers/thermo-helper"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func plist(binary: String, source: String? = nil) -> String {
        let args = ([binary] + (source.map { ["--source", $0] } ?? []))
            .map { "<string>\($0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</string>" }
            .joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(HelperConstants.label)</string>
            <key>ProgramArguments</key><array>\(args)</array>
            <key>MachServices</key><dict><key>\(HelperConstants.machService)</key><true/></dict>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardErrorPath</key><string>/var/log/dev.thermo.helper.log</string>
        </dict>
        </plist>
        """
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Stage and back up before stopping the registered daemon. The EXIT handler
    /// restores the previous files on an activation failure; failed recovery keeps
    /// the private transaction directory for manual repair instead of deleting it.
    static func transactionalInstallationScript(binary: String, plist: String,
                                                installedBinary: String = HelperConstants.installedBinary,
                                                installedPlist: String = HelperConstants.launchdPlist,
                                                owner: String = "root", group: String = "wheel",
                                                launchctl: String = "/bin/launchctl") -> String {
        let bin = shellQuote(installedBinary), pl = shellQuote(installedPlist)
        let folder = shellQuote((installedBinary as NSString).deletingLastPathComponent)
        let plistFolder = shellQuote((installedPlist as NSString).deletingLastPathComponent)
        let tool = shellQuote(launchctl), service = shellQuote("system/" + HelperConstants.label)
        let template = shellQuote((installedBinary as NSString).deletingLastPathComponent + "/.dev.thermo.install.XXXXXX")
        return """
        set -e
        /bin/mkdir -p \(folder) \(plistFolder)
        transaction=$(/usr/bin/mktemp -d \(template))
        had_binary=0
        had_plist=0
        registered=0
        activating=0
        finish_installation() {
            result=$?
            trap - EXIT HUP INT TERM
            set +e
            recovery_failed=0
            if [ "$result" -ne 0 ] && [ "$activating" -eq 1 ]; then
                \(tool) bootout \(service) >/dev/null 2>&1
                if [ "$had_binary" -eq 1 ]; then
                    /bin/cp -p "$transaction/old-helper" "$transaction/restore-helper" && /bin/mv -f "$transaction/restore-helper" \(bin) || recovery_failed=1
                else
                    /bin/rm -f \(bin) || recovery_failed=1
                fi
                if [ "$had_plist" -eq 1 ]; then
                    /bin/cp -p "$transaction/old.plist" "$transaction/restore.plist" && /bin/mv -f "$transaction/restore.plist" \(pl) || recovery_failed=1
                else
                    /bin/rm -f \(pl) || recovery_failed=1
                fi
                if [ "$registered" -eq 1 ]; then
                    if [ "$recovery_failed" -eq 0 ]; then
                        \(tool) bootstrap system \(pl) || recovery_failed=1
                    else
                        recovery_failed=1
                    fi
                fi
            fi
            if [ "$recovery_failed" -ne 0 ]; then
                echo "Helper installation failed; recovery is incomplete. Repair files retained at $transaction" >&2
            else
                /bin/rm -rf "$transaction"
            fi
            exit "$result"
        }
        trap finish_installation EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        test ! -L \(bin)
        test ! -L \(pl)
        if [ -e \(bin) ]; then
            test -f \(bin)
            /bin/cp -p \(bin) "$transaction/old-helper"
            had_binary=1
        fi
        if [ -e \(pl) ]; then
            test -f \(pl)
            /bin/cp -p \(pl) "$transaction/old.plist"
            had_plist=1
        fi
        /usr/bin/install -o \(shellQuote(owner)) -g \(shellQuote(group)) -m 755 \(shellQuote(binary)) "$transaction/new-helper"
        /usr/bin/install -o \(shellQuote(owner)) -g \(shellQuote(group)) -m 644 \(shellQuote(plist)) "$transaction/new.plist"
        /usr/bin/plutil -lint "$transaction/new.plist" >/dev/null
        if \(tool) print \(service) >/dev/null 2>&1; then
            test "$had_binary" -eq 1
            test "$had_plist" -eq 1
            registered=1
            \(tool) bootout \(service)
        fi
        activating=1
        /bin/mv -f "$transaction/new-helper" \(bin)
        /bin/mv -f "$transaction/new.plist" \(pl)
        \(tool) bootstrap system \(pl)
        """
    }

    public static func install(from binary: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dev.thermo.helper.\(getpid()).plist")
        // Keep a pointer to the app's helper so the installed copy can update itself (not from a
        // mounted DMG or a translocated copy, which go away).
        let src = binary.resolvingSymlinksInPath().path
        let source = src.hasPrefix("/Volumes/") || src.contains("/AppTranslocation/") ? nil : src
        try plist(binary: HelperConstants.installedBinary, source: source).write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let script = transactionalInstallationScript(binary: binary.path, plist: tmp.path)
        try runPrivileged(script)
    }

    static func removalScript(bootout: String = "/bin/launchctl bootout system/\(HelperConstants.label)",
                              paths: [String] = [HelperConstants.launchdPlist, HelperConstants.installedBinary, PolicyStore.path]) -> String {
        ([bootout, "/bin/rm -f " + paths.map(shellQuote).joined(separator: " ")]
            + paths.map { "test ! -e \(shellQuote($0)) && test ! -L \(shellQuote($0))" }).joined(separator: " && ")
    }

    public static func uninstall() throws {
        let script = removalScript()
        try HelperClient().withRemovalPreparation { try runPrivileged(script) }
    }

    static func privilegedAppleScript(_ shell: String) -> String {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    static func runPrivileged(_ shell: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", privilegedAppleScript(shell)]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw FanControlError.helper(msg.contains("-128") ? "cancelled by user" : "privileged install failed: \(msg)")
        }
    }
}
