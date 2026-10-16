import Foundation
import ThermoL10n

enum CleanScreenDuration: String, CaseIterable, Identifiable {
    case oneMinute, twoMinutes, fiveMinutes, manual
    var id: String { rawValue }
    var seconds: TimeInterval? {
        switch self { case .oneMinute: return 60; case .twoMinutes: return 120; case .fiveMinutes: return 300; case .manual: return nil }
    }
    var label: String {
        switch self { case .oneMinute: return tr("1 minute"); case .twoMinutes: return tr("2 minutes"); case .fiveMinutes: return tr("5 minutes"); case .manual: return tr("Exit manually") }
    }
}

/// Monotonic time only. Repeated key-down events cannot restart or create a hold.
/// No typed text, key history or event objects are retained.
struct CleanScreenSession {
    enum Finish: Equatable { case duration, escape, pointer }
    let started: TimeInterval
    let duration: CleanScreenDuration
    private(set) var escapeStarted: TimeInterval?
    private(set) var pointerStarted: TimeInterval?
    static let holdDuration: TimeInterval = 3
    mutating func key(_ code: Int64, down: Bool, repeated: Bool, modified: Bool, now: TimeInterval) {
        guard code == 53 else { return }
        if !down || modified { escapeStarted = nil }
        else if !repeated, escapeStarted == nil { escapeStarted = now }
    }
    mutating func modifiersChanged() { escapeStarted = nil }
    mutating func pointer(_ down: Bool, now: TimeInterval) { pointerStarted = down ? pointerStarted ?? now : nil }
    func remaining(_ now: TimeInterval) -> TimeInterval? { duration.seconds.map { max(0, $0 - max(0, now - started)) } }
    func holdProgress(_ now: TimeInterval) -> Double {
        [escapeStarted, pointerStarted].compactMap { $0 }.map { min(1, max(0, now - $0) / Self.holdDuration) }.max() ?? 0
    }
    func finish(_ now: TimeInterval) -> Finish? {
        if let remaining = remaining(now), remaining <= 0 { return .duration }
        if let escapeStarted, now - escapeStarted >= Self.holdDuration { return .escape }
        if let pointerStarted, now - pointerStarted >= Self.holdDuration { return .pointer }
        return nil
    }
}


/// Display notifications may also describe changes unrelated to coverage.
/// Compare a normalized topology, not the notification itself.
struct CleanScreenDisplay: Equatable {
    var id: UInt32
    var frame: CGRect
    var scale: Double
    static func normalized(_ displays: [CleanScreenDisplay]) -> [CleanScreenDisplay]? {
        guard !displays.isEmpty, Set(displays.map(\.id)).count == displays.count,
              displays.allSatisfy({ $0.id != 0 && $0.frame.origin.x.isFinite && $0.frame.origin.y.isFinite &&
                  $0.frame.width.isFinite && $0.frame.height.isFinite && $0.frame.width > 0 && $0.frame.height > 0 &&
                  $0.scale.isFinite && $0.scale > 0 }) else { return nil }
        return displays.sorted { $0.id < $1.id }
    }
}
