import XCTest
@testable import ThermoApp
@testable import ThermoL10n

@MainActor final class FocusTimerTests: XCTestCase {
    final class Screen: FocusBreakScreen {
        var visible = false
        func show(_ model: FocusTimerModel) { visible = true }
        func hide() { visible = false }
    }
    @MainActor final class Harness {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var settings = FocusSettings()
        var callbacks: [(Date, @MainActor () -> Void)] = []
        let screen = Screen()
        lazy var model = FocusTimerModel(now: { [unowned self] in now }, settings: { [unowned self] in settings },
                                         screen: screen, schedule: { [unowned self] end, callback in
            callbacks.append((end, callback))
            return Timer(fire: end, interval: 0, repeats: false) { _ in }
        })
        func fireLatest() {
            guard let (end, callback) = callbacks.last else { return XCTFail("nothing scheduled") }
            now = end; callback()
        }
    }

    func testFocusEndsIntoShortBreakWithFullScreenRest() {
        let h = Harness()
        h.model.startFocus()
        XCTAssertEqual(h.model.phase, .focus)
        XCTAssertEqual(h.model.remaining(at: h.now), 25 * 60)
        XCTAssertFalse(h.screen.visible)
        h.fireLatest()
        XCTAssertEqual(h.model.phase, .rest(.short))
        XCTAssertEqual(h.model.remaining(at: h.now), 5 * 60)
        XCTAssertTrue(h.screen.visible)
    }

    func testBreakEndingKeepsTheFullScreenAndWaitsForTheUserByDefault() {
        let h = Harness()
        XCTAssertFalse(h.settings.autoStartFocus)
        h.model.startFocus(); h.fireLatest()
        let scheduled = h.callbacks.count
        h.fireLatest()
        XCTAssertEqual(h.model.phase, .breakFinished)
        XCTAssertTrue(h.screen.visible)
        XCTAssertNil(h.model.remaining(at: h.now))
        XCTAssertEqual(h.callbacks.count, scheduled, "waiting for the user must not schedule anything")
        XCTAssertEqual(FocusAction.available(in: .breakFinished), [.dismissBreak, .startFocus])
    }

    func testWaitingBreakScreenClosesIntoIdleOrANewFocus() {
        let h = Harness()
        h.model.startFocus(); h.fireLatest(); h.fireLatest()
        FocusAction.dismissBreak.run(h.model)
        XCTAssertEqual(h.model.phase, .idle); XCTAssertFalse(h.screen.visible)
        h.model.startFocus(); h.fireLatest(); h.fireLatest()
        FocusAction.startFocus.run(h.model)
        XCTAssertEqual(h.model.phase, .focus); XCTAssertFalse(h.screen.visible)
    }

    func testBreakEndingStartsTheNextFocusWhenAutoStartIsOn() {
        let h = Harness(); h.settings.autoStartFocus = true
        h.model.startFocus(); h.fireLatest(); h.fireLatest()
        XCTAssertEqual(h.model.phase, .focus)
        XCTAssertFalse(h.screen.visible)
        XCTAssertEqual(h.model.remaining(at: h.now), 25 * 60)
    }

    func testTypedLengthsAreIntegersClampedToTheAllowedRange() {
        let range = FocusSettings.minuteRange
        XCTAssertEqual(FocusSettings.integer(from: " 45 ", in: range), 45)
        XCTAssertEqual(FocusSettings.integer(from: "0", in: range), 1)
        XCTAssertEqual(FocusSettings.integer(from: "999", in: range), 180)
        for invalid in ["", "abc", "12.5"] { XCTAssertNil(FocusSettings.integer(from: invalid, in: range), invalid) }
    }

    func testLongBreakFollowsTheConfiguredNumberOfShortBreaks() {
        let h = Harness(); h.settings.longBreakEvery = 2; h.settings.longBreakMinutes = 20
        var breaks: [FocusPhase] = []
        for _ in 0..<4 {
            h.model.startFocus(); h.fireLatest()
            breaks.append(h.model.phase)
            h.fireLatest()
        }
        XCTAssertEqual(breaks, [.rest(.short), .rest(.short), .rest(.long), .rest(.short)])
    }

    func testFocusCanBeStoppedOrSwitchedEarlyToEitherBreak() {
        let h = Harness(); h.settings.longBreakMinutes = 15
        h.model.startFocus(); h.model.stop()
        XCTAssertEqual(h.model.phase, .idle)
        h.model.startFocus(); h.model.startBreak(.long)
        XCTAssertEqual(h.model.phase, .rest(.long)); XCTAssertEqual(h.model.remaining(at: h.now), 15 * 60)
        XCTAssertTrue(h.screen.visible)
        h.model.startFocus(); h.model.startBreak(.short)
        XCTAssertEqual(h.model.phase, .rest(.short)); XCTAssertEqual(h.model.remaining(at: h.now), 5 * 60)
    }

    func testPostponeWaitsOneMinuteThenReturnsToTheSameBreakWithoutCountingANewOne() {
        let h = Harness(); h.settings.longBreakEvery = 2
        h.model.startFocus(); h.fireLatest()
        h.model.postpone()
        XCTAssertEqual(h.model.phase, .postponed(.short))
        XCTAssertEqual(h.model.remaining(at: h.now), 60)
        XCTAssertFalse(h.screen.visible)
        h.fireLatest()
        XCTAssertEqual(h.model.phase, .rest(.short))
        XCTAssertTrue(h.screen.visible)
        h.model.postpone(); FocusAction.breakNow.run(h.model)
        XCTAssertEqual(h.model.phase, .rest(.short))
        h.fireLatest()
        // 推迟过的那次休息只算一次：再专注一轮后仍是第二次短休息。
        h.model.startFocus(); h.fireLatest()
        XCTAssertEqual(h.model.phase, .rest(.short))
    }

    func testBreakCanBeStoppedOrEndedIntoANewFocus() {
        let h = Harness()
        h.model.startFocus(); h.fireLatest()
        h.model.stop()
        XCTAssertEqual(h.model.phase, .idle); XCTAssertFalse(h.screen.visible)
        h.model.startFocus(); h.fireLatest()
        h.model.endBreakAndStartFocus()
        XCTAssertEqual(h.model.phase, .focus); XCTAssertFalse(h.screen.visible)
        XCTAssertEqual(h.model.remaining(at: h.now), 25 * 60)
    }

    func testEveryBreakOffersPostponeAndBothUnauthenticatedExits() {
        XCTAssertEqual(FocusAction.available(in: .rest(.short)), [.postpone, .stopBreak, .endBreakAndFocus])
        XCTAssertEqual(FocusAction.available(in: .rest(.long)), [.postpone, .stopBreak, .endBreakAndFocus])
        XCTAssertEqual(FocusAction.available(in: .idle), [.startFocus, .shortBreak, .longBreak])
    }

    func testStaleDeadlineAfterQuickRestartDoesNotAffectTheNewRound() throws {
        let h = Harness()
        h.model.startFocus()
        let stale = try XCTUnwrap(h.callbacks.last).1
        h.model.stop(); h.model.startFocus()
        h.now.addTimeInterval(25 * 60); stale()
        XCTAssertEqual(h.model.phase, .focus)
        h.fireLatest()
        XCTAssertEqual(h.model.phase, .rest(.short))
    }

    func testLaunchStaysIdleByDefaultUnlessTurnedOn() {
        XCTAssertFalse(FocusSettings().startOnLaunch)
        let off = Harness(); off.model.launch()
        XCTAssertEqual(off.model.phase, .idle)
        let on = Harness(); on.settings.startOnLaunch = true; on.model.launch()
        XCTAssertEqual(on.model.phase, .focus)
    }

    func testSavedSettingsSurviveARestartAndOutOfRangeValuesAreClamped() throws {
        let suite = "thermo-focus-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(FocusSettings.read(defaults), FocusSettings())
        // 设置面板经 @AppStorage 按这些键写入。
        let values: [(String, Any)] = [(FocusSettings.focusKey, 50), (FocusSettings.shortBreakKey, 10), (FocusSettings.longBreakKey, 30),
                                       (FocusSettings.longBreakEveryKey, 3), (FocusSettings.progressIconKey, false), (FocusSettings.startOnLaunchKey, true),
                                       (FocusSettings.autoStartFocusKey, true)]
        for (key, value) in values { defaults.set(value, forKey: key) }
        var saved = FocusSettings()
        saved.focusMinutes = 50; saved.shortBreakMinutes = 10; saved.longBreakMinutes = 30
        saved.longBreakEvery = 3; saved.showProgressIcon = false; saved.startOnLaunch = true; saved.autoStartFocus = true
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(FocusSettings.read(reopened), saved)
        reopened.set(0, forKey: FocusSettings.focusKey); reopened.set(99, forKey: FocusSettings.longBreakEveryKey)
        XCTAssertEqual(FocusSettings.read(reopened).focusMinutes, 1)
        XCTAssertEqual(FocusSettings.read(reopened).longBreakEvery, 12)
    }

    func testMenuBarShowsTheActiveCountdownAndOptionalProgressIcon() {
        let h = Harness()
        XCTAssertNil(FocusMenuBarDisplay.make(h.model, now: h.now, showProgressIcon: true))
        h.model.startFocus()
        h.now.addTimeInterval(60.4)
        let shown = FocusMenuBarDisplay.make(h.model, now: h.now, showProgressIcon: true)
        XCTAssertEqual(shown?.text, "24:00")
        XCTAssertEqual(shown?.progress ?? 0, 60.4 / 1500, accuracy: 0.0001)
        XCTAssertNil(FocusMenuBarDisplay.make(h.model, now: h.now, showProgressIcon: false)?.progress)
        XCTAssertEqual(FocusMenuBarDisplay.make(h.model, now: h.now, showProgressIcon: false)?.text, "24:00")
    }

    func testFocusTextIsTranslatedToJapaneseAndChineseAndSystemJapaneseIsRecognised() {
        defer { L10n.override = nil }
        XCTAssertEqual(L10n.parse("ja-JP"), .japanese)
        L10n.override = .japanese
        XCTAssertEqual(tr("Start focus"), "集中を開始")
        XCTAssertEqual(tr("Overview"), "Overview", "untranslated keys keep the English fallback")
        L10n.override = .simplifiedChinese
        XCTAssertEqual(tr("Start focus"), "开始专注")
        L10n.override = .english
        XCTAssertEqual(tr("Start focus"), "Start focus")
    }

    /// 日语表只覆盖专注计时；缺一条就会在日语界面里露出英文。
    func testEveryFocusStringHasAJapaneseTranslation() throws {
        let table = try XCTUnwrap(Language.japanese.table)
        let phases: [FocusPhase] = [.idle, .focus, .postponed(.short), .rest(.short), .rest(.long), .breakFinished]
        L10n.override = .english; defer { L10n.override = nil }
        let shown = phases.map(\.title) + FocusAction.allCases.map(\.title)
        for key in shown { XCTAssertNotNil(table[key], "missing Japanese for: \(key)") }
    }
}
