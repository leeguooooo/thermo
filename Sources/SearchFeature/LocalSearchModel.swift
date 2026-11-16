import AppKit
import Combine
import SearchCore
import ModuleKit
import NativeFeatureAPI
import ThermoL10n
import UniformTypeIdentifiers

@MainActor final class LocalSearchModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { error = nil; submit() } } }
    @Published private(set) var response = SearchResponse(query: "", items: [])
    @Published private(set) var searching = false
    @Published private(set) var indexing = false
    @Published private(set) var directPath: String?
    @Published private(set) var featureChoices:[FeatureDiscoveryItem]=[]
    @Published var featureReview:FeatureDiscoveryItem?
    @Published private(set) var featureNotice:String?
    var discovery:any FeatureDiscoveryAccess=UnavailableFeatureDiscovery()
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
    private var suspended = false
    private var lifecycle = UUID()
    private let directory: URL
    weak var panel:LocalSearchPanel?
    private let acceptsWork:()->Bool
    private let module: ModuleManifest?
    private let defaults: UserDefaults
    private var featureOn: Bool { acceptsWork() && (module.map { ModulePreferences.isEnabled($0, in: defaults) } ?? true) }
    private var queries: [UUID: Task<Void, Never>] = [:]
    private var retiringIndexers: [SearchIndexer] = []
    private var appObservers: [NSObjectProtocol] = []
    typealias OpenCompletion = @Sendable (NSRunningApplication?,Error?)->Void
    typealias Launcher = @MainActor (URL,SearchItemKind,URL?,@escaping OpenCompletion)->Void
    private let launch:Launcher
    private let executeQuery: (@Sendable (String, SearchCancellation) throws -> SearchResponse)?
    var selected: SearchItem? {
        guard response.query == query else { return nil }
        return response.items.first { $0.id == selection }
    }
    init(directory: URL = SearchStore.defaultDirectory, module: ModuleManifest? = nil, defaults: UserDefaults = .standard, enabled:@escaping ()->Bool = {true}, launch:Launcher? = nil, executeQuery: (@Sendable (String, SearchCancellation) throws -> SearchResponse)? = nil) {
        self.launch=launch ?? Self.launchItem
        self.acceptsWork=enabled
        self.executeQuery = executeQuery
        self.directory = directory
        self.module = module; self.defaults = defaults
        do {
            let store = try SearchStore(directory: directory)
            self.store = store; preferences = try store.preferences()
        } catch { self.error = String(describing: error) }
    }
    func start() {
        guard featureOn, !started else { return }
        if store == nil {
            do { store = try SearchStore(directory: directory); preferences = try store!.preferences() }
            catch { self.error = String(describing: error); return }
        }
        guard let store else { return }
        started = true; suspended = false; lifecycle = UUID()
        let epoch = lifecycle
        let indexer = SearchIndexer(store: store) { [weak self] busy, issue in
            Task { @MainActor in
                guard let self, self.started, self.lifecycle == epoch else { return }
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
                guard let self, self.started, self.lifecycle == epoch, let prefs = try? self.store?.preferences() else { return }
                self.preferences = prefs; self.indexer?.configure(prefs)
            }
        })
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            appObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.started == true, self?.lifecycle == epoch { self?.indexer?.refresh() } }
            })
        }
    }
    func stop() {
        suspended = true; started = false; lifecycle = UUID(); generation &+= 1
        cancellation?.cancel(); queryTask?.cancel()
        for task in queries.values { task.cancel() }
        if let indexer { indexer.stop(); retiringIndexers.append(indexer); self.indexer = nil }
        searching = false; indexing = false; selection = nil; directPath = nil
        response = SearchResponse(query: query, items: [])
        featureChoices=[];featureReview=nil;featureNotice=nil
        for observer in appObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer); DistributedNotificationCenter.default().removeObserver(observer) }
        appObservers.removeAll()
    }
    func finishStopping() async {
        let pending = Array(queries.values), indexers = retiringIndexers
        for task in pending { await task.value }
        for indexer in indexers { await indexer.finishStopping() }
        retiringIndexers.removeAll()
        if suspended { store = nil; queryTask = nil }
    }
    var enabled: Bool { featureOn && !suspended }
    var activeQueries: Int { queries.count }
    func refresh() { guard featureOn, !suspended else { return };error = nil; indexer?.refresh() }
    private var applicationsRefreshed: Date?
    /// Called each time the panel opens. Installs and removals are already caught by the app-folder
    /// watcher, so this safety-net rescan runs at most every five minutes.
    func refreshApplications(now: Date = Date()) {
        if let last = applicationsRefreshed, now.timeIntervalSince(last) < 300 { return }
        applicationsRefreshed = now; indexer?.refreshApplications()
    }
    var canOpenInPreview: Bool {
        guard let selected else { return false }
        return canOpenInPreview(selected)
    }
    func canOpenInPreview(_ item: SearchItem) -> Bool {
        guard item.kind == .file,
              let type = UTType(filenameExtension: URL(fileURLWithPath: item.path).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }
    func openInPreview() {
        guard canOpenInPreview, let selected,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { return }
        open(selected, using: app)
    }
    func submit() {
        guard featureOn, !suspended else { return }
        featureChoices=discovery.matches(query)
        guard let store else{return}
        generation &+= 1
        let current = generation, term = query, oldSelection = selection
        directPath = nil
        cancellation?.cancel(); queryTask?.cancel()
        let token = SearchCancellation(); cancellation = token; searching = true
        let taskID = UUID()
        let task = Task { [weak self] in
            defer { self?.queries.removeValue(forKey: taskID) }
            do {
                if !term.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
                let executeQuery = self?.executeQuery
                let (result, path) = try await Task.detached(priority: .userInitiated) {
                    (try executeQuery?(term, token) ?? store.query(term, cancellation: token), SearchDirectPath.path(from: term))
                }.value
                guard !Task.isCancelled, let self, current == self.generation else { return }
                self.response = result; self.directPath = path; self.searching = false
                let choices=self.choiceIDs
                self.selection = oldSelection.flatMap{choices.contains($0) ? $0:nil} ?? choices.first
            } catch is CancellationError { }
            catch {
                guard let self, current == self.generation else { return }
                self.error = String(describing: error); self.searching = false
            }
        }
        queries[taskID] = task; queryTask = task
    }
    private var choiceIDs:[String] {featureChoices.map{"feature:"+$0.id}+(response.query == query ? response.items.map(\.id):[])}
    func move(_ delta:Int) {
        let choices=choiceIDs
        guard !choices.isEmpty else{return}
        let index=choices.firstIndex(of:selection ?? "") ?? 0
        selection=choices[min(choices.count-1,max(0,index+delta))]
    }
    func reviewFeature(_ item:FeatureDiscoveryItem) {
        guard enabled,!presentingDialog,featureChoices.contains(where:{$0.id==item.id}) else{return}
        featureReview=item;presentingDialog=true
    }
    func cancelFeatureReview(){featureReview=nil;presentingDialog=false}
    func enableReviewedFeature() {
        guard enabled,let item=featureReview else{return}
        do {
            try discovery.enable(item)
            cancelFeatureReview();featureNotice=tr("%1$@ is on and ready to use.",item.name);submit()
        } catch {self.error=error.localizedDescription;cancelFeatureReview()}
    }
    static let defaultFoldersKey = "dev.thermo.search.defaultFoldersApplied"
    /// Once per user: someone who has never added a folder gets Desktop, Documents and Downloads, so
    /// search finds their files out of the box. Runs when the panel is first opened (not at launch),
    /// because reading these folders can bring up macOS's folder-access prompts. Folders the user
    /// removes later stay removed.
    func applyDefaultFoldersOnce(defaults: UserDefaults = .standard, home: String = NSHomeDirectory()) {
        guard enabled,!defaults.bool(forKey: Self.defaultFoldersKey) else { return }
        defaults.set(true, forKey: Self.defaultFoldersKey)
        guard preferences.roots.isEmpty else { return }
        let roots = ["Desktop", "Documents", "Downloads"].compactMap { name -> String? in
            var isDirectory: ObjCBool = false
            let path = (home as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return SearchPaths.canonical(path)
        }
        guard !roots.isEmpty else { return }
        var next = preferences; next.roots = roots
        configure(next)
    }
    func configure(_ preferences: SearchPreferences) {
        guard enabled else{return}
        self.preferences = preferences; error = nil
        indexer?.configure(preferences)
    }
    func chooseFolder() {
        guard enabled else{return}
        presentingDialog = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = tr("Add folders"); panel.message = tr("Choose folders to search by file name. File contents stay untouched.")
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }; self.presentingDialog = false
                guard self.enabled else{return}
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
        guard enabled else{return}
        do { try store?.setFavorite(!item.favorite, for: item.path); submit() } catch { self.error = String(describing: error) }
    }
    func saveAlias(_ alias: String, for item: SearchItem) {
        guard enabled else{return}
        do { try store?.setAlias(alias, for: item.path); aliasTarget = nil; submit() } catch { self.error = String(describing: error) }
    }
    func clearHistory() { guard enabled else{return};do { try store?.clearHistory(); submit() } catch { self.error = String(describing: error) } }
    func openSelected() {
        if let item=featureChoices.first(where:{"feature:"+$0.id==selection}) {reviewFeature(item)}
        else if let selected {open(selected)}
    }
    func open(_ item: SearchItem, using application: URL? = nil) {
        guard enabled else{return}
        guard response.query == query, response.items.contains(where: { $0.id == item.id }) else { return }
        guard FileManager.default.fileExists(atPath: item.path) else { error = tr("This item is no longer available. Check its location and try again."); return }
        let url = URL(fileURLWithPath: item.path)
        let epoch=lifecycle
        let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { [weak self] _, error in
            Task { @MainActor in
                guard let self,self.enabled,self.lifecycle==epoch else{return}
                if let error { self.error = error.localizedDescription; self.panel?.show(); return }
                do { try self.store?.recordOpen(item.path) } catch { self.error = String(describing: error) }
            }
        }
        panel?.hide(restoreFocus: false)
        launch(url,item.kind,application,completion)
    }
    private static func launchItem(_ url:URL,kind:SearchItemKind,application:URL?,completion:@escaping OpenCompletion) {
        let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
        if let application {NSWorkspace.shared.open([url],withApplicationAt:application,configuration:configuration,completionHandler:completion)}
        else if kind == .application {NSWorkspace.shared.openApplication(at:url,configuration:configuration,completionHandler:completion)}
        else {NSWorkspace.shared.open(url,configuration:configuration,completionHandler:completion)}
    }

    func revealSelected() {
        guard enabled else{return}
        guard let selected else { return }
        guard FileManager.default.fileExists(atPath: selected.path) else { error = tr("This item is no longer available. Check its location and try again."); return }
        panel?.hide(restoreFocus: false)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selected.path)])
    }
    func copySelectedPath() {
        guard enabled else{return}
        guard let selected else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.path, forType: .string)
    }
}
