import AppKit
import Carbon

// Shared key bindings and Carbon leases; existing type names are retained for callers.
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

@MainActor final class CarbonCleanScreenHotkeys: CleanScreenHotkeyBackend {
    private let validate: (CleanScreenKeyBinding) -> Bool
    private let shared: (CleanScreenKeyBinding) -> Bool
    /// `shared` gestures register without the exclusive flag: macOS refuses an exclusive claim on any combo in the
    /// system shortcut table, even after that system shortcut is turned off.
    init(validate: @escaping (CleanScreenKeyBinding) -> Bool = { $0.valid }, shared: @escaping (CleanScreenKeyBinding) -> Bool = { _ in false }) {
        self.validate = validate; self.shared = shared
    }
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
        let status=RegisterEventHotKey(binding.keyCode,binding.modifiers,.init(signature:Self.signature,id:id),GetApplicationEventTarget(),shared(binding) ? 0 : UInt32(kEventHotKeyExclusive),&ref)
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
