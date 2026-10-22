import AppKit
import Combine
import SearchCore
import ThermoL10n

@MainActor final class LocalSearchModel: ObservableObject {
    static let shared = LocalSearchModel()
    @Published var query = "" { didSet { if query != oldValue { submit() } } }
    @Published private(set) var response = SearchResponse(query: "", items: [])
    @Published private(set) var searching = false
    @Published private(set) var indexing = false
    @Published var selection: String?
    @Published var error: String?
    @Published var showSettings = false
    @Published var aliasTarget: SearchItem?
    @Published private(set) var preferences = SearchPreferences()
    var presentingDialog = false
    private(set) var store: SearchStore?
    private var indexer: SearchIndexer?
    private var queryTask: Task<Void, Never>?
    private var cancellation: SearchCancellation?
    private var generation: UInt64 = 0
    private var started = false
    private var appObservers: [NSObjectProtocol] = []
    private let executeQuery: (@Sendable (String, SearchCancellation) throws -> SearchResponse)?
    var selected: SearchItem? {
        guard response.query == query else { return nil }
        return response.items.first { $0.id == selection }
    }
    init(directory: URL = SearchStore.defaultDirectory, executeQuery: (@Sendable (String, SearchCancellation) throws -> SearchResponse)? = nil) {
        self.executeQuery = executeQuery
        do {
            let store = try SearchStore(directory: directory)
            self.store = store; preferences = try store.preferences()
        } catch { self.error = String(describing: error) }
    }
    func start() {
        guard !started, let store else { return }; started = true
        let indexer = SearchIndexer(store: store) { [weak self] busy, issue in
            Task { @MainActor in
                guard let self else { return }
                self.indexing = busy
                if let issue { self.error = issue }
                if !busy {
                    if let prefs = try? self.store?.preferences() { self.preferences = prefs }
                }
                self.submit()
            }
        }
        self.indexer = indexer; indexer.start()
        appObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.thermo.search.configurationChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let prefs = try? self.store?.preferences() else { return }
                self.preferences = prefs; self.indexer?.configure(prefs)
            }
        })
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            appObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.indexer?.refresh() }
            })
        }
    }
    func stop() {
        cancellation?.cancel(); queryTask?.cancel(); indexer?.stop()
        for observer in appObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer); DistributedNotificationCenter.default().removeObserver(observer) }
        appObservers.removeAll()
    }
    func refresh() { error = nil; indexer?.refresh() }
    func refreshApplications() { indexer?.refreshApplications() }
    func submit() {
        guard let store else { return }
        generation &+= 1
        let current = generation, term = query, oldSelection = selection
        cancellation?.cancel(); queryTask?.cancel()
        let token = SearchCancellation(); cancellation = token; searching = true
        queryTask = Task { [weak self] in
            do {
                if !term.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
                let executeQuery = self?.executeQuery
                let result = try await Task.detached(priority: .userInitiated) { try executeQuery?(term, token) ?? store.query(term, cancellation: token) }.value
                guard !Task.isCancelled, let self, current == self.generation else { return }
                self.response = result; self.searching = false
                self.selection = result.items.contains { $0.id == oldSelection } ? oldSelection : result.items.first?.id
            } catch is CancellationError { }
            catch {
                guard let self, current == self.generation else { return }
                self.error = String(describing: error); self.searching = false
            }
        }
    }
    func move(_ delta: Int) {
        guard response.query == query, !response.items.isEmpty else { return }
        let index = response.items.firstIndex { $0.id == selection } ?? 0
        selection = response.items[min(response.items.count - 1, max(0, index + delta))].id
    }
    func configure(_ preferences: SearchPreferences) {
        self.preferences = preferences; error = nil
        indexer?.configure(preferences)
    }
    func chooseFolder() {
        presentingDialog = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = tr("Add folders"); panel.message = tr("Choose folders to search by file name. File contents stay untouched.")
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }; self.presentingDialog = false
                guard response == .OK else { return }
                var next = self.preferences
                for url in panel.urls {
                    let path = SearchPaths.canonical(url.standardizedFileURL.path)
                    if !next.roots.contains(path) { next.roots.append(path) }
                }
                // Validate before changing the visible configuration; the writer repeats validation transactionally.
                for (i, root) in next.roots.enumerated() where next.roots.enumerated().contains(where: { j, other in j != i && SearchPaths.isWithin(root, root: other) }) {
                    self.error = tr("These search folders overlap. Keep the outer folder or choose separate folders.") + " " + root
                    return
                }
                self.configure(next)
            }
        }
    }
    func removeFolder(_ path: String) { var next = preferences; next.roots.removeAll { $0 == path }; configure(next) }
    func favorite(_ item: SearchItem) {
        do { try store?.setFavorite(!item.favorite, for: item.path); submit() } catch { self.error = String(describing: error) }
    }
    func saveAlias(_ alias: String, for item: SearchItem) {
        do { try store?.setAlias(alias, for: item.path); aliasTarget = nil; submit() } catch { self.error = String(describing: error) }
    }
    func clearHistory() { do { try store?.clearHistory(); submit() } catch { self.error = String(describing: error) } }
    func openSelected() { if let selected { open(selected) } }
    func open(_ item: SearchItem) {
        guard response.query == query, response.items.contains(where: { $0.id == item.id }) else { return }
        guard FileManager.default.fileExists(atPath: item.path) else { error = tr("This item is no longer available. Refresh the index."); return }
        let url = URL(fileURLWithPath: item.path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.error = error.localizedDescription; LocalSearchPanel.shared.show(); return }
                do { try self?.store?.recordOpen(item.path) } catch { self?.error = String(describing: error) }
            }
        }
        LocalSearchPanel.shared.hide(restoreFocus: false)
        if item.kind == .application { NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: completion) }
        else { NSWorkspace.shared.open(url, configuration: configuration, completionHandler: completion) }
    }
    func revealSelected() {
        guard let selected else { return }
        guard FileManager.default.fileExists(atPath: selected.path) else { error = tr("This item is no longer available. Refresh the index."); return }
        LocalSearchPanel.shared.hide(restoreFocus: false)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selected.path)])
    }
    func copySelectedPath() {
        guard let selected else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.path, forType: .string)
    }
}
