import Foundation
import ModuleKit
import NativeFeatureAPI
import SystemServicesAPI

/// Composition resolves the same app-owned services only after this feature is admitted.
package enum PerformanceFeature {
    package static func registration(
        telemetry: @escaping @MainActor @Sendable () -> any TelemetryReadService,
        administration: @escaping @MainActor @Sendable () -> any HelperAdministration,
        fanFactory: @escaping @MainActor @Sendable () -> any FanPolicyAccessFactory,
        defaults: @escaping @MainActor @Sendable () -> UserDefaults = { .standard },
        showSettings: @escaping @MainActor @Sendable () -> Void
    ) -> NativeFeatureDefinition {
        let manifest = BuiltinModuleManifests.performance
        func checkText(_ options: [String:NativeContextValue]) throws {
            for value in options.values {
                guard case let .text(text) = value, !text.isEmpty, text.count <= 512,
                      !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw NativeRouteError("Invalid performance presentation text.")
                }
            }
        }
        return .init(manifest: manifest, pageContracts: [
            .init(entry: "overview", optionFields: [.init("program",kind:.text,required:false)], checkOptions: checkText),
            .init(entry: "memory", optionFields: [.init("inspect",kind:.text,required:false)], checkOptions: checkText)
        ], ui: .init(sidebarLocations:[.overview,.machine,.resources],hasBackdrop:true,compactPanelEntry:"overview"),
        resolveLegacyPage: { raw in
            guard ["overview","sensors","fans","memory","cpu","gpu"].contains(raw) else { return nil }
            return .init(manifest.id,raw)
        }, makeSession: { available in
            PerformanceSession(availability:available,telemetry:telemetry(),administration:administration(),
                               fanFactory:fanFactory(),defaults:defaults(),showSettings:showSettings)
        })
    }
}
