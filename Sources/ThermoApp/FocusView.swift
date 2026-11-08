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

private struct FocusIntegerRow: View {
    let label: String
    /// 日文的数字夹在单位中间（短い休憩 4 回），所以按占位符拆开把输入框放进去，不用另拆翻译键。
    let unit: (String) -> String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var draft = ""
    @FocusState private var focused: Bool

    private func commit() {
        if let parsed = FocusSettings.integer(from: draft, in: range) { value = parsed }
        draft = String(value)
    }

    /// 先落下正在输入的数字，否则点箭头会从输入前的旧值算起。
    private func step(_ delta: Int) {
        commit()
        value = FocusSettings.clamped(value + delta, to: range)
    }

    @ViewBuilder private func unitText(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { Text(trimmed) }
    }

    var body: some View {
        let mark = "\u{1}"
        let parts = unit(mark).components(separatedBy: mark)
        HStack(spacing: 6) {
            Text(tr("%1$@: %2$@", label, ""))
            unitText(parts.first ?? "")
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.center).monospacedDigit()
                .frame(width: 52).focused($focused).accessibilityLabel(label)
                .onSubmit(commit)
            unitText(parts.last ?? "")
            Stepper(label, onIncrement: { step(1) }, onDecrement: { step(-1) }).labelsHidden()
        }
        .onAppear { draft = String(value) }
        .onDisappear(perform: commit)
        // macOS 点按钮不会让输入框失焦，只靠失焦提交的话，输入后直接点「开始专注」用的还是旧值；所以范围内的数字边输边存。
        .onChange(of: draft) { text in
            if let number = FocusSettings.parsedInteger(text), range.contains(number) { value = number }
        }
        .onChange(of: value) { if FocusSettings.parsedInteger(draft) != $0 { draft = String($0) } }
        .onChange(of: focused) { if !$0 { commit() } }
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
    @AppStorage(FocusSettings.autoStartFocusKey) private var autoStartFocus = FocusSettings().autoStartFocus

    private func minutes(_ label: String, _ value: Binding<Int>) -> some View {
        FocusIntegerRow(label: label, unit: { tr("%1$@ min", $0) }, value: value, range: FocusSettings.minuteRange)
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
            FocusIntegerRow(label: tr("Long break after"), unit: { tr("%1$@ short breaks", $0) }, value: $every, range: FocusSettings.longBreakEveryRange)
            Toggle(tr("Show progress icon in the menu bar"), isOn: $progressIcon)
            Toggle(tr("Start focus when Thermo opens"), isOn: $startOnLaunch)
            Toggle(tr("Start focus automatically when a break ends"), isOn: $autoStartFocus)
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
