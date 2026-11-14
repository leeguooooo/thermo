import AppKit
import CaptureCore
import ModuleKit
import SwiftUI
import ThermoL10n

/// Trusted in-process capture: prewarmed shortcuts, existing capture/recording engines and saved pins.
enum CaptureModule: BuiltinModule {
    static let manifest = BuiltinModuleManifests.capture
    static let legacyMenuEntries: [String: String] = [:]
    @MainActor static var enabled: Bool { ModuleCenter.shared.isOn(manifest.id) }
    @MainActor static func start() { CaptureWorkspace.shared.activate() }
    static func owns(_ page: MainPage) -> Bool { false }
    static func canonicalArgument(_ argument: String) -> String { argument }
    static func target(_ scene: String) -> MainPage? { nil }
    static func supports(_ entry: ModuleManifest.Entry) -> Bool {
        switch (entry.kind, entry.scene) {
        case (.menuBarItem, "capture-menu"), (.settingsItem, "capture-saving"), (.settingsItem, "capture-shortcuts"): return true
        default: return false
        }
    }
    @MainActor static func sidebar(section: BuiltinSidebarSection, page: Binding<MainPage>, models: AppModels,
                                  row: @escaping @MainActor (BuiltinSidebarItem) -> AnyView) -> AnyView { AnyView(EmptyView()) }
    @MainActor static func page(_ entry: ModuleManifest.Entry, selection: Binding<MainPage>, models: AppModels) -> AnyView { AnyView(ModuleOffView()) }
    @MainActor static func settings(_ entry: ModuleManifest.Entry, models: AppModels) -> AnyView {
        AnyView(HStack(spacing: Theme.Space.m) {
            Image(systemName: entry.symbol ?? manifest.symbol).frame(width: 22).foregroundStyle(Theme.textSecondary)
            Text(tr(entry.title)).font(Theme.body)
            Spacer()
            Button(tr("Open")) {
                if entry.scene == "capture-saving" { CaptureWorkspace.shared.showSavingSettings() }
                else { CaptureWorkspace.shared.showActionSettings() }
            }.buttonStyle(PillButtonStyle()).controlSize(.small)
        }.padding(.horizontal, Theme.Space.m).padding(.vertical, 8))
    }
    @MainActor static func prepareStop(models: AppModels) throws -> BuiltinModules.FinishStop? {
        try CaptureWorkspace.shared.stopFeature()
        return nil
    }
    @MainActor static func appearance(_ page: MainPage) -> (glow: Bool, tint: Color?) { (false, nil) }
    @MainActor static func prepareReview(_ arguments: [String], page: inout MainPage, models: AppModels) {}
    @MainActor static func snapshotReady(_ arguments: [String], models: AppModels, started: Date) -> Bool { true }
}

/// The panel's capture menu. Its own view so `--render-preview` can draw it as a list for review
/// (a SwiftUI Menu cannot be rendered offscreen).
struct CaptureMenuItems: View {
    var body: some View {
                // Grouped like the status menu: everyday capture and pinning, recording, low-frequency tools one level down, then settings.
                Button {CaptureWorkspace.shared.capture()} label: { Label(tr("Capture screen…") + CaptureWorkspace.shared.shortcutSuffix(for:.screenshot), systemImage: "viewfinder") }
                Button {CaptureWorkspace.shared.pinClipboard()} label: { Label(tr("Pin clipboard") + CaptureWorkspace.shared.shortcutSuffix(for:.pinClipboard), systemImage: "pin") }
                Button {CaptureWorkspace.shared.importImage()} label: { Label(tr("Open image…"), systemImage: "photo") }
                Divider()
                Button {CaptureWorkspace.shared.recordScreen()} label: { Label(tr("Record screen…"), systemImage: "record.circle") }
                Button {CaptureWorkspace.shared.recordScreen(draftsOnly:true)} label: { Label(tr("Recording drafts…"), systemImage: "film.stack") }
                Divider()
                Menu {
                    Button {CaptureWorkspace.shared.captureScrolling()} label: { Label(tr("Scrolling capture…"), systemImage: "arrow.down.right.and.arrow.up.left") }
                    Button {CaptureWorkspace.shared.pinClipboard(asText:true)} label: { Label(tr("Pin clipboard as text"), systemImage: "text.quote") }
                    Button {CaptureWorkspace.shared.pinClipboard(asLaTeX:true)} label: { Label(tr("Pin clipboard as LaTeX"), systemImage: "function") }
                    CaptureConfiguredActionsMenu(model:CaptureWorkspace.shared.shortcuts)
                    Divider()
                    Button {CaptureWorkspace.shared.showPinLibrary()} label: { Label(tr("Pin groups and history"), systemImage: "square.stack") }
                    Button {CaptureWorkspace.shared.restoreLastPin()} label: { Label(tr("Restore last closed pin"), systemImage: "arrow.uturn.backward") }
                    Button {CaptureWorkspace.shared.pinSession.restoreMouseInteraction()} label: { Label(tr("Restore pin mouse interaction"), systemImage: "cursorarrow") }
                    Button {CaptureWorkspace.shared.showAll()} label: { Label(tr("Show all pins"), systemImage: "eye") }
                    Button {CaptureWorkspace.shared.hideAll()} label: { Label(tr("Hide all pins"), systemImage: "eye.slash") }
                    Button {CaptureWorkspace.shared.closeAll()} label: { Label(tr("Close all pins"), systemImage: "xmark.circle") }
                } label: { Label(tr("More capture tools"), systemImage: "ellipsis.circle") }
                Divider()
                Button {CaptureWorkspace.shared.showSavingSettings()} label: { Label(tr("Capture saving and after-actions"), systemImage: "square.and.arrow.down") }
                Button {CaptureWorkspace.shared.showActionSettings()} label: { Label(tr("Capture shortcuts and actions"), systemImage: "keyboard") }
    }
}
