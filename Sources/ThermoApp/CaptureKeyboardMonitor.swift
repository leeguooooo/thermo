import AppKit
import Carbon
import CoreMedia
import CaptureCore
import Foundation
import ThermoL10n

struct CaptureKeyboardFailure:LocalizedError {
    let message:String
    var errorDescription:String? { tr(message) }
}

@MainActor final class CaptureKeyboardMonitor {
    private var tap:CFMachPort?
    private var source:CFRunLoopSource?
    private let mode:CaptureKeyMode
    private let archive:CaptureFrameArchive
    private let active:()->Bool
    private let failure:(Error)->Void
    init(mode:CaptureKeyMode,archive:CaptureFrameArchive,active:@escaping()->Bool,failure:@escaping(Error)->Void) {
        self.mode=mode;self.archive=archive;self.active=active;self.failure=failure
    }
    static func authorize() throws {
        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else {
            throw CaptureKeyboardFailure(message:"Enable Input Monitoring for Thermo before recording keys.")
        }
    }
    func start() throws {
        guard tap == nil else { return }
        let mask=CGEventMask(1)<<CGEventType.keyDown.rawValue
        guard let tap=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.tailAppendEventTap,options:.listenOnly,eventsOfInterest:mask,callback:{ _,type,event,context in
            if let context {
                MainActor.assumeIsolated { Unmanaged<CaptureKeyboardMonitor>.fromOpaque(context).takeUnretainedValue().receive(type,event) }
            }
            return Unmanaged.passUnretained(event)
        },userInfo:Unmanaged.passUnretained(self).toOpaque()),let source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0) else {
            throw CaptureKeyboardFailure(message:"Keyboard recording could not start. Check Input Monitoring permission.")
        }
        self.tap=tap;self.source=source;CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes);CGEvent.tapEnable(tap:tap,enable:true)
    }
    private func receive(_ type:CGEventType,_ event:CGEvent) {
        if type == .tapDisabledByTimeout { if let tap { CGEvent.tapEnable(tap:tap,enable:true) };return }
        if type == .tapDisabledByUserInput {
            stop();failure(CaptureKeyboardFailure(message:"Keyboard recording was disabled by the system. The recording has stopped."));return
        }
        guard type == .keyDown,active(),!IsSecureEventInputEnabled(),NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let raw=event.getIntegerValueField(.keyboardEventKeycode)
        guard (0...127).contains(raw) else { return }
        let code=UInt16(raw),flags=event.flags
        let named:[UInt16:String]=[36:"↩",48:"⇥",49:"Space",51:"⌫",53:"Esc",76:"⌅",117:"⌦",123:"←",124:"→",125:"↓",126:"↑",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
        let special=named[code],shortcut=flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) || special != nil && code != 49
        guard mode == .all || shortcut else { return }
        let key=special ?? Self.layoutLabel(code)
        guard !key.isEmpty else { return }
        let modifiers=(flags.contains(.maskControl) ? "⌃" : "")+(flags.contains(.maskAlternate) ? "⌥" : "")+(flags.contains(.maskShift) ? "⇧" : "")+(flags.contains(.maskCommand) ? "⌘" : "")
        do { _=try archive.recordKey(label:modifiers+key,shortcut:shortcut,repeated:event.getIntegerValueField(.keyboardEventAutorepeat) != 0,at:CMClockGetTime(CMClockGetHostTimeClock())) }
        catch { stop();failure(error) }
    }
    private static func layoutLabel(_ code:UInt16) -> String {
        guard let source=TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),let pointer=TISGetInputSourceProperty(source,kTISPropertyUnicodeKeyLayoutData) else { return "" }
        let data=Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes=CFDataGetBytePtr(data) else { return "" }
        let layout=UnsafeRawPointer(bytes).assumingMemoryBound(to:UCKeyboardLayout.self)
        var dead:UInt32=0
        var length=0,characters=[UniChar](repeating:0,count:8)
        let status=characters.withUnsafeMutableBufferPointer {
            UCKeyTranslate(layout,code,UInt16(kUCKeyActionDown),0,UInt32(LMGetKbdType()),OptionBits(kUCKeyTranslateNoDeadKeysMask),&dead,8,&length,$0.baseAddress!)
        }
        guard status == noErr else { return "" }
        let text=String(utf16CodeUnits:characters,count:Int(length)).uppercased()
        return text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } ? "" : String(text.prefix(8))
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        tap=nil;source=nil
    }
}
