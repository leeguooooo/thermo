import CoreGraphics

/// Pacing for automatic scrolling during a long screenshot: scroll a bit over half a viewport per
/// frame so consecutive frames keep a generous overlap for stitching, and stop when the content
/// stops moving (three frames with nothing new: the end of the page, with room for one slow
/// repaint) or stitching keeps failing.
public struct CaptureAutoScroll: Sendable {
    public static let overlapShare: CGFloat = 0.6
    public static let maximumFrames = 200
    public private(set) var frames = 0
    private var duplicates = 0
    private var failures = 0

    public init() {}

    /// Scroll distance in points for a viewport of the given length along the scroll direction.
    public static func step(viewport: CGFloat) -> CGFloat {
        guard viewport.isFinite, viewport > 0 else { return 40 }
        return max(40, (viewport * overlapShare).rounded())
    }

    public enum Next: Equatable, Sendable { case scroll, finished, gaveUp }

    /// Call after each captured frame. `duplicate` means the frame added nothing new.
    public mutating func record(duplicate: Bool, failed: Bool) -> Next {
        frames += 1
        if failed { failures += 1; duplicates = 0; return failures >= 3 ? .gaveUp : .scroll }
        failures = 0
        duplicates = duplicate ? duplicates + 1 : 0
        if duplicates >= 3 { return .finished }
        return frames >= Self.maximumFrames ? .finished : .scroll
    }
}
