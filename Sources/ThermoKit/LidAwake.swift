import Foundation
import IOKit

/// "Keep awake with the lid closed": macOS only lets root stop lid-close sleep (the same switch as
/// `pmset disablesleep`), so the helper owns it. It is never carried across a helper restart, it
/// restores whatever the user had before, and it turns itself off when the Mac gets hot, the sensors
/// go quiet, or the battery runs low — a closed lid in a bag is the case this is guarding.
public struct LidAwakeState: Codable, Sendable, Equatable {
    public struct AutoOff: Codable, Sendable, Equatable {
        public var time: Date
        /// thermal | battery | noReading
        public var reason: String
        public var detail: String
        public init(time: Date, reason: String, detail: String) { self.time = time; self.reason = reason; self.detail = detail }
    }
    public var armed = false
    public var since: Date?
    public var lidClosed: Bool?
    public var lastAutoOff: AutoOff?
    /// The hottest compute sensor at which it turns itself off.
    public var limit: Double
    public init(limit: Double) { self.limit = limit }
}

/// The rules, without I/O. One tick every 10 s in the helper.
public struct LidAwakeGuard: Sendable {
    public private(set) var state: LidAwakeState
    /// Below the fan failsafe ceiling, so this gives up before the fans have to.
    public static func limit(for limits: SafetyLimits) -> Double { limits.ceiling - 10 }
    public static let batteryFloor = 20.0
    /// Consecutive ticks before acting: one hot spike or one missed reading is not enough.
    public static let hotTicksToTrip = 2
    public static let missingTicksToTrip = 3
    private var hot = 0, missing = 0

    public init(limits: SafetyLimits) { state = LidAwakeState(limit: Self.limit(for: limits)) }

    public mutating func arm(now: Date = Date()) {
        guard !state.armed else { return }
        state.armed = true; state.since = now; hot = 0; missing = 0
    }

    public mutating func disarm() {
        state.armed = false; state.since = nil; hot = 0; missing = 0
    }

    /// Returns the reason when it should turn itself off now; never turns itself back on.
    public mutating func tick(hottest: Double?, battery: BatteryInfo?, lidClosed: Bool?, now: Date = Date()) -> LidAwakeState.AutoOff? {
        state.lidClosed = lidClosed
        guard state.armed else { return nil }
        var reason: LidAwakeState.AutoOff?
        if let t = hottest, t.isFinite {
            missing = 0
            hot = t >= state.limit ? hot + 1 : 0
            if hot >= Self.hotTicksToTrip {
                reason = .init(time: now, reason: "thermal", detail: String(format: "%.0f °C ≥ %.0f °C", t, state.limit))
            }
        } else {
            missing += 1
            if missing >= Self.missingTicksToTrip {
                reason = .init(time: now, reason: "noReading", detail: "no temperature reading for \(missing) checks")
            }
        }
        if reason == nil, let b = battery, !b.externalPower, !b.charging, let p = b.percent, p <= Self.batteryFloor {
            reason = .init(time: now, reason: "battery", detail: String(format: "battery %.0f%% on battery power", p))
        }
        if let reason {
            disarm()
            state.lastAutoOff = reason
        }
        return reason
    }
}

/// The system switch itself and the lid state, behind functions so tests never touch the real Mac.
public struct SleepSwitch: Sendable {
    public var read: @Sendable () -> Bool?
    public var write: @Sendable (Bool) throws -> Void

    public init(read: @escaping @Sendable () -> Bool?, write: @escaping @Sendable (Bool) throws -> Void) {
        self.read = read; self.write = write
    }

    /// `pmset -g` lists `SleepDisabled 1` while lid-close sleep is off.
    public static let system = SleepSwitch(read: {
        let p = Process(); let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g"]; p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first == "SleepDisabled", parts.count >= 2 { return parts[1] == "1" }
        }
        return false
    }, write: { on in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FanControlError.helper("pmset disablesleep exited \(p.terminationStatus)") }
    })

    /// `AppleClamshellState` on the power-management root; no privileges needed. nil on desktops.
    public static func lidClosed() -> Bool? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard let value = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool else { return nil }
        return value
    }
}

/// Owns the switch for the helper: remembers what the user had before the first arm (on disk, so a
/// crash still restores it), and puts it back on disarm, on helper start and on helper exit.
public final class LidAwakeController: @unchecked Sendable {
    public private(set) var guardState: LidAwakeGuard
    let sleep: SleepSwitch
    let originalFile: String
    let log: (String) -> Void

    public static let originalPath = "/Library/Application Support/dev.thermo/sleep-disabled-before.json"

    public init(limits: SafetyLimits, sleep: SleepSwitch = .system, originalFile: String = LidAwakeController.originalPath,
                log: @escaping (String) -> Void = { _ in }) {
        guardState = LidAwakeGuard(limits: limits); self.sleep = sleep; self.originalFile = originalFile; self.log = log
    }

    public var state: LidAwakeState { guardState.state }

    struct Original: Codable { var sleepDisabled: Bool }

    func savedOriginal() -> Bool? {
        guard let data = FileManager.default.contents(atPath: originalFile),
              let o = try? JSONDecoder().decode(Original.self, from: data) else { return nil }
        return o.sleepDisabled
    }

    /// Helper start and exit: never carry "armed" across; put back what the user had.
    public func restoreOriginal(reason: String) {
        guard let original = savedOriginal() else { return }
        do {
            try sleep.write(original)
            try? FileManager.default.removeItem(atPath: originalFile)
            log("lid-awake: \(reason); sleep setting restored to disablesleep \(original ? 1 : 0)")
        } catch {
            log("lid-awake: \(reason); could not restore sleep setting: \(error)")
        }
        guardState.disarm()
    }

    public func set(_ on: Bool, now: Date = Date()) throws {
        if on {
            guard !state.armed else { return }
            if savedOriginal() == nil {
                guard let before = sleep.read() else { throw FanControlError.helper("cannot read the current sleep setting") }
                let dir = (originalFile as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(Original(sleepDisabled: before))
                guard FileManager.default.createFile(atPath: originalFile, contents: data, attributes: [.posixPermissions: 0o644]) else {
                    throw FanControlError.helper("cannot record the current sleep setting")
                }
            }
            try sleep.write(true)
            guardState.arm(now: now)
            log("lid-awake: on")
        } else {
            restoreOriginal(reason: "turned off")
        }
    }

    /// One safety check; turns itself off (restoring the user's setting) when a rule trips.
    @discardableResult
    public func tick(hottest: Double?, battery: BatteryInfo?, lidClosed: Bool?, now: Date = Date()) -> LidAwakeState.AutoOff? {
        guard let reason = guardState.tick(hottest: hottest, battery: battery, lidClosed: lidClosed, now: now) else { return nil }
        let last = reason
        restoreOriginal(reason: "auto-off (\(reason.reason): \(reason.detail))")
        // restoreOriginal disarms; keep the reason for the app to show.
        guardState.noteAutoOff(last)
        return reason
    }
}

extension LidAwakeGuard {
    mutating func noteAutoOff(_ reason: LidAwakeState.AutoOff) { state.lastAutoOff = reason }
}
