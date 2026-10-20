import AppKit
import CoreText

/// A status button's cell treats a multiline title as ordinary button text and
/// may compress or clip it. Draw both rows inside one measured template image.
enum MenuStackImage {
    static func make(text: String, showIcon: Bool, height: CGFloat) -> NSImage {
        let height = max(12, min(20, height))
        let rows = text.components(separatedBy: "\n")
        let strings = [rows.first ?? "", rows.dropFirst().joined(separator: " ")]
        let padding: CGFloat = 1
        let gap: CGFloat = 1
        let rowHeight = (height - 2 * padding - gap) / 2
        var size: CGFloat = 9
        func lines(_ size: CGFloat) -> [(CTLine, CGRect)] {
            let name = NSFont.monospacedSystemFont(ofSize: size, weight: .medium).fontName
            let font = CTFontCreateWithName(name as CFString, size, nil)
            return strings.map {
                let attributed = NSAttributedString(string: $0, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor,
                ])
                let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
                return (line, CTLineGetImageBounds(line, nil))
            }
        }
        var measured = lines(size)
        while size > 6, measured.contains(where: { $0.1.height > rowHeight }) {
            size -= 0.25
            measured = lines(size)
        }
        let textWidth = ceil(measured.map { $0.1.isNull ? 0 : $0.1.width }.max() ?? 0) + 2 * padding
        let iconWidth: CGFloat = showIcon ? 15 : 0
        let imageSize = NSSize(width: iconWidth + max(1, textWidth), height: height)
        let renderedLines = measured
        let image = NSImage(size: imageSize, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.textMatrix = .identity
            if showIcon, let icon = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil) {
                icon.draw(in: NSRect(x: rect.minX + 1, y: rect.midY - 6, width: 12, height: 12))
            }
            for (index, entry) in renderedLines.enumerated() {
                let (line, ink) = entry
                guard !ink.isNull else { continue }
                let bottom = rect.minY + padding + (index == 0 ? rowHeight + gap : 0)
                context.textPosition = CGPoint(
                    x: rect.minX + iconWidth + (textWidth - ink.width) / 2 - ink.minX,
                    y: bottom + (rowHeight - ink.height) / 2 - ink.minY)
                CTLineDraw(line, context)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
