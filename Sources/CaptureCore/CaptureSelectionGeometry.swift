import CoreGraphics

/// Geometry for the screenshot selector. All rectangles are display-local points with a top-left
/// origin (the selector view is flipped), so window bounds from Quartz map over by an offset.
public enum CaptureSelectionHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

public enum CaptureSelectionGeometry {
    /// A drag shorter than this counts as a click (select the hovered window or display).
    public static let clickSlop: CGFloat = 4
    /// Smallest selection kept after a drag or resize, in points.
    public static let minimumSide: CGFloat = 4

    public static func rect(from a: CGPoint, to b: CGPoint, in bounds: CGRect) -> CGRect {
        let raw = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        return clamp(raw, to: bounds)
    }

    /// Front-most window containing the point. `windows` must be ordered front to back.
    public static func window(at point: CGPoint, in windows: [CGRect], bounds: CGRect) -> CGRect? {
        for window in windows where window.contains(point) {
            let visible = window.intersection(bounds)
            if !visible.isNull, visible.width >= minimumSide, visible.height >= minimumSide { return visible }
        }
        return nil
    }

    public static func handlePoint(_ handle: CaptureSelectionHandle, of r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// Corners win over edges when a small selection puts them within reach of each other.
    public static func handle(at point: CGPoint, of rect: CGRect, tolerance: CGFloat = 6) -> CaptureSelectionHandle? {
        let near = { (p: CGPoint) in abs(p.x - point.x) <= tolerance && abs(p.y - point.y) <= tolerance }
        let corners: [CaptureSelectionHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        if let corner = corners.first(where: { near(handlePoint($0, of: rect)) }) { return corner }
        let inY = point.y >= rect.minY - tolerance && point.y <= rect.maxY + tolerance
        let inX = point.x >= rect.minX - tolerance && point.x <= rect.maxX + tolerance
        if inY, abs(point.x - rect.minX) <= tolerance { return .left }
        if inY, abs(point.x - rect.maxX) <= tolerance { return .right }
        if inX, abs(point.y - rect.minY) <= tolerance { return .top }
        if inX, abs(point.y - rect.maxY) <= tolerance { return .bottom }
        return nil
    }

    /// Moves the dragged edges to `point`; dragging past the opposite edge flips the selection.
    public static func resize(_ rect: CGRect, handle: CaptureSelectionHandle, to point: CGPoint, in bounds: CGRect) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        return self.rect(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: maxY), in: bounds)
    }

    /// Moves without changing size; stops at the display edges.
    public static func move(_ rect: CGRect, by dx: CGFloat, _ dy: CGFloat, in bounds: CGRect) -> CGRect {
        var moved = rect.offsetBy(dx: dx, dy: dy)
        moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - min(rect.width, bounds.width))
        moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - min(rect.height, bounds.height))
        return moved
    }

    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let clipped = rect.intersection(bounds)
        return clipped.isNull ? CGRect(origin: CGPoint(x: min(max(rect.minX, bounds.minX), bounds.maxX), y: min(max(rect.minY, bounds.minY), bounds.maxY)), size: .zero) : clipped
    }

    /// Selector toolbar lines: each group (tools, then outputs) starts its own line and wraps when
    /// wider than `maxWidth`. The first group lines up on the left, later groups on the right, so
    /// the primary output stays at the far right. Frames are in the toolbar's top-left space.
    public static func toolbarLayout(_ groups: [[CGSize]], maxWidth: CGFloat, spacing: CGFloat = 4, padding: CGFloat = 6) -> (frames: [[CGRect]], size: CGSize) {
        let available = max(1, maxWidth - padding * 2)
        var lines: [(group: Int, items: [Int], width: CGFloat, height: CGFloat)] = []
        for (group, sizes) in groups.enumerated() {
            for (index, size) in sizes.enumerated() {
                if var line = lines.last, line.group == group, line.width + spacing + size.width <= available {
                    line.items.append(index); line.width += spacing + size.width; line.height = max(line.height, size.height)
                    lines[lines.count - 1] = line
                } else { lines.append((group, [index], size.width, size.height)) }
            }
        }
        let width = (lines.map(\.width).max() ?? 0) + padding * 2
        var frames = groups.map { Array(repeating: CGRect.zero, count: $0.count) }, y = padding
        for line in lines {
            var x = line.group == 0 ? padding : width - padding - line.width
            for index in line.items {
                let size = groups[line.group][index]
                frames[line.group][index] = CGRect(x: x, y: y + (line.height - size.height) / 2, width: size.width, height: size.height)
                x += size.width + spacing
            }
            y += line.height + spacing
        }
        return (frames, CGSize(width: width, height: lines.isEmpty ? 0 : y - spacing + padding))
    }

    /// Below the selection, above it when there is no room below, inside its bottom edge when
    /// neither fits; right-aligned with the selection and kept inside `bounds`.
    public static func toolbarOrigin(size: CGSize, selection: CGRect, bounds: CGRect, gap: CGFloat = 8, margin: CGFloat = 4) -> CGPoint {
        var origin = CGPoint(x: selection.maxX - size.width, y: selection.maxY + gap)
        if origin.y + size.height > bounds.maxY - margin { origin.y = selection.minY - size.height - gap }
        if origin.y < bounds.minY + margin { origin.y = selection.maxY - size.height - gap }
        origin.x = max(min(origin.x, bounds.maxX - size.width - margin), bounds.minX + margin)
        origin.y = max(min(origin.y, bounds.maxY - size.height - margin), bounds.minY + margin)
        return origin
    }

    /// Image pixels covered by a point rectangle. `scale` is image pixels per point, so a frozen
    /// frame of any resolution maps exactly; edges are rounded outward to whole pixels.
    public static func pixelRect(_ rect: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect? {
        guard scale.isFinite, scale > 0, [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return nil }
        let x0 = (rect.minX * scale).rounded(.down), y0 = (rect.minY * scale).rounded(.down)
        let x1 = (rect.maxX * scale).rounded(.up), y1 = (rect.maxY * scale).rounded(.up)
        let pixels = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).intersection(CGRect(origin: .zero, size: imageSize))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }
        return pixels
    }

    /// A point drawn on the selector (display points, top-left origin) in the cropped screenshot's
    /// pixel space, which CaptureAnnotation uses with a bottom-left origin.
    public static func imagePoint(_ point: CGPoint, scale: CGFloat, crop: CGRect) -> CGPoint {
        CGPoint(x: point.x * scale - crop.minX, y: crop.height - (point.y * scale - crop.minY))
    }

    /// Pixel size shown next to the selection.
    public static func pixelSize(_ rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()))
    }

    public static func hex(red: UInt8, green: UInt8, blue: UInt8) -> String {
        "#" + [red, green, blue].map { byte in
            let digits = String(byte, radix: 16, uppercase: true)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }
}
