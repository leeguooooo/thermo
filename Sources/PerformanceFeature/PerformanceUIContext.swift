import CleanKit
import Foundation
import ModuleKit
import NativeFeatureAPI
import SwiftUI

enum PerformanceDestination: Sendable {
    case overview, sensors, fans, memory, compute(Bool), storage, settings
    case native(NativeFeatureRoute), inspectMemory(String)
}

/// Private UI callbacks to this session's operation owner, never an external command interface.
struct PerformanceOperations: Sendable {
    let begin: @MainActor @Sendable () -> UUID?
    let end: @MainActor @Sendable (UUID) -> Void
    static let unavailable = PerformanceOperations(begin: { nil }, end: { _ in })
}
struct PerformanceNavigation: Sendable {
    let native: NativeNavigation
    let available: @MainActor @Sendable () -> Bool
    let showSettings: @MainActor @Sendable () -> Void
    static let unavailable = PerformanceNavigation(native: .unavailable, available: { false }, showSettings: {})
    private var disk: NativeFeatureRoute { .init(BuiltinModuleManifests.disk.id,"scan") }
    @MainActor var canOpenStorage: Bool { available() && native.canAdmit(disk) }
    @MainActor func open(_ destination: PerformanceDestination) {
        guard available() else { return }
        let performance = BuiltinModuleManifests.performance.id
        let route: NativeFeatureRoute
        switch destination {
        case .overview: route = .init(performance,"overview")
        case .sensors: route = .init(performance,"sensors")
        case .fans: route = .init(performance,"fans")
        case .memory: route = .init(performance,"memory")
        case let .compute(gpu): route = .init(performance,gpu ? "gpu":"cpu")
        case .storage: route = canOpenStorage ? disk:.init(BuiltinModuleManifests.space.id,"browse")
        case .settings: showSettings(); return
        case let .native(value): route = value
        case let .inspectMemory(name):
            _ = native.show(.init(route:.init(performance,"memory"),options:["inspect":.text(name)])); return
        }
        _ = native.show(route)
    }
    @MainActor func showBrowser(_ hog: MachinePulse.Hog) {
        guard available() else { return }
        var options: [String:NativeContextValue] = ["appMemoryKB":.integer(Int64(hog.memoryKB))]
        if let gpu = hog.parts?.first(where:{$0.role=="GPU"})?.memoryKB { options["gpuMemoryKB"] = .integer(Int64(gpu)) }
        _ = native.show(.init(route:.init(BuiltinModuleManifests.browser.id,"home",context:["app":.text(hog.name)]),options:options))
    }
}
private enum PerformanceOperationsKey: EnvironmentKey { static let defaultValue = PerformanceOperations.unavailable }
private enum PerformanceNavigationKey: EnvironmentKey { static let defaultValue = PerformanceNavigation.unavailable }
extension EnvironmentValues {
    var performanceOperations: PerformanceOperations { get { self[PerformanceOperationsKey.self] } set { self[PerformanceOperationsKey.self] = newValue } }
    var performanceNavigation: PerformanceNavigation { get { self[PerformanceNavigationKey.self] } set { self[PerformanceNavigationKey.self] = newValue } }
}
