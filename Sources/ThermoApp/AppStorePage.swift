import ThermoUI
import NativeFeatureAPI
import AgentCore
import AppKit
import SwiftUI
import ThermoL10n

/// Products from app.leeguoo.com. Opens apps or their web page; never downloads anything itself.
@MainActor
final class AppStoreModel: ObservableObject {
    let work = FeatureTasks()
    private var generation = UUID()
    private let fetch: @Sendable () async -> Data?
    @Published private(set) var apps: [StoreApp] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var usingCachedCopy = false
    private var lastLoad: Date?
    private let cache: StoreCache
    private static let cacheName = "app-store.json"

    init(cache: StoreCache = StoreCache(), fetch: @escaping @Sendable () async -> Data? = { await StoreFetch.data(AppStoreCatalog.url) }) {
        self.cache=cache;self.fetch=fetch
    }
    func open() {
        guard work.acceptsWork else { return }
        if let lastLoad, Date().timeIntervalSince(lastLoad) < 600 { return }
        refresh()
    }

    func refresh() {
        guard work.acceptsWork else { return }
        guard !loading else { return }
        loading = true
        lastLoad = Date()
        let cache = cache, fetch = fetch, token = generation
        work.run { [weak self] in
            let fetched = await fetch()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,self.work.acceptsWork,self.generation == token else { return }
                if let fetched,let list=AppStoreCatalog.decode(fetched) {
                    cache.write(fetched,as:Self.cacheName);self.apps=list;self.usingCachedCopy=false
                } else {
                    if self.apps.isEmpty {self.apps=cache.read(Self.cacheName).flatMap(AppStoreCatalog.decode) ?? []}
                    self.usingCachedCopy = !self.apps.isEmpty
                }
                self.loading=false;self.loaded=true
            }
        }
    }
    func stopFeature() {work.stop();generation=UUID();loading=false}
    func finishFeatureStop() async {
        await work.finish();apps=[];lastLoad=nil;loaded=false;usingCachedCopy=false
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
                // No emoji in the catalog: a monogram tile. A bare "app" outline read as an unticked checkbox.
                else {
                    Text(verbatim: String(app.title.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent.gradient))
                }
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
            if app.bundleID != nil, app.bundleID == Bundle.main.bundleIdentifier {
                StatusTag(text: tr("In use"), color: Theme.good)
            } else if let installed = AppStoreModel.installedURL(app) {
                Button(tr("Open")) { NSWorkspace.shared.openApplication(at: installed, configuration: .init()) }
                    .buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small).fixedSize()
            } else {
                Button(tr("View page")) { NSWorkspace.shared.open(app.url) }
                    .buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
            }
        }.padding(12)
    }
}
