import AgentCore
import AppKit
import SwiftUI
import ThermoL10n

/// Products from app.leeguoo.com. Opens apps or their web page; never downloads anything itself.
@MainActor
final class AppStoreModel: ObservableObject {
    @Published private(set) var apps: [StoreApp] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var usingCachedCopy = false
    private var lastLoad: Date?
    private let cache = StoreCache()
    private static let cacheName = "app-store.json"

    func open() {
        if let lastLoad, Date().timeIntervalSince(lastLoad) < 600 { return }
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        lastLoad = Date()
        let cache = cache
        Task {
            let fetched = await StoreFetch.data(AppStoreCatalog.url)
            if let fetched, let list = AppStoreCatalog.decode(fetched) {
                cache.write(fetched, as: Self.cacheName)
                apps = list
                usingCachedCopy = false
            } else {
                if apps.isEmpty { apps = cache.read(Self.cacheName).flatMap(AppStoreCatalog.decode) ?? [] }
                usingCachedCopy = !apps.isEmpty
            }
            loading = false
            loaded = true
        }
    }

    static func installedURL(_ app: StoreApp) -> URL? {
        app.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }
}

struct AppStorePage: View {
    @ObservedObject var model: AppStoreModel
    @Binding var tab: AppsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: tr("Software"), subtitle: tr("Store")) {
                Button(tr("Refresh")) { model.refresh() }
                    .buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize().disabled(model.loading)
            } below: {
                SoftwareTabPicker(tab: $tab)
            }
            .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pageTop).padding(.bottom, Theme.Space.l)
            content
        }
        .onAppear { model.open() }
    }

    @ViewBuilder var content: some View {
        if model.apps.isEmpty {
            if model.loaded {
                EmptyState(symbol: "bag", title: tr("The store is not available right now"),
                           detail: tr("Check the connection and refresh, or visit app.leeguoo.com."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NoticeBanner(text: tr("Loading the store…"), busy: true).padding(.horizontal, Theme.pagePadding)
                Spacer()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if model.usingCachedCopy { NoticeBanner(text: tr("Could not reach the store. Showing the last saved copy.")) }
                    InspectorPanel {
                        ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                            if index > 0 { Divider() }
                            row(app)
                        }
                    }
                }.padding(.horizontal, Theme.pagePadding).padding(.bottom, Theme.Space.l)
            }
        }
    }

    func description(_ app: StoreApp) -> String? {
        L10n.current == .simplifiedChinese ? app.descriptionZH ?? app.descriptionEN : app.descriptionEN ?? app.descriptionZH
    }

    /// The feed names categories in English; the common ones read in the app's language.
    static func category(_ name: String) -> String {
        switch name.lowercased() {
        case "collaboration": return tr("Collaboration")
        case "productivity": return tr("Productivity")
        case "tools": return tr("Tools")
        case "games": return tr("Games")
        case "learning": return tr("Learning")
        case "development": return tr("Development")
        case "monitoring": return tr("Monitoring")
        default: return name
        }
    }

    func row(_ app: StoreApp) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon = app.icon { Text(verbatim: icon).font(.system(size: 22)) }
                else { Image(systemName: "app").font(.system(size: 20)).foregroundStyle(Theme.textTertiary) }
            }.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: app.title).font(.system(size: 13, weight: .medium))
                    if let category = app.category { Text(verbatim: Self.category(category)).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                }
                if let text = description(app) {
                    Text(verbatim: text).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            if let installed = AppStoreModel.installedURL(app) {
                Button(tr("Open")) { NSWorkspace.shared.openApplication(at: installed, configuration: .init()) }
                    .buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small).fixedSize()
            } else {
                Button(tr("View page")) { NSWorkspace.shared.open(app.url) }
                    .buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
            }
        }.padding(12)
    }
}
