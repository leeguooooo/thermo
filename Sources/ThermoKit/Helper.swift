import Foundation
import Security

public enum HelperConstants {
    public static let label = "dev.thermo.helper"
    public static let machService = "dev.thermo.helper"
    public static let installedBinary = "/Library/PrivilegedHelperTools/dev.thermo.helper"
    public static let launchdPlist = "/Library/LaunchDaemons/dev.thermo.helper.plist"
    public static let protocolVersion = "1"
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

/// XPC interface exported by the root helper. Policies travel as JSON.
@objc public protocol ThermoHelperProtocol {
    func version(reply: @escaping (String) -> Void)
    /// fan == -1 applies to every fan. Reply carries an error message or nil.
    func setPolicy(fan: Int, policy: Data, reply: @escaping (String?) -> Void)
    /// JSON-encoded [Int: FanPolicy].
    func policies(reply: @escaping (Data) -> Void)
}

public enum PolicyCoding {
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
public final class HelperClient {
    private let connection: NSXPCConnection

    public init() {
        connection = NSXPCConnection(machServiceName: HelperConstants.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ThermoHelperProtocol.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    private func proxy(_ onError: @escaping (Error) -> Void) -> ThermoHelperProtocol? {
        connection.remoteObjectProxyWithErrorHandler(onError) as? ThermoHelperProtocol
    }

    // MARK: async

    public func version() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let once = Once()
            guard let p = proxy({ e in once.run { cont.resume(throwing: FanControlError.helperUnavailable(e.localizedDescription)) } }) else {
                return once.run { cont.resume(throwing: FanControlError.helperUnavailable("no proxy")) }
            }
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
            p.policies { d in once.run { cont.resume(returning: d) } }
        }
        return try PolicyCoding.decoder().decode([Int: FanPolicy].self, from: data)
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

    static func plist(binary: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(HelperConstants.label)</string>
            <key>ProgramArguments</key><array><string>\(binary)</string></array>
            <key>MachServices</key><dict><key>\(HelperConstants.machService)</key><true/></dict>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardErrorPath</key><string>/var/log/dev.thermo.helper.log</string>
        </dict>
        </plist>
        """
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func install(from binary: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dev.thermo.helper.\(getpid()).plist")
        try plist(binary: HelperConstants.installedBinary).write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bin = shellQuote(HelperConstants.installedBinary)
        let pl = shellQuote(HelperConstants.launchdPlist)
        let script = [
            "/bin/launchctl bootout system/\(HelperConstants.label) 2>/dev/null",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 755 \(shellQuote(binary.path)) \(bin)",
            "/usr/bin/install -o root -g wheel -m 644 \(shellQuote(tmp.path)) \(pl)",
            "/bin/launchctl bootstrap system \(pl)",
        ].joined(separator: "; ")
        try runPrivileged(script)
    }

    public static func uninstall() throws {
        let script = [
            "/bin/launchctl bootout system/\(HelperConstants.label) 2>/dev/null",
            "/bin/rm -f \(shellQuote(HelperConstants.launchdPlist)) \(shellQuote(HelperConstants.installedBinary))",
            "true",
        ].joined(separator: "; ")
        try runPrivileged(script)
    }

    static func runPrivileged(_ shell: String) throws {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
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
