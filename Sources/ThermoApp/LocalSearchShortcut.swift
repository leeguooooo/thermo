import AgentCore
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
    static let commandSpace = CleanScreenKeyBinding(keyCode: 49, modifiers: UInt32(cmdKey), keyLabel: "Space")
    static let optionSpace = CleanScreenKeyBinding(keyCode: 49, modifiers: UInt32(optionKey), keyLabel: "Space")
    @Published private(set) var binding: CleanScreenKeyBinding?
    @Published private(set) var issue: String?
    @Published var recording = false
    /// Spotlight's ⌘Space has been turned off by Thermo and can be given back.
    @Published private(set) var spotlightReleased = false
    /// Another app already using ⌘Space, shown before the user tries to take it over.
    @Published private(set) var commandSpaceHolder: SpotlightShortcut.Holder?
    @Published private(set) var commandSpaceOfferDismissed = UserDefaults.standard.bool(forKey: offerDismissedKey)
    private static let offerDismissedKey = "dev.thermo.search.commandSpaceOfferDismissed"
    /// The one-time ⌘Space offer at the top of the search panel; settings keep the same choice afterwards.
    var offersCommandSpace: Bool {
        !commandSpaceOfferDismissed && !spotlightReleased && binding?.sameGesture(Self.commandSpace) != true
    }
    func dismissCommandSpaceOffer() {
        commandSpaceOfferDismissed = true; UserDefaults.standard.set(true, forKey: Self.offerDismissedKey)
    }
    private let backend: CleanScreenHotkeyBackend
    private let spotlight: SpotlightShortcut
    private let record: (OperationRecord) -> Void
    private let action: @MainActor () -> Void
    private var lease: CleanScreenHotkeyLease?
    private var retained: [CleanScreenHotkeyLease] = []
    private var held = false, active = false, uncertain = false
    init(backend: CleanScreenHotkeyBackend? = nil, spotlight: SpotlightShortcut? = nil, action: (@MainActor () -> Void)? = nil,
         record: @escaping (OperationRecord) -> Void = { OperationJournal.record($0) }) {
        self.record = record
        self.backend = backend ?? CarbonCleanScreenHotkeys(validate: { $0.validForSearch }, shared: { $0.sameGesture(Self.commandSpace) })
        self.spotlight = spotlight ?? .system
        self.action = action ?? { LocalSearchPanel.shared.toggle() }
    }
    func activate() {
        guard !active else { return }; active = true
        spotlightReleased = spotlight.released()
        defer {
            refreshCommandSpaceHolder()
            if binding?.sameGesture(Self.commandSpace) == true, spotlight.commandSpaceTaken() {
                issue = tr("Spotlight is using ⌘Space again. Let Thermo take it over or record another shortcut.")
            }
        }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.key + ".disabled") { return }
        if let data = defaults.data(forKey: Self.key) {
            guard data.count <= 1024, let saved = try? JSONDecoder().decode(CleanScreenKeyBinding.self, from: data), saved.validForSearch else {
                issue = tr("The saved shortcut is invalid. Record it again."); return
            }
            apply(saved, persist: false)
        } else { apply(Self.optionSpace, persist: false) }
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
        let previous = binding
        lease = next; binding = value; held = false; issue = nil; save(value, persist: persist)
        // Moving off ⌘Space hands it back to Spotlight so it is never left without a shortcut.
        if previous?.sameGesture(Self.commandSpace) == true, value?.sameGesture(Self.commandSpace) != true, spotlight.released() {
            restoreSpotlight()
        }
    }
    /// Turns off Spotlight's ⌘Space and binds search to it; Spotlight is restored if Thermo cannot register it.
    func refreshCommandSpaceHolder() {
        let ours = binding?.sameGesture(Self.commandSpace) == true
        commandSpaceHolder = ours ? nil : spotlight.otherHolder()
    }
    func takeOverSpotlight() {
        guard !uncertain else { return }
        refreshCommandSpaceHolder()
        if let holder = commandSpaceHolder { issue = Self.heldMessage(holder); return }
        do { try spotlight.release() } catch { journal("takeOverSpotlight", error); issue = error.localizedDescription; return }
        spotlightReleased = spotlight.released()
        apply(Self.commandSpace)
        guard binding?.sameGesture(Self.commandSpace) == true else {
            let reason = (issue ?? tr("This shortcut is unavailable. The previous shortcut is kept.")) + " " + tr("Spotlight's shortcut was left on.")
            journal("takeOverSpotlight", SpotlightShortcut.Failure(message: reason))
            restoreSpotlight(); issue = reason; return
        }
        journal("takeOverSpotlight", nil)
    }
    /// Gives ⌘Space back to Spotlight; search falls back to ⌥Space when it was using ⌘Space.
    func giveBackToSpotlight() {
        guard restoreSpotlight() else { return }
        if binding?.sameGesture(Self.commandSpace) == true { apply(Self.optionSpace) }
        refreshCommandSpaceHolder()
    }
    static func heldMessage(_ holder: SpotlightShortcut.Holder) -> String {
        tr("%1$@ is using ⌘Space. Change its shortcut in %1$@, then try again.", holder.name)
    }
    @discardableResult private func restoreSpotlight() -> Bool {
        do { try spotlight.restore() } catch { journal("restoreSpotlight", error); issue = error.localizedDescription; return false }
        spotlightReleased = spotlight.released(); journal("restoreSpotlight", nil); return true
    }
    private func journal(_ action: String, _ error: Error?) {
        record(OperationRecord(feature: "search", action: action, subject: "⌘Space",
            items: [.init(target: "⌘Space", status: error == nil ? "done" : "failed", detail: error?.localizedDescription)],
            undo: action == "takeOverSpotlight" && error == nil ? .init(kind: "spotlightShortcut", ref: "64") : nil))
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
