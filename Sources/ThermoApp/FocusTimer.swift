import Foundation

enum FocusBreak: String { case short, long }

enum FocusPhase: Equatable {
    case idle, focus
    /// 到了休息时间但用户推迟了一分钟；到点后重新进入同一种休息。
    case postponed(FocusBreak)
    case rest(FocusBreak)
    /// 休息时间到了但用户没开自动专注：全屏画面留着，等用户操作。
    case breakFinished
    var isActive: Bool { self != .idle }
    var showsBreakScreen: Bool {
        if case .rest = self { return true }
        return self == .breakFinished
    }
}

struct FocusSettings: Equatable {
    static let focusKey = "focus.focusMinutes"
    static let shortBreakKey = "focus.shortBreakMinutes"
    static let longBreakKey = "focus.longBreakMinutes"
    static let longBreakEveryKey = "focus.longBreakEvery"
    static let progressIconKey = "focus.showProgressIcon"
    static let startOnLaunchKey = "focus.startOnLaunch"
    static let autoStartFocusKey = "focus.autoStartFocusAfterBreak"
    static let minuteRange = 1...180
    static let longBreakEveryRange = 1...12

    var focusMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    var longBreakEvery = 4
    var showProgressIcon = true
    var startOnLaunch = false
    var autoStartFocus = false

    static func read(_ d: UserDefaults = .standard) -> FocusSettings {
        var s = FocusSettings()
        func int(_ key: String, _ range: ClosedRange<Int>, _ fallback: Int) -> Int {
            guard let value = (d.object(forKey: key) as? NSNumber)?.intValue else { return fallback }
            return clamped(value, to: range)
        }
        s.focusMinutes = int(focusKey, minuteRange, s.focusMinutes)
        s.shortBreakMinutes = int(shortBreakKey, minuteRange, s.shortBreakMinutes)
        s.longBreakMinutes = int(longBreakKey, minuteRange, s.longBreakMinutes)
        s.longBreakEvery = int(longBreakEveryKey, longBreakEveryRange, s.longBreakEvery)
        s.showProgressIcon = (d.object(forKey: progressIconKey) as? NSNumber)?.boolValue ?? s.showProgressIcon
        s.startOnLaunch = (d.object(forKey: startOnLaunchKey) as? NSNumber)?.boolValue ?? s.startOnLaunch
        s.autoStartFocus = (d.object(forKey: autoStartFocusKey) as? NSNumber)?.boolValue ?? s.autoStartFocus
        return s
    }

    static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    static func parsedInteger(_ text: String) -> Int? { Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// 不是整数时返回 nil，由调用方保持原值。
    static func integer(from text: String, in range: ClosedRange<Int>) -> Int? {
        parsedInteger(text).map { clamped($0, to: range) }
    }
}

/// 菜单、设置面板和休息画面共用的操作清单，避免各处各写一套按阶段的分支。
enum FocusAction: CaseIterable {
    case startFocus, stopFocus, shortBreak, longBreak, breakNow, postpone, stopBreak, endBreakAndFocus, dismissBreak

    static func available(in phase: FocusPhase) -> [FocusAction] {
        switch phase {
        case .idle: return [.startFocus, .shortBreak, .longBreak]
        case .focus: return [.stopFocus, .shortBreak, .longBreak]
        case .postponed: return [.breakNow, .stopBreak]
        // 提前结束休息不做任何验证（spec 明确排除密码与 Touch ID）。
        case .rest: return [.postpone, .stopBreak, .endBreakAndFocus]
        case .breakFinished: return [.dismissBreak, .startFocus]
        }
    }

    @MainActor func run(_ model: FocusTimerModel) {
        switch self {
        case .startFocus: model.startFocus()
        case .stopFocus, .stopBreak, .dismissBreak: model.stop()
        case .shortBreak: model.startBreak(.short)
        case .longBreak: model.startBreak(.long)
        case .breakNow: if case let .postponed(kind) = model.phase { model.startBreak(kind) }
        case .postpone: model.postpone()
        case .endBreakAndFocus: model.endBreakAndStartFocus()
        }
    }
}

/// 休息画面由计时模型开关；真实实现是覆盖所有显示器的窗口，测试用替身。
@MainActor protocol FocusBreakScreen: AnyObject {
    func show(_ model: FocusTimerModel)
    func hide()
}

/// 专注／休息的唯一计时来源：菜单、菜单栏和休息画面都只读这里。
@MainActor final class FocusTimerModel: ObservableObject {
    static let postponeSeconds: TimeInterval = 60
    @Published private(set) var phase: FocusPhase = .idle
    @Published private(set) var started: Date?
    @Published private(set) var ends: Date?
    /// 本轮循环里已开始的短休息次数，达到设置值后下一次休息为长休息。
    private(set) var shortBreaksTaken = 0
    var onChange: (() -> Void)?
    private let now: () -> Date
    private let settings: () -> FocusSettings
    private let screen: FocusBreakScreen
    private let schedule: (Date, @escaping @MainActor () -> Void) -> Timer
    private var deadline: Timer?
    private var generation = 0

    init(now: @escaping () -> Date = { Date() }, settings: @escaping () -> FocusSettings = { FocusSettings.read() },
         screen: FocusBreakScreen,
         schedule: @escaping (Date, @escaping @MainActor () -> Void) -> Timer = { end, callback in
             let timer = Timer(fire: end, interval: 0, repeats: false) { _ in MainActor.assumeIsolated { callback() } }
             RunLoop.main.add(timer, forMode: .common)
             return timer
         }) {
        self.now = now; self.settings = settings; self.screen = screen; self.schedule = schedule
    }

    var nextBreak: FocusBreak { shortBreaksTaken >= settings().longBreakEvery ? .long : .short }

    func launch() { if settings().startOnLaunch, phase == .idle { startFocus() } }
    func startFocus() { enter(.focus) }
    func startBreak(_ kind: FocusBreak) {
        // 推迟中立即休息是同一次休息，不再计数。
        if phase == .postponed(kind) { enter(.rest(kind)) } else { beginBreak(kind) }
    }
    func stop() { enter(.idle) }
    func endBreakAndStartFocus() {
        guard case .rest = phase else { return }
        enter(.focus)
    }
    func postpone() {
        guard case let .rest(kind) = phase else { return }
        enter(.postponed(kind))
    }

    func remaining(at date: Date) -> TimeInterval? { ends.map { max(0, $0.timeIntervalSince(date)) } }
    func progress(at date: Date) -> Double? {
        guard let started, let ends, ends > started else { return nil }
        return min(1, max(0, date.timeIntervalSince(started) / ends.timeIntervalSince(started)))
    }

    static func countdownText(_ remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func beginBreak(_ kind: FocusBreak) {
        if kind == .long { shortBreaksTaken = 0 } else { shortBreaksTaken += 1 }
        enter(.rest(kind))
    }

    private func seconds(_ phase: FocusPhase) -> TimeInterval? {
        let s = settings()
        switch phase {
        case .idle, .breakFinished: return nil
        case .focus: return TimeInterval(s.focusMinutes * 60)
        case .postponed: return Self.postponeSeconds
        case .rest(.short): return TimeInterval(s.shortBreakMinutes * 60)
        case .rest(.long): return TimeInterval(s.longBreakMinutes * 60)
        }
    }

    private func enter(_ next: FocusPhase) {
        deadline?.invalidate(); deadline = nil
        // 旧计时器即使已排进运行循环也会因代数不符被忽略，快速停止再开始不会串轮。
        generation += 1
        let start = now(), current = generation
        phase = next
        started = next == .idle ? nil : start
        ends = seconds(next).map { start.addingTimeInterval($0) }
        if let ends {
            deadline = schedule(ends) { [weak self] in
                guard let self, self.generation == current else { return }
                self.expire()
            }
        }
        if next.showsBreakScreen { screen.show(self) } else { screen.hide() }
        onChange?()
    }

    private func expire() {
        switch phase {
        case .idle, .breakFinished: break
        case .focus: beginBreak(nextBreak)
        case let .postponed(kind): enter(.rest(kind))
        case .rest: enter(settings().autoStartFocus ? .focus : .breakFinished)
        }
    }
}

struct FocusMenuBarDisplay: Equatable {
    var text: String
    var progress: Double?
    @MainActor static func make(_ model: FocusTimerModel, now: Date, showProgressIcon: Bool) -> FocusMenuBarDisplay? {
        guard model.phase.isActive, let remaining = model.remaining(at: now) else { return nil }
        return FocusMenuBarDisplay(text: FocusTimerModel.countdownText(remaining),
                                   progress: showProgressIcon ? model.progress(at: now) : nil)
    }
}
