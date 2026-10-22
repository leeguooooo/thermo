import AppKit
import Carbon
import Combine
import ThermoL10n

struct CleanScreenKeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String
    static let allowed = UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey) | UInt32(shiftKey)
    var valid: Bool {
        keyCode < 128 && keyCode != 53 && !(54...63).contains(keyCode) && modifiers & ~Self.allowed == 0 &&
        modifiers.nonzeroBitCount >= 2 && modifiers & (UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)) != 0 &&
        !keyLabel.isEmpty && keyLabel.count <= 24 && !keyLabel.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    func sameGesture(_ other: Self) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
    var label: String {
        [(UInt32(controlKey),"⌃"),(UInt32(optionKey),"⌥"),(UInt32(shiftKey),"⇧"),(UInt32(cmdKey),"⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined() + keyLabel
    }
    static func flags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }; if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }; if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
    static func flags(_ flags: CGEventFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.maskCommand) { value |= UInt32(cmdKey) }; if flags.contains(.maskControl) { value |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { value |= UInt32(optionKey) }; if flags.contains(.maskShift) { value |= UInt32(shiftKey) }
        return value
    }
    static func captured(_ event: NSEvent) -> CleanScreenKeyBinding {
        let special: [UInt16:String] = [36:"↩",48:"⇥",49:"Space",51:"⌫",76:"⌅",117:"⌦",123:"←",124:"→",125:"↓",126:"↑",
            122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",
            105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
        return .init(keyCode:UInt32(event.keyCode),modifiers:flags(event.modifierFlags),
                     keyLabel:special[event.keyCode] ?? String((event.charactersIgnoringModifiers ?? "").uppercased().prefix(24)))
    }
}

@MainActor protocol CleanScreenHotkeyLease: AnyObject { func release() throws }
@MainActor protocol CleanScreenHotkeyBackend {
    func register(_ binding: CleanScreenKeyBinding, event: @escaping (Bool) -> Void) throws -> CleanScreenHotkeyLease
}

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

@MainActor final class CarbonCleanScreenHotkeys: CleanScreenHotkeyBackend {
    private let validate: (CleanScreenKeyBinding) -> Bool
    init(validate: @escaping (CleanScreenKeyBinding) -> Bool = { $0.valid }) { self.validate = validate }
    private struct Entry { var binding: CleanScreenKeyBinding; var ref: EventHotKeyRef; var event: (Bool)->Void }
    private var entries: [UInt32:Entry] = [:]
    private static var nextID: UInt32 = 0
    private var handler: EventHandlerRef?
    private var monitor: Any?
    private static let signature: OSType = 0x54484353
    struct Failure: Error { let status: OSStatus }
    private final class Lease: CleanScreenHotkeyLease {
        var owner: CarbonCleanScreenHotkeys?
        let id: UInt32
        init(_ owner: CarbonCleanScreenHotkeys, _ id: UInt32) { self.owner=owner;self.id=id }
        func release() throws { try owner?.remove(id);owner=nil }
        deinit {
            let owner=owner,id=id
            Task { @MainActor in try? owner?.remove(id) }
        }
    }
    func register(_ binding: CleanScreenKeyBinding, event: @escaping (Bool) -> Void) throws -> CleanScreenHotkeyLease {
        guard validate(binding), Self.nextID < UInt32.max else { throw Failure(status:OSStatus(paramErr)) }
        try prepare()
        Self.nextID += 1
        let id=Self.nextID
        var ref: EventHotKeyRef?
        let status=RegisterEventHotKey(binding.keyCode,binding.modifiers,.init(signature:Self.signature,id:id),GetApplicationEventTarget(),UInt32(kEventHotKeyExclusive),&ref)
        guard status == noErr, let ref else { clearIfEmpty();throw Failure(status:status) }
        entries[id] = .init(binding:binding,ref:ref,event:event)
        return Lease(self,id)
    }
    private func prepare() throws {
        if handler == nil {
            let types=[EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed)),
                       EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyReleased))]
            var ref: EventHandlerRef?
            let status=types.withUnsafeBufferPointer { types in
                InstallEventHandler(GetApplicationEventTarget(),{ _, event, context in
                    guard let event,let context else { return OSStatus(eventNotHandledErr) }
                    return MainActor.assumeIsolated {
                        let owner=Unmanaged<CarbonCleanScreenHotkeys>.fromOpaque(context).takeUnretainedValue()
                        var id=EventHotKeyID()
                        guard GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id) == noErr,
                              id.signature == CarbonCleanScreenHotkeys.signature,let entry=owner.entries[id.id] else { return OSStatus(eventNotHandledErr) }
                        entry.event(GetEventKind(event) == UInt32(kEventHotKeyPressed));return noErr
                    }
                },types.count,types.baseAddress,Unmanaged.passUnretained(self).toOpaque(),&ref)
            }
            guard status == noErr,let ref else { throw Failure(status:status) };handler=ref
        }
        if monitor == nil {
            monitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return event }
                    for entry in self.entries.values where entry.binding.keyCode == UInt32(event.keyCode) {
                        if event.type == .keyUp { entry.event(false) }
                        else if entry.binding.modifiers == CleanScreenKeyBinding.flags(event.modifierFlags) {
                            if !event.isARepeat { entry.event(true) };return nil
                        }
                    }
                    return event
                }
            }
            guard monitor != nil else { clearIfEmpty();throw Failure(status:OSStatus(memFullErr)) }
        }
    }
    private func remove(_ id: UInt32) throws {
        guard let entry=entries[id] else { return }
        let status=UnregisterEventHotKey(entry.ref)
        guard status == noErr else { throw Failure(status:status) }
        entries[id]=nil;clearIfEmpty()
    }
    private func clearIfEmpty() {
        guard entries.isEmpty else { return }
        if let handler { RemoveEventHandler(handler) };handler=nil
        if let monitor { NSEvent.removeMonitor(monitor) };monitor=nil
    }
}
