import AgentDoctor
import AppKit
import SwiftUI
import ThermoL10n
@main @MainActor enum RenderObservedUsage {
    static func main() throws {
        _ = NSApplication.shared
        L10n.override = .simplifiedChinese
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var report = try decoder.decode(ToolUsageReport.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        report.note = tr(report.note)
        let model = ToolUsageModel(report: report)
        let height = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 620 : 620
        guard height.isFinite, (620...4096).contains(height) else { fatalError("Height must be between 620 and 4096") }
        let host = NSHostingView(rootView: ToolUsagePanel(model: model, kind: "mcp").padding(24).frame(width: 760, height: height).background(Color(red: 0.04, green: 0.10, blue: 0.18)).environment(\.colorScheme, .dark))
        let frame = NSRect(x: 0, y: 0, width: 760, height: height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua); window.contentView = host; host.frame = frame
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Rendered \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
