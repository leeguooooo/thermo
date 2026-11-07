import SwiftUI
import ThermoL10n

struct FocusButton: View {
    @ObservedObject private var model = FocusTimerModel.shared
    var body: some View {
        Button { MainWindow.show(tool: .focus) } label: {
            FeatureRow(title: tr("Focus timer"), symbol: "timer", active: model.phase.isActive)
        }
        .buttonStyle(.plain)
    }
}

struct FocusPanel: View {
    @ObservedObject var model: FocusTimerModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FocusSettings.focusKey) private var focus = FocusSettings().focusMinutes
    @AppStorage(FocusSettings.shortBreakKey) private var shortBreak = FocusSettings().shortBreakMinutes
    @AppStorage(FocusSettings.longBreakKey) private var longBreak = FocusSettings().longBreakMinutes
    @AppStorage(FocusSettings.longBreakEveryKey) private var every = FocusSettings().longBreakEvery
    @AppStorage(FocusSettings.progressIconKey) private var progressIcon = FocusSettings().showProgressIcon
    @AppStorage(FocusSettings.startOnLaunchKey) private var startOnLaunch = FocusSettings().startOnLaunch

    private func minutes(_ label: String, _ value: Binding<Int>) -> some View {
        Stepper(value: value, in: FocusSettings.minuteRange) {
            Text(tr("%1$@: %2$@", label, tr("%1$@ min", String(value.wrappedValue)))).monospacedDigit()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(tr("Focus timer"), systemImage: "timer").font(Theme.heading)
            Text(tr("Breaks cover every display with its desktop picture. You can end a break at any time; this does not lock your Mac."))
                .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = model.remaining(at: context.date).map { " · " + FocusTimerModel.countdownText($0) } ?? ""
                Text(model.phase.title + remaining).font(Theme.rowTitle.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(model.phase.isActive ? Theme.good : Theme.textSecondary)
            }
            minutes(tr("Focus length"), $focus)
            minutes(tr("Short break length"), $shortBreak)
            minutes(tr("Long break length"), $longBreak)
            Stepper(value: $every, in: FocusSettings.longBreakEveryRange) {
                Text(tr("%1$@: %2$@", tr("Long break after"), tr("%1$@ short breaks", String(every)))).monospacedDigit()
            }
            Toggle(tr("Show progress icon in the menu bar"), isOn: $progressIcon)
            Toggle(tr("Start focus when Thermo opens"), isOn: $startOnLaunch)
            Text(tr("New lengths apply from the next focus or break."))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            HStack {
                ForEach(FocusAction.available(in: model.phase), id: \.self) { action in
                    Button(action.title) { action.run(model) }
                }
                Spacer()
                Button(tr("Close")) { dismiss() }
            }
        }.padding(24).frame(width: 550)
    }
}
