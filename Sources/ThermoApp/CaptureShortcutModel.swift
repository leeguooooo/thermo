import AppKit
import CaptureCore
import Combine
import ThermoL10n

@MainActor final class CaptureShortcutModel:ObservableObject {
    static let preferenceKey="dev.thermo.capture.actions.v1"
    @Published private(set) var settings=CaptureActionSettings.defaults
    @Published private(set) var issue:String?
    @Published private(set) var uncertain=false
    @Published private(set) var registrationIssues:[String:String]=[:]
    @Published private(set) var recordingOwner:UUID?
    private let backend:CleanScreenHotkeyBackend
    private let read:()->Data?
    private let write:(Data)throws->Void
    private let execute:(CaptureAction)throws->Void
    private let pinFocused:()->Bool
    private var leases:[String:CleanScreenHotkeyLease]=[:]
    private var retained:[CleanScreenHotkeyLease]=[]
    private var held:Set<String>=[]
    private var recordingReceiver:((CaptureShortcut)->Void)?
    private var activated=false
    private var dispatching=false
    private var localMonitor:Any?
    init(backend:CleanScreenHotkeyBackend,read:@escaping()->Data?,write:@escaping(Data)throws->Void,pinFocused:@escaping()->Bool,execute:@escaping(CaptureAction)throws->Void) {
        self.backend=backend;self.read=read;self.write=write;self.pinFocused=pinFocused;self.execute=execute
    }
    static func backend() -> CarbonCleanScreenHotkeys { CarbonCleanScreenHotkeys(validate:{ CaptureShortcut(keyCode:$0.keyCode,modifiers:$0.modifiers,keyLabel:$0.keyLabel).validGlobal }) }
    func activate() {
        guard !activated else { return };activated=true
        if let data=read() {
            do { settings=try CaptureActionSettings.decode(data) }
            catch { settings = .init();settings.shortcutsEnabled=false;issue=tr(CaptureActionFailure.invalidSettings.localizedDescription);return }
        }
        installMonitor()
        for (gesture,key) in globals(settings) {
            do { leases[gesture]=try register(key) }
            catch { registrationIssues[gesture]=tr("Shortcut is unavailable in this session.") }
        }
    }
    private func globals(_ value:CaptureActionSettings) -> [String:CaptureShortcut] {
        guard value.shortcutsEnabled else { return [:] }
        return Dictionary(uniqueKeysWithValues:value.entries.filter { $0.enabled && $0.scope == .global && $0.shortcut != nil }.map { ($0.shortcut!.gesture,$0.shortcut!) })
    }
    private func register(_ key:CaptureShortcut) throws -> CleanScreenHotkeyLease {
        try backend.register(.init(keyCode:key.keyCode,modifiers:key.modifiers,keyLabel:key.keyLabel)) { [weak self] down in self?.receive(key,down:down) }
    }
    @discardableResult func apply(_ next:CaptureActionSettings) -> Bool {
        if !activated { activate() }
        guard !uncertain else { return false }
        do { _=try next.data() } catch { issue=tr(CaptureActionFailure.invalidSettings.localizedDescription);return false }
        let desired=globals(next);var added:[String:CleanScreenHotkeyLease]=[:]
        do { for (gesture,key) in desired where leases[gesture] == nil { added[gesture]=try register(key) } }
        catch { rollback(added);issue=tr(uncertain ? "Shortcut release was not confirmed. Restart Thermo before changing shortcuts." : "Shortcut registration failed. Previous settings are kept.");return false }
        do { try write(next.data()) }
        catch { rollback(added);issue=tr(uncertain ? "Shortcut release was not confirmed. Restart Thermo before changing shortcuts." : "Capture settings could not be saved. Previous settings are kept.");return false }
        // Callbacks route through the current settings, so reused gestures can change actions atomically.
        let previous=settings;settings=next
        do {
            for (gesture,lease) in leases where desired[gesture] == nil { try lease.release() }
        } catch {
            settings=previous;try? write(previous.data());freeze(added)
            issue=tr("Shortcut release was not confirmed. Restart Thermo before changing shortcuts.");return false
        }
        leases=leases.filter { desired[$0.key] != nil }.merging(added) { _,new in new };let active=Set(next.entries.filter { $0.enabled }.compactMap { $0.shortcut?.gesture });held.formIntersection(active);registrationIssues=[:];issue=nil;installMonitor();return true
    }
    private func rollback(_ added:[String:CleanScreenHotkeyLease]) {
        for lease in added.values { do { try lease.release() } catch { retained.append(lease);uncertain=true } }
        if uncertain { held.removeAll();recordingOwner=nil;recordingReceiver=nil }
    }
    private func freeze(_ added:[String:CleanScreenHotkeyLease]) {
        uncertain=true;held.removeAll();recordingOwner=nil;recordingReceiver=nil
        retained += Array(leases.values)+Array(added.values);leases=[:]
        for lease in retained { try? lease.release() }
    }
    private func installMonitor() {
        guard localMonitor == nil else { return }
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                let key=CaptureShortcut(keyCode:UInt32(event.keyCode),modifiers:CleanScreenKeyBinding.flags(event.modifierFlags),keyLabel:CleanScreenKeyBinding.captured(event).keyLabel)
                if event.type == .keyUp { self.held=self.held.filter { !$0.hasSuffix(":"+String(event.keyCode)) };return event }
                guard !event.isARepeat,self.settings.shortcutsEnabled,!self.uncertain,self.recordingOwner == nil,self.pinFocused() else { return event }
                if let text=NSApp.keyWindow?.firstResponder as? NSTextView,text.isEditable,key.modifiers & (CaptureShortcut.command|CaptureShortcut.control|CaptureShortcut.option) == 0 { return event }
                guard self.settings.entries.contains(where:{ $0.enabled && $0.scope == .pin && $0.shortcut?.gesture == key.gesture }) else { return event }
                self.receive(key,down:true);return nil
            }
        }
    }
    func receive(_ key:CaptureShortcut,down:Bool) {
        if !down { held.remove(key.gesture);return }
        guard !uncertain,settings.shortcutsEnabled,!held.contains(key.gesture) else { return };held.insert(key.gesture)
        if let owner=recordingOwner { record(key,owner:owner);return }
        let matching=settings.entries.filter { $0.enabled && $0.shortcut?.gesture == key.gesture }
        let entry=pinFocused() ? matching.first(where:{ $0.scope == .pin }) ?? matching.first(where:{ $0.scope == .global }) : matching.first(where:{ $0.scope == .global })
        guard let entry else { return };run(entry.action)
    }
    func run(_ action:CaptureAction) {
        guard !dispatching else { issue=tr("Another capture action is in progress.");return }
        dispatching=true;defer { dispatching=false }
        do { try execute(action);issue=nil } catch { issue=captureFailureMessage(error) }
    }
    func beginRecording(_ owner:UUID,receive:@escaping(CaptureShortcut)->Void) { guard !uncertain else { return };recordingOwner=owner;recordingReceiver=receive;issue=nil }
    func cancelRecording(_ owner:UUID) { if recordingOwner == owner { recordingOwner=nil;recordingReceiver=nil } }
    func record(_ key:CaptureShortcut,owner:UUID) {
        guard recordingOwner == owner else { return }
        guard key.valid else { issue=tr("Use a supported key combination.");return }
        let receive=recordingReceiver;recordingOwner=nil;recordingReceiver=nil;held.insert(key.gesture);receive?(key)
    }
    func label(for action:CaptureAction) -> String {
        settings.entries.filter { $0.action == action && $0.scope == .global }.compactMap { entry in let value=label(for:entry);return value.isEmpty ? nil : value }.first ?? ""
    }
    func label(for entry:CaptureShortcutEntry) -> String {
        guard settings.shortcutsEnabled,!uncertain,entry.enabled,let key=entry.shortcut else { return "" }
        if entry.scope == .pin { return key.label }
        return leases[key.gesture] != nil ? key.label : ""
    }
    func state(for entry:CaptureShortcutEntry) -> String {
        if uncertain { return tr("Restart required") }
        guard entry.enabled else { return tr("Disabled") }
        guard let key=entry.shortcut else { return tr("Action menu only") }
        guard settings.shortcutsEnabled else { return tr("Disabled") }
        if entry.scope == .pin { return tr("Local binding enabled") }
        return leases[key.gesture] != nil ? tr("Registered") : registrationIssues[key.gesture] ?? tr("Not registered")
    }
    func shutdown() {
        recordingOwner=nil;recordingReceiver=nil;held.removeAll()
        for lease in Array(leases.values)+retained { try? lease.release() };leases=[:];retained=[]
        if let localMonitor { NSEvent.removeMonitor(localMonitor) };localMonitor=nil;activated=false
    }
}
