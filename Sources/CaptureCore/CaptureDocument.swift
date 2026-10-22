import AppKit
import Vision

public enum CaptureTool: String, CaseIterable, Identifiable, Codable, Sendable {
    case move, select, rectangle, ellipse, line, arrow, pencil, highlight, redact, mosaic, blur, eraser, eraserRect, spotlight, magnifier, watermark, text, number, crop
    public var id: String { rawValue }
}

/// Points use the original image's pixel coordinates, with the origin at bottom left.
public struct CaptureAnnotation {
    public let tool: CaptureTool
    public var points: [CGPoint]
    public var color: NSColor
    public var width: CGFloat
    public var text: String
    public var options:CaptureAnnotationOptions
    public init(tool: CaptureTool, points: [CGPoint], color: NSColor = .systemRed, width: CGFloat = 4, text: String = "",options:CaptureAnnotationOptions = .init()) {
        self.tool = tool; self.points = points; self.color = color; self.width = width; self.text = text;self.options=options
    }
}

public enum CaptureFailure: LocalizedError {
    case invalidImage, invalidCrop, exportFailed, unsupportedClipboard, captureFailed
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "The image could not be read."
        case .invalidCrop: return "Select an area inside the image."
        case .exportFailed: return "The image could not be exported."
        case .unsupportedClipboard: return "Copy an image, text, or file before pinning."
        case .captureFailed: return "Screen capture failed. Check Screen Recording permission in System Settings."
        }
    }
}

public struct CaptureDocument {
    public private(set) var image: CGImage
    public private(set) var annotations: [CaptureAnnotation] = []
    private struct State { let image: CGImage; let annotations: [CaptureAnnotation] }
    private var history: [State] = []
    private var undone: [State] = []
    public init(image: CGImage,annotations:[CaptureAnnotation] = []) { self.image = image;self.annotations=annotations }
    public var size: CGSize { CGSize(width: image.width, height: image.height) }
    public var canUndo: Bool { !history.isEmpty }
    public var canRedo: Bool { !undone.isEmpty }
    public mutating func append(_ item: CaptureAnnotation) {
        guard !item.points.isEmpty else { return }
        checkpoint(); annotations.append(item)
    }
    private mutating func checkpoint() {
        history.append(State(image: image, annotations: annotations)); undone.removeAll()
        if history.count > 100 { history.removeFirst() }
    }
    public mutating func undo() {
        guard let state = history.popLast() else { return }
        undone.append(State(image: image, annotations: annotations)); image = state.image; annotations = state.annotations
    }
    public mutating func redo() {
        guard let state = undone.popLast() else { return }
        history.append(State(image: image, annotations: annotations)); image = state.image; annotations = state.annotations
    }
    public func rendered(adding draft:CaptureAnnotation? = nil,replacing index:Int? = nil,replacements:[Int:CaptureAnnotation] = [:]) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.invalidImage }
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        for (i,item) in annotations.enumerated() { try Self.draw(replacements[i] ?? (index == i ? draft ?? item : item),in:ctx,base:image) }
        if index == nil,let draft { try Self.draw(draft,in:ctx,base:image) }
        guard let output = ctx.makeImage() else { throw CaptureFailure.invalidImage }
        return output
    }
    public static func draw(_ item: CaptureAnnotation, in ctx: CGContext,base:CGImage? = nil) throws {
        guard item.options.valid,item.width.isFinite,item.width >= 1,item.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw CaptureFailure.invalidImage }
        guard let first = item.points.first, let last = item.points.last else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        let color = item.color.usingColorSpace(.deviceRGB) ?? .red
        ctx.setStrokeColor(color.cgColor); ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(max(1, item.width)); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x-first.x), height: abs(last.y-first.y))
        switch item.tool {
        case .mosaic,.blur,.eraser,.eraserRect,.spotlight,.magnifier,.watermark: try effect(item,in:ctx,base:base)
        case .rectangle: ctx.stroke(rect)
        case .ellipse: ctx.strokeEllipse(in: rect)
        case .redact:
            // Opaque fill intentionally removes source pixels from exported output.
            ctx.setFillColor(NSColor.black.cgColor); ctx.fill(rect)
        case .highlight:
            ctx.setBlendMode(.multiply); ctx.setAlpha(0.35); ctx.fill(rect)
        case .line, .arrow, .pencil:
            ctx.beginPath(); ctx.move(to: first)
            for point in item.points.dropFirst() { ctx.addLine(to: point) }; ctx.strokePath()
            if item.tool == .arrow {
                let angle = atan2(last.y-first.y, last.x-first.x), length = max(12, item.width*4)
                ctx.move(to: CGPoint(x: last.x-length*cos(angle-0.5), y: last.y-length*sin(angle-0.5)))
                ctx.addLine(to: last)
                ctx.addLine(to: CGPoint(x: last.x-length*cos(angle+0.5), y: last.y-length*sin(angle+0.5)))
                ctx.strokePath()
            }
        case .text, .number:
            let fontSize = max(18, item.width*6)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            if item.tool == .number {
                let circle = CGRect(x: first.x-fontSize, y: first.y-fontSize, width: fontSize*2, height: fontSize*2)
                ctx.fillEllipse(in: circle)
                let text = item.text as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: NSColor.white]
                let s = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: first.x-s.width/2, y: first.y-s.height/2), withAttributes: attributes)
            } else {
                (item.text as NSString).draw(at: first, withAttributes: [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: color])
            }
            NSGraphicsContext.restoreGraphicsState()
        case .move,.select, .crop: break
        }
    }
    public mutating func crop(to requested: CGRect) throws {
        let rect = requested.standardized.intersection(CGRect(origin: .zero, size: size)).integral
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { throw CaptureFailure.invalidCrop }
        // CGImage cropping uses top-left coordinates; the editing canvas uses bottom-left.
        let topRect = CGRect(x: rect.minX, y: size.height-rect.maxY, width: rect.width, height: rect.height)
        guard let result = try rendered().cropping(to: topRect) else { throw CaptureFailure.invalidCrop }
        checkpoint(); image = result; annotations.removeAll()
    }
    public func data(format: NSBitmapImageRep.FileType = .png) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: try rendered())
        guard let data = rep.representation(using: format, properties: [:]) else { throw CaptureFailure.exportFailed }
        return data
    }
    public mutating func transform(rotateClockwise: Bool = false, flipHorizontal: Bool = false) throws {
        let original = try rendered()
        let width = rotateClockwise ? original.height : original.width
        let height = rotateClockwise ? original.width : original.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.invalidImage }
        if rotateClockwise { ctx.translateBy(x: 0, y: CGFloat(height)); ctx.rotate(by: -.pi/2) }
        if flipHorizontal { ctx.translateBy(x: CGFloat(original.width), y: 0); ctx.scaleBy(x: -1, y: 1) }
        ctx.draw(original, in: CGRect(origin: .zero, size: size))
        guard let image = ctx.makeImage() else { throw CaptureFailure.invalidImage }
        checkpoint(); self.image = image; annotations.removeAll()
    }
    public static func load(_ url: URL) throws -> CGImage {
        // Screenshot files are removed before asynchronous after-actions run. Decode now,
        // otherwise a lazy provider can attempt to read an already removed temporary file.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw CaptureFailure.invalidImage }
        return image
    }
}

public struct CaptureRecognition: Sendable {
    public let text: String
    public let codes: [String]
    /// Entirely on-device. Network translation and formula recognition are separate features.
    public static func recognize(_ image: CGImage) throws -> CaptureRecognition {
        let text = VNRecognizeTextRequest(); text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true; text.automaticallyDetectsLanguage = true
        let codes = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([text, codes])
        return CaptureRecognition(text: (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"),
                                  codes: (codes.results ?? []).compactMap(\.payloadStringValue))
    }
}

extension CaptureDocument {
    public func hitTest(_ point:CGPoint,tolerance:CGFloat = 4) -> Int? {
        annotations.indices.reversed().first { index in
            let item=annotations[index]
            guard item.bounds.insetBy(dx:-tolerance,dy:-tolerance).contains(point) else { return false }
            if [.line,.arrow,.pencil,.eraser].contains(item.tool),item.points.count >= 2 {
                for (a,b) in zip(item.points,item.points.dropFirst()) {
                    let dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
                    let t=length > 0 ? min(1,max(0,((point.x-a.x)*dx+(point.y-a.y)*dy)/length)) : 0
                    if hypot(point.x-a.x-t*dx,point.y-a.y-t*dy) <= tolerance+item.width*(item.tool == .eraser ? 2 : 0.5) { return true }
                }
                return false
            }
            return true
        }
    }
    public mutating func replaceAnnotation(at index:Int,with annotation:CaptureAnnotation) {
        guard annotations.indices.contains(index),!annotation.points.isEmpty else { return }
        checkpoint();annotations[index]=annotation
    }
    public mutating func replaceAnnotations(_ replacements:[Int:CaptureAnnotation]) {
        guard !replacements.isEmpty,replacements.allSatisfy({annotations.indices.contains($0.key) && !$0.value.points.isEmpty}) else {return}
        checkpoint()
        for (index,item) in replacements {annotations[index]=item}
    }
    public mutating func removeAnnotations(at indices:Set<Int>) {
        guard !indices.isEmpty,indices.allSatisfy({annotations.indices.contains($0)}) else {return}
        checkpoint()
        for index in indices.sorted(by:>) {annotations.remove(at:index)}
    }
    public mutating func removeAnnotation(at index:Int) {
        guard annotations.indices.contains(index) else { return };checkpoint();annotations.remove(at:index)
    }
    public mutating func clearAnnotations() {
        guard !annotations.isEmpty else { return };checkpoint();annotations.removeAll()
    }
}
