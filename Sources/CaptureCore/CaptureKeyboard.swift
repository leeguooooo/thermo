import Foundation

public enum CaptureKeyMode:String,Codable,CaseIterable,Sendable { case hidden, shortcuts, all }
public struct CaptureKeyEvent:Codable,Sendable,Equatable {
    public let time:Double
    public let label:String
    public let shortcut:Bool
    public let repeated:Bool
    public init(time:Double,label:String,shortcut:Bool,repeated:Bool = false) { self.time=time;self.label=label;self.shortcut=shortcut;self.repeated=repeated }
    var valid:Bool { time.isFinite && time >= 0 && !label.isEmpty && label.count <= 32 && !label.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
}
public struct CaptureKeyboardEdits:Codable,Sendable {
    public var mode:CaptureKeyMode = .shortcuts
    public var hold=1.2
    public var scale=1.0
    public var top=false
    public init() {}
    public var valid:Bool { hold.isFinite && (0.2...5).contains(hold) && scale.isFinite && (0.5...3).contains(scale) }
}
