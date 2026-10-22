import AppKit
import Carbon
import Combine
import ThermoL10n

@MainActor final class CleanScreenShortcutModel: ObservableObject {
    static let preferenceKey = "dev.thermo.cleanScreen.shortcut"
    static let shared = CleanScreenShortcutModel(backend:CarbonCleanScreenHotkeys(),read:{ UserDefaults.standard.data(forKey:preferenceKey) },write:{ data in
        if let data { UserDefaults.standard.set(data,forKey:preferenceKey) } else { UserDefaults.standard.removeObject(forKey:preferenceKey) }
    },action:{
        let model = CleanScreenModel.shared
        if model.active { model.stop(); return }
        model.refreshPermission()
        if model.hasAccessibility {
            let duration = UserDefaults.standard.string(forKey:CleanScreenDuration.preferenceKey).flatMap(CleanScreenDuration.init(rawValue:)) ?? .twoMinutes
            model.start(duration)
        } else { CleanScreenSetupWindow.show() }
    })
    @Published private(set) var binding: CleanScreenKeyBinding?
    @Published private(set) var issue: String?
    @Published private(set) var uncertain = false
    @Published private(set) var recordingOwner: UUID?
    private let backend: CleanScreenHotkeyBackend
    private let read: () -> Data?
    private let write: (Data?) -> Void
    private let action: () -> Void
    private var lease: CleanScreenHotkeyLease?
    private var unreleased: [CleanScreenHotkeyLease] = []
    private var activated = false, held = false
    private var termination: NSObjectProtocol?
    init(backend: CleanScreenHotkeyBackend, read: @escaping () -> Data?, write: @escaping (Data?) -> Void, action: @escaping () -> Void) {
        self.backend=backend;self.read=read;self.write=write;self.action=action
    }
    static func enableLive() {
        let shortcut = shared
        CleanScreenModel.shared.shortcutInput = { [weak shortcut] code, flags, down, repeated in
            shortcut?.input(code:code,flags:flags,down:down,repeated:repeated)
        }
        shortcut.activate()
    }
    func activate() {
        guard !activated else { return };activated=true
        termination = NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        guard let data=read() else { return }
        guard data.count <= 1024,let saved=try? JSONDecoder().decode(CleanScreenKeyBinding.self,from:data),saved.valid else {
            issue=tr("The saved shortcut is invalid. Record it again.");return
        }
        apply(saved,persist:false)
    }
    func beginRecording(_ owner: UUID) { guard !uncertain else { return };recordingOwner=owner;issue=nil }
    func cancelRecording(_ owner: UUID) { if recordingOwner == owner { recordingOwner=nil } }
    func record(_ value: CleanScreenKeyBinding, owner: UUID) {
        guard recordingOwner == owner else { return }
        guard value.valid else { issue=tr("Use at least two modifiers, including Command, Control or Option.");return }
        recordingOwner=nil;apply(value)
        if binding?.sameGesture(value) == true { held=true }
    }
    func apply(_ value: CleanScreenKeyBinding?, persist: Bool = true) {
        guard !uncertain else { return }
        guard value?.valid ?? true else { issue=tr("Use at least two modifiers, including Command, Control or Option.");return }
        guard binding != value else { issue=nil;recordingOwner=nil;if value == nil,persist { write(nil) };return }
        if let current=binding,let value,current.sameGesture(value) {
            binding=value;issue=nil;recordingOwner=nil
            if persist { write(try? JSONEncoder().encode(value)) };return
        }
        let next: CleanScreenHotkeyLease?
        do {
            next = try value.map { candidate in try backend.register(candidate,event:{ [weak self] down in self?.receive(candidate,down:down) }) }
        } catch {
            issue=tr(binding == nil ? "This shortcut is unavailable. Record another combination." : "This shortcut could not be registered. The previous shortcut is kept.");return
        }
        do { try lease?.release() }
        catch {
            if let lease { unreleased.append(lease) }
            if let next { do { try next.release() } catch { unreleased.append(next) } }
            lease=nil;binding=nil;held=false;uncertain=true;recordingOwner=nil
            write(nil)
            issue=tr("Shortcut registration could not be released reliably. Restart Thermo before recording another shortcut.")
            return
        }
        lease=next;binding=value;held=false;issue=nil;recordingOwner=nil
        if persist { write(value.flatMap { try? JSONEncoder().encode($0) }) }
    }
    private func receive(_ candidate: CleanScreenKeyBinding, down: Bool) {
        guard binding?.sameGesture(candidate) == true, !uncertain else { return }
        if !down { held=false;return }
        guard !held else { return };held=true
        if recordingOwner != nil { recordingOwner=nil;issue=nil;return }
        action()
    }
    func input(code: Int64, flags: UInt32, down: Bool, repeated: Bool) {
        guard let binding, code == Int64(binding.keyCode) else { return }
        if !down { receive(binding,down:false) }
        else if !repeated, flags == binding.modifiers { receive(binding,down:true) }
    }
    func shutdown() {
        binding=nil;held=false;recordingOwner=nil
        if let lease { try? lease.release() };lease=nil
        for item in unreleased { try? item.release() };unreleased=[]
        if let termination { NotificationCenter.default.removeObserver(termination) };termination=nil
    }
}
