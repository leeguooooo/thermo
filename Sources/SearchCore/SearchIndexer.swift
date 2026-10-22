import Foundation
import CoreServices

/// File events schedule metadata reconciliation, never search-time filesystem walks.
public final class SearchFileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.thermo.search.events", qos: .utility)
    private let changed: @Sendable ([String], Bool) -> Void
    public init(roots: [String], changed: @escaping @Sendable ([String], Bool) -> Void) throws {
        self.changed = changed
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, context, count, rawPaths, flags, _ in
            guard let context else { return }
            let owner = Unmanaged<SearchFileWatcher>.fromOpaque(context).takeUnretainedValue()
            let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var changes: [String] = [], rescan = false
            let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
            for i in 0..<count {
                if flags[i] & lost != 0 { rescan = true }
                changes.append(String(cString: paths[i]))
            }
            owner.changed(changes, rescan)
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)) else {
            throw SearchFailure("Could not watch the search folders. Use Refresh to reconcile changes.")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil
            throw SearchFailure("Could not watch the search folders. Use Refresh to reconcile changes.")
        }
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); queue.sync {}; FSEventStreamRelease(stream) }
    }
}

public final class SearchIndexer: @unchecked Sendable {
    public let store: SearchStore
    private let queue = DispatchQueue(label: "dev.thermo.search.index", qos: .utility)
    private let eventQueue = DispatchQueue(label: "dev.thermo.search.changes", qos: .utility)
    private let stateLock = NSLock()
    private var token = SearchCancellation()
    private var watcher: SearchFileWatcher?
    private var applicationWatcher: SearchFileWatcher?
    private var timer: DispatchSourceTimer?
    private var pending: Set<String> = []
    private var pendingAll = false
    private var scheduled: DispatchWorkItem?
    private var applicationScheduled: DispatchWorkItem?
    private var stopped = false
    private let onChange: @Sendable (Bool, String?) -> Void
    public init(store: SearchStore, onChange: @escaping @Sendable (Bool, String?) -> Void = { _, _ in }) {
        self.store = store; self.onChange = onChange
    }
    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.reconcile(paths: nil)
        }
        let timer = DispatchSource.makeTimerSource(queue: eventQueue)
        timer.schedule(deadline: .now() + 1800, repeating: 1800)
        timer.setEventHandler { [weak self] in self?.schedule(paths: [], all: true) }
        self.timer = timer; timer.resume()
    }
    public func stop() {
        stateLock.lock(); stopped = true; token.cancel(); stateLock.unlock()
        timer?.cancel(); timer = nil
        eventQueue.async { [weak self] in self?.scheduled?.cancel(); self?.scheduled = nil; self?.applicationScheduled?.cancel(); self?.applicationScheduled = nil }
        queue.async { [weak self] in self?.watcher = nil; self?.applicationWatcher = nil }
    }
    public func refresh() { schedule(paths: [], all: true) }
    public func refreshApplications() {
        eventQueue.async { [weak self] in
            guard let self, self.applicationScheduled == nil else { return }
            let job = DispatchWorkItem { [weak self] in
                guard let self else { return }; self.applicationScheduled = nil
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.stateLock.lock(); let stopped = self.stopped; self.stateLock.unlock()
                    guard !stopped else { return }
                    self.onChange(true, nil)
                    do {
                        let report = ApplicationCatalog.scan()
                        try self.store.replaceApplications(report.items, complete: report.complete)
                        self.onChange(false, report.issues.first)
                    } catch { self.onChange(false, String(describing: error)) }
                }
            }
            self.applicationScheduled = job; self.eventQueue.asyncAfter(deadline: .now() + 0.2, execute: job)
        }
    }
    public func configure(_ preferences: SearchPreferences) {
        stateLock.lock(); token.cancel(); stateLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            do { try self.store.savePreferences(preferences); self.reconcile(paths: nil) }
            catch { self.onChange(false, String(describing: error)) }
        }
    }
    private func installWatcher(_ preferences: SearchPreferences) throws {
        watcher = nil
        if applicationWatcher == nil {
            let applications = ApplicationCatalog.defaultRoots.map { SearchPaths.canonical($0.path) }.filter { FileManager.default.fileExists(atPath: $0) }
            applicationWatcher = try? SearchFileWatcher(roots: applications) { [weak self] _, _ in self?.refreshApplications() }
        }
        let available = preferences.roots.filter { FileManager.default.fileExists(atPath: $0) }
        watcher = try SearchFileWatcher(roots: available) { [weak self] paths, all in self?.schedule(paths: paths, all: all) }
    }
    private func schedule(paths: [String], all: Bool) {
        eventQueue.async { [weak self] in
            guard let self else { return }
            let index = self.store.directory.path
            let relevant = paths.map(SearchPaths.entry).filter { !SearchPaths.isWithin($0, root: index) }
            if !paths.isEmpty && relevant.isEmpty { return }
            self.pending.formUnion(relevant); self.pendingAll = self.pendingAll || all
            if self.pending.count > 512 { self.pending.removeAll(); self.pendingAll = true }
            guard self.scheduled == nil else { return }
            let job = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let paths: [String]? = self.pendingAll ? nil : Array(self.pending)
                self.pending.removeAll(); self.pendingAll = false; self.scheduled = nil
                self.queue.async { [weak self] in self?.reconcile(paths: paths) }
            }
            self.scheduled = job; self.eventQueue.asyncAfter(deadline: .now() + 1, execute: job)
        }
    }
    private func reconcile(paths: [String]?) {
        stateLock.lock()
        guard !stopped else { stateLock.unlock(); return }
        let cancellation = SearchCancellation(); token = cancellation
        stateLock.unlock()
        onChange(true, nil)
        var messages: [String] = []
        defer { onChange(false, messages.first) }
        do {
            let preferences = try store.preferences()
            if paths == nil {
                do { try installWatcher(preferences) } catch { messages.append(String(describing: error)) }
                let apps = ApplicationCatalog.scan(cancellation: cancellation)
                try store.replaceApplications(apps.items, complete: apps.complete)
                messages += apps.issues
                onChange(true, nil)
            }
            for root in preferences.roots {
                if cancellation.isCancelled { return }
                let scopes: [String]
                if let paths {
                    let candidates = Set(paths.filter { SearchPaths.isWithin($0, root: root) }.map { path -> String in
                        // Reconcile the parent of a file/rename so removed names and ignore-rule changes are handled together.
                        path == root ? root : (path as NSString).deletingLastPathComponent
                    })
                    scopes = candidates.sorted { $0.count < $1.count }.reduce(into: []) { result, path in
                        if !result.contains(where: { SearchPaths.isWithin(path, root: $0) }) { result.append(path) }
                    }
                } else { scopes = [root] }
                for scope in scopes {
                    if cancellation.isCancelled { return }
                    let generation = UUID().uuidString
                    var directory: ObjCBool = false
                    if scope != root, !FileManager.default.fileExists(atPath: scope, isDirectory: &directory) {
                        try store.finishScan(root: root, generation: generation, complete: true, scope: scope)
                        continue
                    }
                    var publishedAt = ProcessInfo.processInfo.systemUptime
                    let report = try SearchFileScanner.scan(root: URL(fileURLWithPath: root), scope: URL(fileURLWithPath: scope),
                                                            preferences: preferences, cancellation: cancellation, excludingPaths: [store.directory.path]) { items in
                        if cancellation.isCancelled { throw CancellationError() }
                        try self.store.upsert(items, root: root, generation: generation)
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - publishedAt >= 0.5 { publishedAt = now; self.onChange(true, nil) }
                    }
                    try store.finishScan(root: root, generation: generation, complete: report.complete && !cancellation.isCancelled, scope: scope == root ? nil : scope)
                    if scope == root {
                        try store.markRoot(root, count: report.count, issue: report.issues.first, available: report.available, completed: report.complete)
                    } else {
                        let old = try store.rootsReport().first { $0.path == root }
                        try store.markRoot(root, count: old?.count ?? 0, issue: report.issues.first ?? old?.issue, available: report.available, completed: false)
                    }
                    messages += report.issues
                }
            }
        } catch is CancellationError { }
        catch { messages.append(String(describing: error)) }
    }
}
