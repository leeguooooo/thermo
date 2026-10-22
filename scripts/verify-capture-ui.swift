// Link with the debug ThermoApp module to exercise production capture UI without the helper.
@testable import ThermoApp
import AppKit
import CaptureCore
import ThermoL10n

@main struct CaptureReview {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        L10n.override = .simplifiedChinese
        let ctx = CGContext(data: nil,width: 900,height: 600,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0,y: 0,width: 900,height: 600))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx,flipped: false)
        ("Thermo capture QA\n截图、标注、贴图\nOCR local recognition 12345" as NSString).draw(at: CGPoint(x: 60,y: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let menu = NSMenu(), top = NSMenuItem(), items = NSMenu()
        items.addItem(withTitle: "Quit QA",action: #selector(NSApplication.terminate(_:)),keyEquivalent: "q")
        top.submenu = items; menu.addItem(top); app.mainMenu = menu
        let image = ctx.makeImage()!
        CaptureWorkspace.shared.open(image)
        DispatchQueue.main.asyncAfter(deadline: .now()+600) { app.terminate(nil) }
        app.run()
    }
}
