import Foundation

public enum CaptureAction:String,Codable,CaseIterable,Sendable,Identifiable {
    case screenshot, pinClipboard, pinText, pinLaTeX, openImage, scrolling, recording, recordingDrafts
    case pinGroups, shortcutSettings, nextGroup, previousGroup, restorePin, showPins, hidePins, togglePins, closePins
    case showPin, closePin, copyImage, copyContent, saveImage, recognize, toggleTop, toggleLock, resetZoom, rotate, flip, undo, redo
    public var id:String { rawValue }
    public var title:String {
        switch self {
        case .screenshot:return "Capture screen…";case .pinClipboard:return "Pin clipboard";case .pinText:return "Pin clipboard as text";case .pinLaTeX:return "Pin clipboard as LaTeX"
        case .openImage:return "Open image…";case .scrolling:return "Scrolling capture…";case .recording:return "Record screen…";case .recordingDrafts:return "Recording drafts…"
        case .pinGroups:return "Pin groups and history";case .shortcutSettings:return "Capture shortcuts and actions";case .nextGroup:return "Next pin group";case .previousGroup:return "Previous pin group"
        case .restorePin:return "Restore last closed pin";case .showPins:return "Show all pins";case .hidePins:return "Hide all pins";case .togglePins:return "Toggle all pins";case .closePins:return "Close all pins"
        case .showPin:return "Show current pin";case .closePin:return "Close current pin";case .copyImage:return "Copy current pin image";case .copyContent:return "Copy current pin content"
        case .saveImage:return "Save current pin image…";case .recognize:return "Recognize current image";case .toggleTop:return "Toggle current pin topmost";case .toggleLock:return "Toggle current pin lock"
        case .resetZoom:return "Reset current pin view";case .rotate:return "Rotate current image";case .flip:return "Flip current image";case .undo:return "Undo image annotation";case .redo:return "Redo image annotation"
        }
    }
    public var needsPin:Bool { [.showPin,.closePin,.copyImage,.copyContent,.saveImage,.recognize,.toggleTop,.toggleLock,.resetZoom,.rotate,.flip,.undo,.redo].contains(self) }
    public var imageOnly:Bool { [.copyImage,.saveImage,.recognize,.rotate,.flip,.undo,.redo].contains(self) }
}
public struct CaptureShortcut:Codable,Sendable,Equatable,Hashable {
    public var keyCode:UInt32
    public var modifiers:UInt32
    public var keyLabel:String
    public static let command:UInt32=256,shift:UInt32=512,option:UInt32=2048,control:UInt32=4096
    public static let allowed=command|shift|option|control
    public init(keyCode:UInt32,modifiers:UInt32,keyLabel:String) { self.keyCode=keyCode;self.modifiers=modifiers;self.keyLabel=keyLabel }
    public var valid:Bool { keyCode < 128 && !(54...63).contains(keyCode) && modifiers & ~Self.allowed == 0 && !keyLabel.isEmpty && keyLabel.count <= 24 && !keyLabel.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    public var validGlobal:Bool {
        let functionKeys:Set<UInt32>=[122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        return valid && keyCode != 53 && (modifiers & (Self.command|Self.control|Self.option) != 0 || functionKeys.contains(keyCode))
    }
    public var gesture:String { "\(modifiers):\(keyCode)" }
    public var label:String { [(Self.control,"⌃"),(Self.option,"⌥"),(Self.shift,"⇧"),(Self.command,"⌘")].filter { modifiers & $0.0 != 0 }.map(\.1).joined()+keyLabel }
}
public struct CaptureShortcutEntry:Codable,Sendable,Equatable,Identifiable {
    public enum Scope:String,Codable,Sendable,CaseIterable { case global,pin }
    public var id:UUID
    public var title:String
    public var action:CaptureAction
    public var scope:Scope
    public var shortcut:CaptureShortcut?
    public var enabled:Bool
    public var showInMenu:Bool?
    public var appearsInMenu:Bool { enabled && (showInMenu ?? true) }
    public init(id:UUID=UUID(),title:String="",action:CaptureAction,scope:Scope = .global,shortcut:CaptureShortcut? = nil,enabled:Bool=true,showInMenu:Bool=true) { self.showInMenu=showInMenu;self.id=id;self.title=title;self.action=action;self.scope=scope;self.shortcut=shortcut;self.enabled=enabled }
    public var valid:Bool { title.count <= 100 && (shortcut.map { scope == .global ? $0.validGlobal : $0.valid } ?? true) }
}
public struct CaptureActionSettings:Codable,Sendable,Equatable {
    public var version=1
    public var shortcutsEnabled=true
    public var entries:[CaptureShortcutEntry]
    public init(entries:[CaptureShortcutEntry]=[]) { self.entries=entries }
    public static var defaults:Self { .init(entries:[
        .init(id:UUID(uuidString:"71A7E028-CE31-42E5-A450-5A2552930003")!,action:.screenshot,shortcut:.init(keyCode:20,modifiers:CaptureShortcut.command|CaptureShortcut.option,keyLabel:"3"),showInMenu:false),
        .init(id:UUID(uuidString:"71A7E028-CE31-42E5-A450-5A2552930004")!,action:.pinClipboard,shortcut:.init(keyCode:21,modifiers:CaptureShortcut.command|CaptureShortcut.option,keyLabel:"4"),showInMenu:false)]) }
    public var valid:Bool {
        guard version == 1,entries.count <= 128,Set(entries.map(\.id)).count == entries.count,entries.allSatisfy(\.valid) else { return false }
        var gestures:Set<String>=[]
        for entry in entries where entry.enabled {
            if let shortcut=entry.shortcut,!gestures.insert(entry.scope.rawValue+":"+shortcut.gesture).inserted { return false }
        };return true
    }
    public func data() throws -> Data { guard valid else { throw CaptureActionFailure.invalidSettings };let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];let data=try encoder.encode(self);guard data.count <= 65536 else { throw CaptureActionFailure.invalidSettings };return data }
    public static func decode(_ data:Data) throws -> Self { guard data.count <= 65536 else { throw CaptureActionFailure.invalidSettings };let result=try JSONDecoder().decode(Self.self,from:data);guard result.valid else { throw CaptureActionFailure.invalidSettings };return result }
}
public enum CaptureActionFailure:LocalizedError {
    case invalidSettings,noPin,imageRequired
    public var errorDescription:String? {
        switch self {
        case .invalidSettings:return "Capture action settings are invalid or contain duplicate shortcuts."
        case .noPin:return "Show or select a pin before running this action."
        case .imageRequired:return "This action requires an image pin."
        }
    }
}
