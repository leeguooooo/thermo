import AppKit
import Foundation

public struct CaptureVectorAnnotation: Codable, Sendable {
    public var tool:CaptureTool
    public var points:[CGPoint]
    public var rgba:[Double]
    public var width:Double
    public var text:String
    public var start:Double
    public var end:Double
    public var options:CaptureAnnotationOptions?
    public init(_ annotation:CaptureAnnotation,start:Double,end:Double) {
        tool=annotation.tool; points=annotation.points; width=annotation.width; text=annotation.text; self.start=start; self.end=end;options=annotation.options
        let color=annotation.color.usingColorSpace(.deviceRGB) ?? .red
        rgba=[color.redComponent,color.greenComponent,color.blueComponent,color.alphaComponent]
    }
    public var annotation:CaptureAnnotation? {
        guard valid else { return nil }
        return .init(tool:tool,points:points,color:NSColor(deviceRed:rgba[0],green:rgba[1],blue:rgba[2],alpha:rgba[3]),width:width,text:text,options:options ?? .init())
    }
    var valid:Bool {
        tool != .move && tool != .select && tool != .crop && !points.isEmpty && points.count <= 100000 && points.allSatisfy { $0.x.isFinite && $0.y.isFinite } &&
        rgba.count == 4 && rgba.allSatisfy { $0.isFinite && (0...1).contains($0) } && width.isFinite && (1...1000).contains(width) &&
        text.count <= 20000 && start.isFinite && end.isFinite && start >= 0 && end > start && (options?.valid ?? true)
    }
}

public struct CaptureNormalEdits: Codable, Sendable {
    public enum Progress:String,Codable,CaseIterable,Sendable { case none, elapsed, remaining }
    public var showCursor=true
    public var showClicks=true
    public var cursorScale=1.0
    public var progress:Progress = .none
    public var watermark=""
    /// Normalized bottom-left crop coordinates. The raw source remains intact.
    public var crop=CGRect(x:0,y:0,width:1,height:1)
    public var annotations:[CaptureVectorAnnotation]=[]
    public var systemVolume=1.0
    public var microphoneVolume:Double?
    public var camera:CaptureCameraEdits?
    public var keyboard:CaptureKeyboardEdits?
    public init() {}
    public var valid:Bool {
        cursorScale.isFinite && (0.25...4).contains(cursorScale) && watermark.count <= 2000 &&
        crop.minX.isFinite && crop.minY.isFinite && crop.width.isFinite && crop.height.isFinite && crop.minX >= 0 && crop.minY >= 0 &&
        crop.maxX <= 1.000001 && crop.maxY <= 1.000001 && crop.width > 0 && crop.height > 0 &&
        annotations.count <= 1000 && annotations.allSatisfy(\.valid) && systemVolume.isFinite && (0...1).contains(systemVolume) && (microphoneVolume.map { $0.isFinite && (0...1).contains($0) } ?? true) && (camera?.valid ?? true) && (keyboard?.valid ?? true)
    }
    public func save(to archive:URL) throws {
        guard valid else { throw CaptureMovieFailure.invalidConfiguration }
        let data=try JSONEncoder().encode(self)
        guard data.count <= 4*1024*1024 else { throw CaptureMovieFailure.invalidConfiguration }
        try data.write(to:archive.appendingPathComponent("edits.json"),options:.atomic)
    }
    public static func load(from archive:URL) throws -> CaptureNormalEdits {
        let url=archive.appendingPathComponent("edits.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return CaptureNormalEdits() }
        guard try CaptureFrameArchiveSource.regular(url),(try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 4*1024*1024 else { throw CaptureMovieFailure.invalidConfiguration }
        let result=try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        guard result.valid else { throw CaptureMovieFailure.invalidConfiguration }; return result
    }
}
