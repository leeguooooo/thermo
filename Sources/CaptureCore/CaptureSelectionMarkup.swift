import AppKit

/// One mark drawn on the screenshot selector, in selector points (top-left origin).
public struct CaptureSelectionMark: Equatable, Sendable {
    public let tool: CaptureTool
    public var points: [CGPoint]
    /// Typed text for `.text`, the badge value for `.number`.
    public var text: String
    public init(tool: CaptureTool, points: [CGPoint], text: String = "") { self.tool = tool; self.points = points; self.text = text }
}

/// The marks of one capture and their undo/redo record. Only marks are kept, never the frozen
/// screen, so history stays cheap while the selector is open.
public struct CaptureSelectionMarkup: Sendable {
    public private(set) var marks: [CaptureSelectionMark] = []
    private var undone: [CaptureSelectionMark] = []
    public init() {}
    public var canUndo: Bool { !marks.isEmpty }
    public var canRedo: Bool { !undone.isEmpty }
    public mutating func add(_ mark: CaptureSelectionMark) { marks.append(mark); undone.removeAll() }
    public mutating func undo() { if let mark = marks.popLast() { undone.append(mark) } }
    public mutating func redo() { if let mark = undone.popLast() { marks.append(mark) } }
    public var nextNumber: Int { (marks.filter { $0.tool == .number }.compactMap { Int($0.text) }.max() ?? 0) + 1 }

    /// Mosaic hides the screenshot underneath, never the user's own boxes and arrows: effects go
    /// first, then the drawn marks on top, in the preview and the saved image alike.
    public var layered: [CaptureSelectionMark] { marks.filter { $0.tool == .mosaic } + marks.filter { $0.tool != .mosaic } }

    /// The annotation the saved image draws for a mark. `scale` is image pixels per selector point;
    /// `crop` is the selection in the frozen frame's pixels.
    public static func annotation(_ mark: CaptureSelectionMark, scale: CGFloat, crop: CGRect) -> CaptureAnnotation {
        let points = mark.points.map { CaptureSelectionGeometry.imagePoint($0, scale: scale, crop: crop) }
        // Text and badges size their font from the width (max(18, width × 6) pixels); 3 points keeps them legible at any scale.
        let width = max(2, ((mark.tool == .text || mark.tool == .number ? 3 : 2) * scale).rounded())
        var options = CaptureAnnotationOptions()
        if mark.tool == .number { options.numberValue = Int(mark.text) }
        return CaptureAnnotation(tool: mark.tool, points: points, color: .systemRed, width: width, text: mark.text, options: options)
    }

    /// The selection with its marks burnt in, or nil when there are none and the crop is used as is.
    public func rendered(onto cropped: CGImage, crop: CGRect, scale: CGFloat) throws -> CGImage? {
        guard !marks.isEmpty else { return nil }
        var document = CaptureDocument(image: cropped)
        for mark in layered { document.append(Self.annotation(mark, scale: scale, crop: crop)) }
        return try document.rendered()
    }
}

/// What each selector output asks the capture pipeline to do once the selector closes. Interactive
/// captures name their output explicitly, so the saved after-capture chain (default: pin) is not
/// replayed behind the user's back; scripts and configured actions keep their own steps.
// Note: 交互截图只跑用户点的输出，不回放默认贴图的动作链 — 见 .agents/notes/implemented/feature/2026-11-10-capture-toolbar.md。
public enum CaptureSelectionOutput: Equatable, Sendable {
    case primary(confirm: [CaptureAfterStep]?), copyImage, pin, saved(copyAfterSave: Bool), copyText
    public var steps: [CaptureAfterStep] {
        switch self {
        case .primary(let confirm): return confirm ?? [.copyImage]
        case .copyImage: return [.copyImage]
        case .pin: return [.pin]
        case .saved(let copy): return copy ? [.copyImage] : []
        case .copyText: return [.copyText]
        }
    }
    /// Enter's steps: an action's or script's own steps, a script's saved chain, otherwise nil (copy).
    public static func confirm(override: [CaptureAfterStep]?, scripted: Bool, saved: [CaptureAfterStep]) -> [CaptureAfterStep]? {
        override ?? (scripted ? saved : nil)
    }
}
