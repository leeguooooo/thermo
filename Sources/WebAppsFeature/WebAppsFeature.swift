import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n

/// The bundled local web apps (PDF, Photo Studio, Time Tracking). Each is its own switch in the
/// feature centre and keeps one web view for as long as it is on.
package enum WebAppsFeature {
    package static func registrations() -> [NativeFeatureDefinition] { WebApp.allCases.map(definition) }
    static func definition(_ app: WebApp) -> NativeFeatureDefinition {
        let scene = "webapp:\(app.slug)", route = app.route
        return .init(manifest: app.manifest, ui: .init(sidebarLocations: [.workspace]),
                     resolveLegacyPage: { $0 == scene ? route : nil },
                     makeSession: { WebAppSession(app: app, availability: $0) })
    }
}

enum WebApp: String, CaseIterable, Sendable {
    case pdf, photoStudio = "photo-studio", timeTracking = "time-tracking"
    var manifest: ModuleManifest {
        switch self {
        case .pdf: return BuiltinModuleManifests.pdf
        case .photoStudio: return BuiltinModuleManifests.photoStudio
        case .timeTracking: return BuiltinModuleManifests.timeTracking
        }
    }
    /// The folder name under `Resources/WebApps` and the host of its `thermo-webapp://` URLs.
    var slug: String { rawValue }
    var tint: Color {
        switch self {
        case .pdf: return .red
        case .photoStudio: return .purple
        case .timeTracking: return .orange
        }
    }
    /// Only Time Tracking keeps documents through Puter's cloud API; the shim answers it from this Mac.
    var needsLocalStore: Bool { self == .timeTracking }
    var route: NativeFeatureRoute { .init(manifest.id, "home") }
}

@MainActor final class WebAppSession: NativeFeatureSession {
    let app: WebApp
    private let availability: FeatureAvailability
    private var host: WebAppHost?
    init(app: WebApp, availability: FeatureAvailability) { self.app = app; self.availability = availability }

    func ui(_ surface: NativeUISurface, navigation: NativeNavigation) -> AnyView? {
        guard availability.acceptsWork, case let .sidebar(location, _, rows) = surface, location == .workspace else { return nil }
        return AnyView(rows(.init(route: app.route, tint: app.tint)))
    }
    func page(_ route: NativeFeatureRoute, navigation: NativeNavigation) -> AnyView? {
        guard availability.acceptsWork, route.entry == "home" else { return nil }
        guard let root = WebAppResources.root(for: app) else { return AnyView(WebAppMissingView(app: app)) }
        let host = self.host ?? WebAppHost(app: app, root: root)
        self.host = host
        return AnyView(WebAppPage(host: host))
    }
    var status: NativeFeatureStatus { .init(modelLoaded: host != nil, snapshotReady: true) }
    func retireVisibility() {}
    func quitBlocker() -> NativeFeatureBlocker? { nil }
    func prepareStop() throws -> NativeFeatureDrain {
        let host = self.host
        self.host = nil
        host?.close()
        return .init(finish: {})
    }
}

enum WebAppResources {
    /// The built app inside Thermo.app, or for a development build the staged copy under `.build/webapps`.
    static func root(for app: WebApp, bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [URL] = []
        if let dir = environment["THERMO_WEBAPPS_DIR"] { candidates.append(URL(fileURLWithPath: dir)) }
        if let resources = bundle.resourceURL { candidates.append(resources.appendingPathComponent("WebApps")) }
        let exe = bundle.executableURL?.path ?? CommandLine.arguments[0]
        if let range = exe.range(of: "/.build/") {
            candidates.append(URL(fileURLWithPath: String(exe[..<range.lowerBound]) + "/.build/webapps"))
        }
        return candidates.map { $0.appendingPathComponent(app.slug) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }
    /// Where Time Tracking's documents live. Never inside the app bundle, so updates keep them.
    static func dataDirectory(for app: WebApp) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thermo/WebApps/\(app.slug)", isDirectory: true)
    }
}

struct WebAppMissingView: View {
    let app: WebApp
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: app.manifest.symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(tr(app.manifest.name)).font(.title3.weight(.semibold))
            Text(tr("This build of Thermo does not include the app's files. Run scripts/build-web-apps.sh, then open it again."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
