import AppKit
import CleanKit
import ModuleKit
import SwiftUI
import ThermoL10n

/// The disk feature owns rendering and dynamic findings; the host reads entry names/routes from its manifest.
enum DiskModule: BuiltinModule {
    static let manifest = BuiltinModuleManifests.disk
    static let legacyMenuEntries = ["smartScan": "scan"]
    static func owns(_ page: MainPage) -> Bool {
        if case let .module(id, _) = page { return id == manifest.id }
        return false
    }
    static func canonicalArgument(_ argument: String) -> String {
        argument == "disk:home" ? "disk" : argument
    }
    static func target(_ scene: String) -> MainPage? {
        guard let entry = manifest.entries.first(where: { $0.kind == .page && $0.scene == scene }) else { return nil }
        return .module(manifest.id, entry.id)
    }
    static func route(_ sub: DiskPage) -> MainPage? {
        let scene: String
        switch sub {
        case .home: scene = "disk"
        case .overview: scene = "disk:overview"
        case let .category(value): scene = "disk:" + value.rawValue
        }
        return target(scene)
    }
    static func subpage(_ scene: String) -> DiskPage? {
        if scene == "disk" { return .home }
        guard scene.hasPrefix("disk:") else { return nil }
        return DiskPage(argument: String(scene.dropFirst(5)))
    }
    static func supports(_ entry: ModuleManifest.Entry) -> Bool {
        switch entry.kind {
        case .page: return entry.scene.flatMap(subpage) != nil
        case .settingsItem: return entry.scene == "disk-protection"
        default: return false
        }
    }
    static func normalized(_ page: MainPage) -> MainPage? { BuiltinModules.page(page)?.target }
    @MainActor static func sidebarItems(selection: MainPage, disk: DiskModel) -> [BuiltinSidebarItem] {
        let selected = normalized(selection)
        return manifest.entries.compactMap { entry in
            guard entry.kind == .page, let scene = entry.scene, let page = target(scene), let sub = subpage(scene) else { return nil }
            if entry.parent != nil && !owns(selection) { return nil }
            var tint = Color.pink, trailing: String?
            switch sub {
            case .home: trailing = disk.report.map { ByteFormat.string($0.totalBytes) }
            case .overview: tint = .teal
            case let .category(category):
                let bytes = disk.report?.bytes(in: category) ?? 0
                guard category == .aiSessions || bytes > 0 || (disk.report?.items ?? []).contains(where: { $0.category == category }) else { return nil }
                tint = DiskStyle.tint(category)
                trailing = category == .aiSessions && disk.sessionRetentionDays == nil ? nil : ByteFormat.string(bytes)
            }
            return .init(entry: entry, target: page, tint: tint, trailing: trailing, selected: selected == page)
        }
    }
    @MainActor static func sidebar(page: Binding<MainPage>, models: AppModels,
                                   row: @escaping @MainActor (BuiltinSidebarItem) -> AnyView) -> AnyView {
        AnyView(DiskSidebarRows(disk: models.disk) { disk in
            ForEach(sidebarItems(selection: page.wrappedValue, disk: disk)) { item in row(item) }
        })
    }
    @MainActor static func page(_ entry: ModuleManifest.Entry, selection: Binding<MainPage>, models: AppModels) -> AnyView {
        guard let scene = entry.scene, let sub = subpage(scene) else { return AnyView(ModuleOffView()) }
        return AnyView(DiskPages(page: selection, sub: sub, disk: models.disk))
    }
    @MainActor static func settings(_ entry: ModuleManifest.Entry, models: AppModels) -> AnyView {
        guard supports(entry), entry.kind == .settingsItem else { return AnyView(EmptyView()) }
        return AnyView(CleanupProtectionsButton(disk: models.disk, asRow: true, title: tr(entry.title), symbol: entry.symbol ?? manifest.symbol))
    }
    @MainActor static func prepareStop(models: AppModels) throws -> BuiltinModules.FinishStop? { try models.prepareDiskStop() }
    @MainActor static func appearance(_ page: MainPage) -> (glow: Bool, tint: Color?) {
        (normalized(page) == route(.home), Color(red: 0.36, green: 0.42, blue: 1.0))
    }
    @MainActor static func prepareReview(_ arguments: [String], page: inout MainPage, models: AppModels) {
        guard arguments.contains("--disk") else { return }
        let index = arguments.firstIndex(of: "--page")
        let raw = index.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        page = raw.flatMap { BuiltinModules.argument("disk:" + $0) } ?? target("disk") ?? .overview
        guard ModuleCenter.shared.shows(page) else { return }
        if arguments.contains("--all") { models.disk.scope = .all }
        if !arguments.contains("--no-scan") {
            let category: CleanCategory?
            if let entry = BuiltinModules.page(page)?.entry, let scene = entry.scene, case let .category(value)? = subpage(scene) { category = value } else { category = nil }
            models.disk.loadSaved(category: category, scanIfMissing: true)
        }
    }
    @MainActor static func snapshotReady(_ arguments: [String], models: AppModels) -> Bool {
        let model = models.disk
        if arguments.contains("--no-scan") || !arguments.contains("--disk") { return !model.loadingSaved && !model.scanning }
        return !model.loadingSaved && model.report != nil && !model.scanning
    }
}

struct DiskPages: View {
    @Binding var page: MainPage
    let sub: DiskPage
    @ObservedObject var disk: DiskModel
    @State private var cleanReview: DiskCleanupReview?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var cleanupCategory: CleanCategory? {
        if case let .category(category) = sub { return category }
        return nil
    }

    var cleanupNoticeNeeded: Bool {
        switch sub {
        case .home, .category:
            return disk.scopeNeedsRefresh(category: cleanupCategory) || disk.resultsNeedRefresh || disk.languageStale
        default: return false
        }
    }

    func startClean() { if cleanReview == nil { cleanReview = disk.cleanupReview() } }
    func load() { if disk.report == nil, !disk.scanning { disk.loadSaved(category: cleanupCategory) } }

    var body: some View {
        VStack(spacing: 0) {
            if let error = disk.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.body).foregroundStyle(Theme.caution).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14).glass(radius: 12)
                    .padding(.horizontal, 32).padding(.top, 12)
            }
            if cleanupNoticeNeeded {
                HStack {
                    Text(disk.resultsNeedRefresh ? tr("Some paths could not be removed. Scan again to refresh the remaining items.") : disk.languageStale ? tr("Scan again to refresh results in the selected language.") : tr("Scan scope changed. Scan again to update these results.")).font(Theme.body)
                    Spacer()
                    Button(tr("Scan again")) { disk.scan(category: cleanupCategory) }.disabled(disk.scanning || disk.cleaning)
                }
                .padding(14).glass(radius: 12).padding(.horizontal, 32).padding(.top, 12)
            }
            ZStack { content }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Theme.standard.unlessReduced(reduceMotion), value: sub)
        }
        .onChange(of: sub) { _ in load() }
        .onAppear { load() }
        .sheet(item: $cleanReview) { review in
            DiskCleanConfirmation(review: review,
                                  confirm: { cleanReview = nil; disk.clean(review: review) }, cancel: { cleanReview = nil })
        }
    }

    @ViewBuilder var content: some View {
        switch sub {
        case .home:
            DiskHome(model: disk, open: { if let target = DiskModule.route(.category($0)) { page = target } }, clean: startClean).transition(.page)
        case .overview:
            DiskOverviewView(openCleanup: { category in
                SpaceOverviewModel.shared.stop()
                if !disk.scanning && !disk.cleaning { disk.scan(category: category) }
                if let target = DiskModule.route(category.map(DiskPage.category) ?? .home) { page = target }
            }, cleanupDisabled: disk.scanning || disk.cleaning, openInSpaceLens: { path in
                SpaceOverviewModel.shared.stop()
                SpaceLensModel.shared.reveal(path)
                page = .space(.browse)
            }).transition(.page)
        case let .category(c):
            DiskCategoryPage(model: disk, category: c, clean: startClean, cleanOne: { item in if cleanReview == nil { cleanReview = disk.cleanupReview(of: item) } }).id(c)
                .transition(.page)
        }
    }
}

/// The sidebar's disk cleanup rows redraw with the scan; the rest of the sidebar does not hold the model.
private struct DiskSidebarRows<Content: View>: View {
    @ObservedObject var disk: DiskModel
    @ViewBuilder let content: @MainActor (DiskModel) -> Content
    var body: some View { content(disk) }
}



extension MainPage {
    var isDisk: Bool { DiskModule.owns(self) }
}
