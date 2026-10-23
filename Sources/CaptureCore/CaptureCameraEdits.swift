import Foundation

public struct CaptureCameraEdits:Codable,Sendable {
    public enum Corner:String,Codable,CaseIterable,Sendable { case topLeft, topRight, bottomLeft, bottomRight }
    public enum Shape:String,Codable,CaseIterable,Sendable { case rectangle, circle }
    public var enabled=true
    public var mirrored=true
    public var width=0.25
    public var margin=0.03
    public var corner:Corner = .bottomRight
    public var shape:Shape = .rectangle
    public init() {}
    public var valid:Bool { width.isFinite && (0.05...0.5).contains(width) && margin.isFinite && (0...0.2).contains(margin) }
}
