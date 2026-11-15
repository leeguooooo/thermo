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
        actionsAllowed: @escaping @MainActor @Sendable () -> Bool = { true },
        showSettings: @escaping @MainActor @Sendable () -> Void
    ) -> NativeFeatureDefinition {
        definition { available in
            PerformanceSession(availability:available,telemetry:telemetry(),administration:administration(),
                               fanFactory:fanFactory(),defaults:defaults(),showSettings:showSettings,actionsAllowed:actionsAllowed)
        }
    }
    static func definition(makeSession:@escaping @MainActor @Sendable (FeatureAvailability)->any NativeFeatureSession)->NativeFeatureDefinition {
        let manifest = BuiltinModuleManifests.performance
        return .init(manifest: manifest,runsInBackground:true, pageContracts: [
            .init(entry: "overview", optionFields: [.init("program",kind:.text,required:false)], checkOptions: {try checkText($0)}),
            .init(entry: "memory", optionFields: [.init("inspect",kind:.text,required:false)], checkOptions: {try checkText($0)})
        ], ui: .init(sidebarLocations:[.overview,.machine,.resources],hasBackdrop:true,compactPanelEntry:"overview"),
        resolveLegacyPage: { raw in
            guard ["overview","sensors","fans","memory","cpu","gpu"].contains(raw) else { return nil }
            return .init(manifest.id,raw)
        }, makeSession:makeSession)
    }
    private static func checkText(_ options: [String:NativeContextValue]) throws {
        for value in options.values {
            guard case let .text(text) = value, text.count <= 512,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw NativeRouteError("Invalid performance presentation text.")
            }
        }
    }

}
