// Offline native view rendering; never activates or drives the installed app.
// Link this file, MCPDefinitionStore.swift and MCPInspectionView.swift with Debug AgentDoctor/AgentCore/ThermoL10n libraries.
// Arguments: inspection JSON (ISO-8601 dates), output PNG.
import AgentDoctor
import AppKit
import SwiftUI
import ThermoL10n

@main @MainActor enum RenderMCPInspection {
    static func main() throws {
        _ = NSApplication.shared
        L10n.override = .simplifiedChinese
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var report = try decoder.decode(MCPInspection.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        report.message = tr(report.message)
        report.measurementNote = tr(report.measurementNote)
        let host = NSHostingView(rootView: MCPInspectionResultView(report: report).padding(24).frame(width: 640, height: 410).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        let frame = NSRect(x: 0, y: 0, width: 640, height: 410)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Rendered \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
