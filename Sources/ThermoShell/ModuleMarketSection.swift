import AgentCore
import CleanKit
import Foundation
import ModuleKernelCore
import ModuleKit
import SwiftUI
import ThermoL10n
import ThermoUI

/// Third-party WebAssembly modules from the module registry (#49). Reads when the section appears;
/// installs, updates and uninstalls only from a click, after the declared access was shown.
@MainActor final class ModuleMarketModel: ObservableObject {
    static let registryURL = URL(string: "https://raw.githubusercontent.com/leeguooooo/thermo-modules/main/registry.json")!
    @Published private(set) var listings: [ModuleRegistry.Listing] = []
    @Published private(set) var installed: [ModuleMarketStore.Installed] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var usingCachedCopy = false
    @Published private(set) var working: String?
    @Published var message: String?
    let store: ModuleMarketStore
    private let center: ModuleCenter
    private let fetch: @Sendable (URL) async -> Data?
    private let cache: StoreCache
    private let trash: @Sendable (String, URL) throws -> Void
    var supported: Bool {
        guard #available(macOS 15, *) else { return false }
        return ModuleKernel.wasmRunner != nil
    }
    var hasSigningKey: Bool { !store.keys.isEmpty }

    init(center: ModuleCenter, store: ModuleMarketStore = .init(root: ModuleMarketStore.defaultRoot(), keys: ModuleSigningKeys.production),
         cache: StoreCache = StoreCache(), fetch: @escaping @Sendable (URL) async -> Data? = ModuleMarketModel.download,
         trash: @escaping @Sendable (String, URL) throws -> Void = ModuleMarketModel.moveToTrash) {
        self.center = center; self.store = store; self.cache = cache; self.fetch = fetch; self.trash = trash
        reloadInstalled()
    }

    private static var instance: ModuleMarketModel?
    /// One model per app run, so the listing and a running install survive leaving the page.
    static func shared(_ center: ModuleCenter) -> ModuleMarketModel {
        if let instance { return instance }
        let made = ModuleMarketModel(center: center); instance = made; return made
    }

    func reloadInstalled() {
        installed = store.installed()
        center.reloadMarketModules(installed.map(\.manifest))
    }

    func refresh() {
        guard !loading, working == nil else { return }
        loading = true
        Task { [self] in
            let data = await fetch(Self.registryURL)
            if let data, let registry = ModuleRegistry.decode(data) {
                cache.write(data, as: "module-registry.json"); listings = registry.modules; usingCachedCopy = false
            } else if listings.isEmpty, let cached = cache.read("module-registry.json").flatMap(ModuleRegistry.decode) {
                listings = cached.modules; usingCachedCopy = true
            }
            loading = false; loaded = true
        }
    }

    func version(of id: String) -> String? { installed.first { $0.id == id }?.manifest.version }
    func canUpdate(_ listing: ModuleRegistry.Listing) -> Bool { version(of: listing.id).map { ModuleVersion.isNewer(listing.version, than: $0) } ?? false }

    /// Downloads, checks the hash and signature, and installs. Nothing is written when a check fails.
    func install(_ listing: ModuleRegistry.Listing) {
        guard working == nil, supported else { return }
        working = listing.name; message = nil
        Task { [self] in
            defer { working = nil }
            guard let data = await fetch(listing.url) else { message = tr("Could not download %1$@.", listing.name); return }
            do {
                let store = store
                _ = try await Task.detached { try store.install(data, listing: listing) }.value
                reloadInstalled()
                message = tr("%1$@ %2$@ is installed. Switch it on above to use it.", listing.name, listing.version)
            } catch {
                message = tr("%1$@ was not installed: %2$@", listing.name, String(describing: error))
            }
        }
    }

    func uninstall(_ id: String) {
        guard working == nil, let module = installed.first(where: { $0.id == id }) else { return }
        if center.isOn(id) { center.setEnabled(id, false) }
        do {
            try store.uninstall(id) { folder in try trash(id, folder) }
            reloadInstalled()
            message = tr("%1$@ was moved to the Trash. Undo it from operation history.", module.manifest.name)
        } catch { message = String(describing: error) }
    }

    /// HTTPS only, final URL included, and never more than a package may be.
    nonisolated static func download(_ url: URL) async -> Data? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 120; configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url), let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme?.lowercased() == "https", data.count <= ModulePackage.maxPackageBytes else { return nil }
        return data
    }

    /// The package folder goes to the Trash as one undoable batch in operation history.
    nonisolated static func moveToTrash(_ id: String, _ folder: URL) throws {
        let home = NSHomeDirectory(), batch = UUID().uuidString
        var destination: NSURL?
        try FileManager.default.trashItem(at: folder, resultingItemURL: &destination)
        var detail: String?, recorded = false
        if let destination = destination as URL? {
            do { try TrashBatches.recordMoved(original: folder.path, destination: destination.path, id: batch, home: home); recorded = true }
            catch { detail = "Moved to Trash, but undo recording failed: " + error.localizedDescription }
        }
        OperationJournal.record(OperationRecord(feature: "modules", action: "uninstall", subject: id,
            items: [.init(target: folder.path, status: detail == nil ? "done" : "partial", detail: detail)],
            undo: recorded ? .init(kind: "trashBatch", ref: batch) : nil), home: home)
    }
}

struct ModuleMarketSection: View {
    @ObservedObject var model: ModuleMarketModel
    @State private var reviewing: ModuleRegistry.Listing?
    @State private var removing: ModuleMarketStore.Installed?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(tr("Module market")).font(Theme.heading)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button(tr("Refresh")) { model.refresh() }.buttonStyle(PillButtonStyle()).controlSize(.small)
                    .disabled(model.loading || model.working != nil)
            }
            Text(tr("Third-party modules run in a sandbox and can only use the access they declare. Thermo installs only packages signed by its module pipeline."))
                .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            if !model.supported { NoticeBanner(text: tr("Third-party modules need macOS 15 or later.")) }
            if !model.hasSigningKey { NoticeBanner(text: tr("This build has no module signing key, so no module can be installed yet.")) }
            if let message = model.message { NoticeBanner(text: message, dismiss: { model.message = nil }) }
            if let working = model.working { NoticeBanner(text: tr("Working on %1$@…", working), busy: true) }
            if model.usingCachedCopy { NoticeBanner(text: tr("Could not reach the module registry. Showing the last saved copy.")) }
            if model.listings.isEmpty && model.installed.isEmpty {
                Text(model.loaded ? tr("No modules are listed right now.") : tr("Loading the module registry…"))
                    .font(Theme.secondary).foregroundStyle(Theme.textTertiary)
            }
            VStack(spacing: 0) {
                ForEach(Array(model.listings.enumerated()), id: \.element.id) { index, listing in
                    if index > 0 { InspectorDivider(inset: 46) }
                    row(listing)
                }
                ForEach(model.installed.filter { item in !model.listings.contains { $0.id == item.id } }) { item in
                    InspectorDivider(inset: 46)
                    installedOnly(item)
                }
            }.glass(radius: Theme.radius)
        }
        .onAppear { if !model.loaded { model.refresh() } }
        .sheet(item: $reviewing) { listing in
            ModuleInstallReview(listing: listing, update: model.version(of: listing.id) != nil) { go in
                reviewing = nil
                if go { model.install(listing) }
            }
        }
        .confirmationDialog(tr("Uninstall %1$@?", removing?.manifest.name ?? ""), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { item in
            Button(tr("Uninstall"), role: .destructive) { model.uninstall(item.id) }
            Button(tr("Cancel"), role: .cancel) {}
        } message: { _ in Text(tr("The module is switched off and moved to the Trash. You can put it back from operation history.")) }
    }

    func row(_ listing: ModuleRegistry.Listing) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: listing.symbol ?? "puzzlepiece.extension").frame(width: 22).foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: listing.name).font(Theme.body)
                    Text(verbatim: listing.version).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(listing.size), countStyle: .file)).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                Text(verbatim: listing.summary).font(Theme.secondary).foregroundStyle(Theme.textSecondary).lineLimit(3)
                Text(listing.capabilities.isEmpty ? tr("No access to the Mac declared.") : listing.capabilities.map { ModuleCapabilityText.title($0.kind) + ($0.scope.map { " · " + $0 } ?? "") }.joined(separator: ", "))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                if let have = model.version(of: listing.id) {
                    Text(model.canUpdate(listing) ? tr("Update available: %1$@ → %2$@", have, listing.version) : tr("Installed %1$@", have))
                        .font(Theme.caption).foregroundStyle(model.canUpdate(listing) ? .orange : .green)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                if model.version(of: listing.id) == nil {
                    Button(tr("Install…")) { reviewing = listing }.buttonStyle(PillButtonStyle()).controlSize(.small)
                        .disabled(!model.supported || !model.hasSigningKey)
                } else {
                    if model.canUpdate(listing) {
                        Button(tr("Update…")) { reviewing = listing }.buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small)
                    }
                    if let item = model.installed.first(where: { $0.id == listing.id }) {
                        Button(tr("Uninstall")) { removing = item }.buttonStyle(PillButtonStyle()).controlSize(.small)
                    }
                }
            }.disabled(model.working != nil)
            .accessibilityIdentifier("module-market-actions-" + listing.id)
        }.padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
    }

    func installedOnly(_ item: ModuleMarketStore.Installed) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: item.manifest.symbol).frame(width: 22).foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.manifest.name).font(Theme.body)
                Text(tr("Installed %1$@ · no longer listed", item.manifest.version)).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button(tr("Uninstall")) { removing = item }.buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.working != nil)
        }.padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
    }
}

/// What the module will be allowed to do, shown before anything is downloaded. The same list is
/// checked against the signed package, so a listing can't show less than the module gets.
struct ModuleInstallReview: View {
    let listing: ModuleRegistry.Listing
    let update: Bool
    let done: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(update ? tr("Update %1$@ to %2$@?", listing.name, listing.version) : tr("Install %1$@?", listing.name)).font(Theme.heading)
            Text(verbatim: listing.summary).foregroundStyle(Theme.textSecondary)
            Text(tr("It may ask Thermo to:")).font(Theme.body.weight(.semibold))
            if listing.capabilities.isEmpty { Text(tr("No access to the Mac declared.")).foregroundStyle(Theme.textSecondary) }
            ForEach(Array(listing.capabilities.enumerated()), id: \.offset) { _, capability in
                HStack(alignment: .top) {
                    Text(ModuleCapabilityText.title(capability.kind))
                    if let scope = capability.scope { Text(verbatim: scope).font(Theme.mono).foregroundStyle(Theme.textSecondary) }
                    Spacer()
                    if capability.kind.alwaysConfirmed { Text(tr("Confirmation required")).font(Theme.caption).foregroundStyle(Theme.caution) }
                }
            }
            Text(tr("Thermo checks the download against the registry and the pipeline signature before installing. The module stays off until you switch it on."))
                .font(Theme.secondary).foregroundStyle(Theme.textTertiary)
            HStack {
                Spacer()
                Button(tr("Cancel"), role: .cancel) { done(false) }.keyboardShortcut(.cancelAction)
                Button(update ? tr("Update") : tr("Install")) { done(true) }.keyboardShortcut(.defaultAction)
            }
        }.padding(Theme.Space.l).frame(width: 440)
    }
}
