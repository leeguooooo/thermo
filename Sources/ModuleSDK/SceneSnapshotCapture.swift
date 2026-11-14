import AppKit
import ModuleKit
import WebKit

/// AppKit's cached display omits WebKit's remote surfaces. Ask each visible web
/// view for its own pixels and compose them inside the module's process.
@MainActor enum SceneSnapshotCapture {
    enum Failure: LocalizedError {
        case unavailable, loading, limits, changed
        var errorDescription: String? {
            switch self {
            case .unavailable: "scene could not be rendered"
            case .loading: "scene web content is still loading"
            case .limits: "scene snapshot exceeds pixel limits"
            case .changed: "scene changed during snapshot"
            }
        }
    }
    static func capture(_ root: NSView) async throws -> Data {
        root.layoutSubtreeIfNeeded()
        let bounds = root.bounds, window = root.window
        guard let rep = root.bitmapImageRepForCachingDisplay(in: bounds),
              rep.pixelsWide > 0, rep.pixelsHigh > 0,
              rep.pixelsWide <= ModuleSnapshot.maxDimension, rep.pixelsHigh <= ModuleSnapshot.maxDimension,
              rep.pixelsWide * rep.pixelsHigh <= ModuleSnapshot.maxPixels else { throw Failure.limits }
        root.cacheDisplay(in: bounds, to: rep)
        guard let base = rep.cgImage,
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure.unavailable
        }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        var webViews: [WKWebView] = []
        func collect(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0 else { return }
            if let web = view as? WKWebView { webViews.append(web); return }
            for child in view.subviews { collect(child) }
        }
        collect(root)
        guard webViews.count <= 16 else { throw Failure.limits }
        let sx = CGFloat(base.width) / bounds.width, sy = CGFloat(base.height) / bounds.height
        for web in webViews {
            let rect = web.visibleRect.intersection(web.bounds)
            guard !rect.isEmpty else { continue }
            guard !web.isLoading else { throw Failure.loading }
            let frame = root.convert(rect, from: web)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = rect
            configuration.afterScreenUpdates = false
            configuration.snapshotWidth = NSNumber(value: Double(rect.width))
            let pixels: CGImage
            do {
                let image = try await web.takeSnapshot(configuration: configuration)
                guard let image = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure.unavailable }
                pixels = image
            } catch {
                // An offscreen remote scene may have no WindowServer-backed surface.
                // WebKit can still render the same viewport without that surface.
                let pdfConfiguration = WKPDFConfiguration(); pdfConfiguration.rect = rect
                let data = try await web.pdf(configuration: pdfConfiguration)
                guard data.count <= ModuleSnapshot.maxBytes,
                      let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
                      let page = document.page(at: 1),
                      let bitmap = CGContext(data: nil, width: Int(ceil(rect.width * sx)), height: Int(ceil(rect.height * sy)),
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.unavailable }
                bitmap.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height), rotate: 0, preserveAspectRatio: false))
                bitmap.drawPDFPage(page)
                guard let image = bitmap.makeImage() else { throw Failure.unavailable }
                pixels = image
            }
            guard root.window === window, root.bounds == bounds, web.isDescendant(of: root),
                  root.convert(rect, from: web) == frame else { throw Failure.changed }
            let y = root.isFlipped ? bounds.maxY - frame.maxY : frame.minY - bounds.minY
            context.draw(pixels, in: CGRect(x: (frame.minX - bounds.minX) * sx, y: y * sy,
                                           width: frame.width * sx, height: frame.height * sy))
        }
        guard let output = context.makeImage(), let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]),
              ModuleSnapshot.dimensions(png) != nil else { throw Failure.limits }
        return png
    }
}
