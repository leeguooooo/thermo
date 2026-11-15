import ThermoUI
import AppKit
import ModuleKit
import SwiftUI
import ThermoKit
import ThermoL10n

/// Native performance pages share existing demand-driven readers and the kernel's fan helper.
enum PerformanceModule: BuiltinModule {
    static let manifest = BuiltinModuleManifests.performance
    static let legacyMenuEntries: [String: String] = [:]
    static let sidebarSections: Set<BuiltinSidebarSection> = [.overview, .machine, .resources]
    @MainActor static var enabled: Bool { ModuleCenter.shared.isOn(manifest.id) }
    @MainActor private static var retiring = false
    @MainActor private static var operations = Set<UUID>()
    @MainActor static func beginOperation() -> UUID? {
        guard enabled, !retiring else { return nil }
        let id = UUID(); operations.insert(id); return id
    }
    @MainActor static func endOperation(_ id: UUID) { operations.remove(id) }
    @MainActor static func start() {
        guard enabled else { return }
        retiring = false
        AppModels.shared.monitor.startFeature()
        PulseRecorder.shared.start()
        if AppModels.shared.monitor.popoverOpen { PanelModel.shared.setActive(true) }
    }
    static func owns(_ page: MainPage) -> Bool {
        switch page {
        case .overview, .sensors, .fans, .memory, .compute: return true
        case let .module(id, _): return id == manifest.id
        default: return false
        }
    }
    static func canonicalArgument(_ argument: String) -> String { argument }
    static func target(_ scene: String) -> MainPage? {
        switch scene {
        case "overview": return .overview
        case "sensors": return .sensors
        case "fans": return .fans
        case "memory": return .memory
        case "cpu": return .compute(false)
        case "gpu": return .compute(true)
        default: return nil
        }
    }
    static func supports(_ entry: ModuleManifest.Entry) -> Bool { entry.kind == .page && entry.scene.flatMap(target) != nil }
    static func section(_ entry: ModuleManifest.Entry) -> BuiltinSidebarSection? {
        switch entry.id {
        case "overview": return .overview
        case "sensors", "fans": return .machine
        case "cpu", "gpu", "memory": return .resources
        default: return nil
        }
    }
    @MainActor static func sidebar(section: BuiltinSidebarSection, page: Binding<MainPage>, models: AppModels,
                                  row: @escaping @MainActor (BuiltinSidebarItem) -> AnyView) -> AnyView {
        AnyView(PerformanceSidebarRows(section: section, selection: page.wrappedValue, monitor: models.monitor, row: row))
    }
    @MainActor static func page(_ entry: ModuleManifest.Entry, selection: Binding<MainPage>, models: AppModels) -> AnyView {
        switch entry.scene.flatMap(target) {
        case .overview?: return AnyView(OverviewPage(monitor: models.monitor, open: { selection.wrappedValue = $0 }))
        case .sensors?: return AnyView(SensorsPage(monitor: models.monitor))
        case .fans?: return AnyView(WindowPage(title: tr("Fans"), subtitle: tr("Choose how fast each fan runs. Settings stay when Thermo quits or updates.")) { FansView(monitor: models.monitor) })
        case .memory?: return AnyView(MemoryPage(model: .shared, open: { selection.wrappedValue = $0 }))
        case let .compute(gpu)?: return AnyView(ComputePage(gpu: gpu).id(gpu))
        default: return AnyView(ModuleOffView())
        }
    }
    @MainActor static func settings(_ entry: ModuleManifest.Entry, models: AppModels) -> AnyView { AnyView(EmptyView()) }
    @MainActor static func prepareStop(models: AppModels) throws -> BuiltinModules.FinishStop? {
        guard models.monitor.canStopFeature, operations.isEmpty, SystemPulse.shared.quitting.isEmpty,
              SystemPulse.shared.restarting == nil, MemoryReliefAdvice.shared.phase != .asking else {
            throw BuiltinModules.StopRefused(description: tr("Wait for fan setup, memory relief or the current process action before switching this feature off."))
        }
        retiring = true
        models.monitor.beginStoppingFeature()
        PulseRecorder.shared.beginStopping()
        PanelModel.shared.setActive(false)
        SystemPulse.shared.stop()
        ComputeModel.cpu.stop(); ComputeModel.shared.stop(); MemoryModel.shared.stop()
        return {
            await models.monitor.finishStoppingFeature()
            await PulseRecorder.shared.stop()
            await SystemPulse.shared.finishStoppingFeature()
            while ComputeModel.cpu.sampleInFlight || ComputeModel.shared.sampleInFlight || MemoryModel.shared.sampleInFlight || PanelModel.shared.sampleInFlight {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            ComputeModel.cpu.releaseReadingsIfIdle(); ComputeModel.shared.releaseReadingsIfIdle(); MemoryModel.shared.releaseReadingsIfIdle()
            models.monitor.onMenuUpdate?()
            retiring = false
        }
    }
    @MainActor static func appearance(_ page: MainPage) -> (glow: Bool, tint: Color?) {
        (BuiltinModules.page(page)?.target == .overview, nil)
    }
    @MainActor static func prepareReview(_ arguments: [String], page: inout MainPage, models: AppModels) {}
    @MainActor static func snapshotReady(_ arguments: [String], models: AppModels, started: Date) -> Bool {
        let raw = arguments.firstIndex(of: "--page").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "overview"
        let page = MainPage(argument: raw).flatMap { BuiltinModules.page($0)?.target }
        switch page {
        case let .compute(gpu)?: return (gpu ? ComputeModel.shared : .cpu).current?.cpu != nil && Date().timeIntervalSince(started) > 4
        case .memory?: return MemoryModel.shared.breakdown != nil && Date().timeIntervalSince(started) > 4
        case .overview?: return models.monitor.snapshot != nil && SystemPulse.shared.sampled && PulseRecorder.shared.diagnosis != nil && Date().timeIntervalSince(started) > 4
        default: return models.monitor.snapshot != nil
        }
    }
}

private struct PerformanceSidebarRows: View {
    let section: BuiltinSidebarSection
    let selection: MainPage
    @ObservedObject var monitor: Monitor
    let row: @MainActor (BuiltinSidebarItem) -> AnyView
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false
    var body: some View {
        ForEach(PerformanceModule.manifest.entries.filter { PerformanceModule.section($0) == section }, id: \.id) { entry in
            if let target = entry.scene.flatMap(PerformanceModule.target) {
                let selected = (BuiltinModules.page(selection)?.target ?? selection) == target
                let color = entry.id == "overview" ? monitor.snapshot.map { heatColor($0.maximumKnownTemperature) } : nil
                row(.init(entry: entry, target: target, tint: tint(entry.id), trailing: trailing(entry.id), trailingColor: color, selected: selected))
            }
        }
    }
    func tint(_ id: String) -> Color {
        switch id {
        case "overview": return .orange
        case "sensors": return .red
        case "fans": return .blue
        case "cpu": return .cyan
        case "gpu": return .purple
        default: return .green
        }
    }
    func trailing(_ id: String) -> String? {
        switch id {
        case "overview": return monitor.snapshot.map { tempText($0.maximumKnownTemperature, fahrenheit: fahrenheit) }
        case "fans": return monitor.snapshot.flatMap { FanControlPresentation.speedSummary($0.fans, stopped: monitor.stoppedFans) }
        case "memory":
            guard monitor.snapshot != nil, let memory = SystemStats.memory() else { return nil }
            return String(format: "%.0f%%", Double(memory.usedBytes) / Double(max(1, memory.totalBytes)) * 100)
        default: return nil
        }
    }
}
