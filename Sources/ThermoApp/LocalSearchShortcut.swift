import AppKit
import Carbon
import SwiftUI
import ThermoL10n

extension CleanScreenKeyBinding {
    var validForSearch: Bool {
        keyCode < 128 && keyCode != 53 && !(54...63).contains(keyCode) && modifiers & ~Self.allowed == 0 &&
        modifiers & (UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)) != 0 &&
        !keyLabel.isEmpty && keyLabel.count <= 24 && !keyLabel.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

@MainActor final class LocalSearchShortcut: ObservableObject {
    static let shared = LocalSearchShortcut()
    static let key = "dev.thermo.search.shortcut"
    @Published private(set) var binding: CleanScreenKeyBinding?
    @Published private(set) var issue: String?
    @Published var recording = false
    private let backend: CleanScreenHotkeyBackend
    private let action: @MainActor () -> Void
    private var lease: CleanScreenHotkeyLease?
    private var retained: [CleanScreenHotkeyLease] = []
    private var held = false, active = false, uncertain = false
    init(backend: CleanScreenHotkeyBackend? = nil, action: (@MainActor () -> Void)? = nil) {
        self.backend = backend ?? CarbonCleanScreenHotkeys(validate: { $0.validForSearch })
        self.action = action ?? { LocalSearchPanel.shared.toggle() }
    }
    func activate() {
        guard !active else { return }; active = true
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.key + ".disabled") { return }
        if let data = defaults.data(forKey: Self.key) {
            guard data.count <= 1024, let saved = try? JSONDecoder().decode(CleanScreenKeyBinding.self, from: data), saved.validForSearch else {
                issue = tr("The saved shortcut is invalid. Record it again."); return
            }
            apply(saved, persist: false)
        } else { apply(.init(keyCode: 49, modifiers: UInt32(optionKey), keyLabel: "Space"), persist: false) }
    }
    func apply(_ value: CleanScreenKeyBinding?, persist: Bool = true) {
        guard !uncertain else { return }
        guard value?.validForSearch ?? true else { issue = tr("Include Command, Control or Option in the shortcut."); return }
        recording = false
        if binding == value { return }
        if let value, binding?.sameGesture(value) == true { binding = value; save(value, persist: persist); return }
        let next: CleanScreenHotkeyLease?
        do {
            next = try value.map { candidate in
                try backend.register(candidate) { [weak self] down in
                    guard let self else { return }
                    if !down { self.held = false }
                    else if !self.held, !self.recording, !self.uncertain { self.held = true; self.action() }
                }
            }
        } catch { issue = tr("This shortcut is unavailable. The previous shortcut is kept."); return }
        do { try lease?.release() }
        catch {
            if let lease { retained.append(lease) }
            if let next { do { try next.release() } catch { retained.append(next) } }
            lease = nil; binding = nil; uncertain = true
            issue = tr("Shortcut release could not be confirmed. Restart Thermo before recording another shortcut.")
            return
        }
        lease = next; binding = value; held = false; issue = nil; save(value, persist: persist)
    }
    private func save(_ value: CleanScreenKeyBinding?, persist: Bool) {
        guard persist else { return }
        UserDefaults.standard.set(value == nil, forKey: Self.key + ".disabled")
        if let value { UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: Self.key) }
        else { UserDefaults.standard.removeObject(forKey: Self.key) }
    }
    func shutdown() {
        do { try lease?.release(); lease = nil } catch { issue = tr("Shortcut release could not be confirmed.") }
        for item in retained { try? item.release() }; retained.removeAll()
    }
}

struct SearchShortcutRecorder: NSViewRepresentable {
    @ObservedObject var model: LocalSearchShortcut
    func makeNSView(context: Context) -> Recorder { let view = Recorder(); view.model = model; return view }
    func updateNSView(_ view: Recorder, context: Context) {
        view.title = model.recording ? tr("Press a shortcut; Esc cancels") : model.binding?.label ?? tr("Record shortcut…")
        view.setAccessibilityLabel(tr("Record global search shortcut"))
    }
    final class Recorder: NSButton {
        weak var model: LocalSearchShortcut?
        override var acceptsFirstResponder: Bool { true }
        init() { super.init(frame: .zero); bezelStyle = .rounded; target = self; action = #selector(record) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        @objc func record() { model?.recording = true; window?.makeFirstResponder(self) }
        override func resignFirstResponder() -> Bool { model?.recording = false; return super.resignFirstResponder() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if model?.recording == true, event.type == .keyDown { keyDown(with: event); return true }
            return super.performKeyEquivalent(with: event)
        }
        override func keyDown(with event: NSEvent) {
            guard model?.recording == true else { super.keyDown(with: event); return }
            if event.keyCode == 53 { model?.recording = false }
            else { model?.apply(.captured(event)) }
        }
    }
}
