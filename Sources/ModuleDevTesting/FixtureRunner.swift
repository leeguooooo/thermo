import AppKit
import Foundation
import ModuleDevKit
import ModuleKernelCore
import ModuleKit
import SwiftUI
import ThermoUI
import WasmHost

/// One `fixtures/*.json`: what to ask the module, what the kernel answers, and what must show.
///
///     {"scene": "main", "language": "en", "action": "refresh", "values": {"name": "x"},
///      "answers": {"processes.read": {"processes": [{"pid": 1}]}, "files.read": "denied"},
///      "expect": ["Processes", "1"], "snapshot": true}
///
/// `answers` replaces the Mac: a declared capability gets the fixture's answer ("denied" and "failed"
/// refuse it), an undeclared one is still refused by the broker exactly as in the app.
public struct ModuleFixture: Codable, Sendable, Equatable {
    public var scene: String
    public var language: String?
    public var action: String?
    public var values: [String: ModuleView.Value]?
    public var answers: [String: JSONValue]?
    public var expect: [String]?
    public var snapshot: Bool?
}

public struct FixtureResult: Sendable, Equatable {
    public var name: String
    public var problems: [String]
    public var view: ModuleView?
    public var passed: Bool { problems.isEmpty }
}

public enum FixtureRunner {
    public static func fixtures(_ source: ModuleSource) throws -> [(name: String, fixture: ModuleFixture)] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: source.fixturesURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { file in
            do { return (file.deletingPathExtension().lastPathComponent, try JSONDecoder().decode(ModuleFixture.self, from: Data(contentsOf: file))) }
            catch { throw ModuleSource.Failure("fixtures/\(file.lastPathComponent): \(error)") }
        }
    }

    /// The broker handlers a fixture's answers stand for.
    public static func handlers(_ answers: [String: JSONValue]) throws -> [Capability.Kind: CapabilityBroker.Handler] {
        var handlers: [Capability.Kind: CapabilityBroker.Handler] = [:]
        for (key, answer) in answers {
            guard let kind = Capability.Kind(rawValue: key) else { throw ModuleSource.Failure("answers: unknown capability \(key)") }
            switch answer.string {
            case "denied"?: handlers[kind] = { _ in throw BrokerError(.denied, "denied by the fixture") }
            case "failed"?: handlers[kind] = { _ in throw BrokerError(.failed, "failed by the fixture") }
            default:
                let data = try JSONEncoder().encode(answer)
                handlers[kind] = { _ in BrokerAnswer(data) }
            }
        }
        return handlers
    }

    /// Runs one fixture against `module` and checks the expected text appears in the result.
    public static func run(_ name: String, _ fixture: ModuleFixture, module: DeclarativeModule) async -> FixtureResult {
        let language = fixture.language ?? "en"
        do {
            let view: ModuleView
            if let action = fixture.action {
                view = try await module.perform(action, values: fixture.values ?? [:], scene: fixture.scene, language: language)
            } else {
                view = try await module.render(scene: fixture.scene, language: language)
            }
            let text = String(decoding: try JSONEncoder().encode(view), as: UTF8.self)
            let missing = (fixture.expect ?? []).filter { !text.contains($0) }
            return FixtureResult(name: name, problems: missing.map { "expected text not shown: \($0)" }, view: view)
        } catch {
            return FixtureResult(name: name, problems: [(error as? DeclarativeModule.Failure)?.description ?? "\(error)"], view: nil)
        }
    }

    public static func module(_ manifest: ModuleManifest, wasm: Data, fixture: ModuleFixture, runner: URL, home: String) throws -> DeclarativeModule {
        let broker = CapabilityBroker(manifest: manifest, home: home, log: ModuleAccessLog(home: home), handlers: try handlers(fixture.answers ?? [:]))
        return DeclarativeModule(host: WasmHost(manifest: manifest, wasm: wasm, broker: broker, launcher: .process(runner)))
    }
}

/// Offscreen pictures of a page, drawn by the same SwiftUI views the app uses.
@MainActor public enum PageSnapshot {
    public static let size = NSSize(width: 760, height: 620)

    /// PNG of `view` as the app would draw the page. AppKit-backed controls (switches, text fields)
    /// need a real window, so the page is hosted in an offscreen one rather than an ImageRenderer.
    public static func png(_ view: ModuleView, manifest: ModuleManifest, scene: String) async throws -> Data {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let module = DeclarativeModule(manifest: manifest) { _, _ in
            WasmHost.Result(status: 0, output: try JSONEncoder().encode(view))
        }
        let model = DeclarativeSceneModel(module: module, scene: scene, language: { "en" })
        await model.load()
        let title = manifest.entries.first { $0.scene == scene }?.title ?? manifest.name
        let host = NSHostingView(rootView: DeclarativePageView(model: model, fallbackTitle: title)
            .frame(width: size.width, height: size.height).background(Theme.canvas))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 50_000_000) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ModuleSource.Failure("could not draw the page") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ModuleSource.Failure("could not encode the snapshot") }
        return png
    }

    /// Share of pixels that differ by more than `tolerance` in any channel, or nil when sizes differ.
    /// Fonts and antialiasing vary a little between Macs; compare against a threshold, not equality.
    nonisolated public static func difference(_ a: Data, _ b: Data, tolerance: Int = 24) -> Double? {
        guard let x = NSBitmapImageRep(data: a), let y = NSBitmapImageRep(data: b),
              x.pixelsWide == y.pixelsWide, x.pixelsHigh == y.pixelsHigh else { return nil }
        var differing = 0
        for row in 0..<x.pixelsHigh {
            for column in 0..<x.pixelsWide {
                guard let p = x.colorAt(x: column, y: row)?.usingColorSpace(.sRGB), let q = y.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                let channels = [(p.redComponent, q.redComponent), (p.greenComponent, q.greenComponent), (p.blueComponent, q.blueComponent)]
                if channels.contains(where: { abs(Int(($0.0 - $0.1) * 255)) > tolerance }) { differing += 1 }
            }
        }
        return Double(differing) / Double(max(1, x.pixelsWide * x.pixelsHigh))
    }
}
