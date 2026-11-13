import AppKit
import ModuleKit

@MainActor enum ModuleSnapshotCompositor {
    static func capture(_ root: NSView, overlays: [(frame: CGRect, png: Data)]) throws -> Data {
        root.layoutSubtreeIfNeeded()
        guard !root.bounds.isEmpty, let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            throw ModuleError.failed("host view cannot be rendered")
        }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let base = rep.cgImage,
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ModuleError.failed("host bitmap cannot be created")
        }
        context.draw(base, in: CGRect(x: 0, y: 0, width: CGFloat(base.width), height: CGFloat(base.height)))
        let sx = CGFloat(base.width) / root.bounds.width, sy = CGFloat(base.height) / root.bounds.height
        for overlay in overlays {
            guard let dimensions = ModuleSnapshot.dimensions(overlay.png), let image = NSBitmapImageRep(data: overlay.png)?.cgImage,
                  image.width == dimensions.width, image.height == dimensions.height else { throw ModuleError.failed("invalid scene bitmap") }
            let frame = overlay.frame
            guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
                  frame.width > 0, frame.height > 0 else { throw ModuleError.failed("invalid scene frame") }
            let y = root.isFlipped ? root.bounds.maxY - frame.maxY : frame.minY - root.bounds.minY
            context.draw(image, in: CGRect(x: (frame.minX - root.bounds.minX) * sx, y: y * sy,
                                          width: frame.width * sx, height: frame.height * sy))
        }
        guard let output = context.makeImage(), let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else {
            throw ModuleError.failed("composed snapshot could not be encoded")
        }
        return png
    }
}
