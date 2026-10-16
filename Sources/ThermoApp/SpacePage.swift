import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

enum SpaceTab: String, Hashable, CaseIterable {
    case browse, large, duplicates
}

/// The space browser: the home folder measured once, then any folder looked into without walking
/// again; the big files; the duplicate files. What the user picks waits in one basket and goes to
/// the Trash only after a confirmation that lists every path.
@MainActor
final class SpaceLensModel: ObservableObject {
    static let shared = SpaceLensModel()

    let root: String
    @Published private(set) var tree: SpaceTree?
    @Published var path: String
    @Published private(set) var scanning = false
    @Published private(set) var stopping = false
    @Published private(set) var progress: SpaceLens.Progress?
    /// Picked paths and what removing each gives back.
    @Published var basket: [String: Int64] = [:]
    @Published private(set) var working = false
    @Published var exitRequested = false
    @Published var outcome: String?
    @Published private(set) var outcomeIsWarning = false
    /// When Spotlight last saw each big file opened (nil inside: it does not know).
    @Published private(set) var lastOpened: [String: Date?] = [:]
    @Published private(set) var duplicates: [DuplicateGroup]?
    @Published private(set) var duplicateReport: DuplicateScanReport?
    @Published private(set) var duplicateStopped = false
    @Published private(set) var findingDuplicates = false
    @Published private(set) var stoppingDuplicates = false
    @Published private(set) var duplicateProgress: Duplicates.Progress?
    private var cancellation: ScanCancellation?
    private var scanGeneration = UUID(), needsRestoreRefresh = false, pendingRestoreRefresh = false
    private var lastOpenedGeneration = UUID()
    @Published private(set) var loadingLastOpened = false
    private var lastOpenedCancellation: ScanCancellation?
    private var wantsLastOpened = false
    private let readLastOpened: @Sendable (String) -> Date?
    private var duplicateCancellation: ScanCancellation?
    private var duplicateInFlight = false, pendingDuplicate = false
    private let searchDuplicates: @Sendable ([String], ScanCancellation, ((Duplicates.Progress) -> Void)?) -> DuplicateScanReport
    private let cache: URL
    private let measure: @Sendable (String, ScanCancellation, ((SpaceLens.Progress) -> Void)?) -> SpaceTree
    private var selectionIdentities: [String: String] = [:]
    private var selectionSizeStates: [String: AppSizeState] = [:]
    private var selectionRequirements: [String: [String: String]] = [:]
    private let remove: @Sendable ([String], [String: Int64], String, Set<String>, [String: String], [String: String]) -> CleanResult

    init(root: String = NSHomeDirectory(), cache: URL = SpaceLens.cacheURL,
         measure: @escaping @Sendable (String, ScanCancellation, ((SpaceLens.Progress) -> Void)?) -> SpaceTree = { SpaceLens.scan($0, cancellation: $1, progress: $2) },
         remove: @escaping @Sendable ([String], [String: Int64], String, Set<String>, [String: String], [String: String]) -> CleanResult = {
             ManualRemoval.trash($0, sizes: $1, home: $2, incompletePaths: $3, reviewIdentities: $4, requiredIdentities: $5)
         }, searchDuplicates: @escaping @Sendable ([String], ScanCancellation, ((Duplicates.Progress) -> Void)?) -> DuplicateScanReport = {
             Duplicates.scan(in: $0, cancellation: $1, progress: $2)
         }, readLastOpened: @escaping @Sendable (String) -> Date? = { SpaceLens.lastOpened($0) }) {
        self.readLastOpened = readLastOpened
        self.root = root
        self.cache = cache; self.measure = measure; self.remove = remove
        self.searchDuplicates = searchDuplicates
        path = root
        tree = SpaceLens.cached(root: root, from: cache)
    }

    var folder: SpaceFolder? { tree?.folder(path) }
    var basketBytes: Int64 { basket.filter { sizeState($0.key) != .unavailable && sizeState($0.key) != .unmeasured }.values.reduce(0, +) }
    func sizeState(_ path: String) -> AppSizeState {
        if let state = selectionSizeStates[path] { return state }
        if let entry = tree?.folder(path)?.entry { return entry.effectiveSizeState }
        if let entry = tree?.folder((path as NSString).deletingLastPathComponent)?.children.first(where: { $0.path == path }) { return entry.effectiveSizeState }
        if tree?.large.contains(where: { $0.path == path }) == true { return .complete }
        if duplicates?.contains(where: { $0.privateBytes?[path] != nil }) == true { return .complete }
        return .unavailable
    }
    var basketSizeText: String { AppSize.text(basketBytes, state: AppSize.combined(basket.keys.map(sizeState), bytes: basketBytes)) }

    static let duplicateRoots = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
        .map { NSHomeDirectory() + "/" + $0 }

    func scan() {
        guard !working else { return }
        if scanning {
            if needsRestoreRefresh { pendingRestoreRefresh = true }
            return
        }
        cancellation?.cancel()
        lastOpenedGeneration = UUID(); lastOpenedCancellation?.cancel(); lastOpened = [:]
        let token = ScanCancellation()
        cancellation = token
        scanGeneration = UUID(); let generation = scanGeneration
        needsRestoreRefresh = false; pendingRestoreRefresh = false
        scanning = true
        stopping = false
        progress = nil
        let root = root
        let measure = self.measure, cache = self.cache
        Task.detached(priority: .userInitiated) {
            let tree = measure(root, token) { p in
                Task { @MainActor in if self.cancellation === token && self.scanGeneration == generation && !token.isCancelled { self.progress = p } }
            }
            if !token.isCancelled { SpaceLens.save(tree, to: cache) }
            if token.isCancelled { SpaceLens.invalidateCache(at: cache) }
            await MainActor.run {
                guard self.cancellation === token else { return }
                self.scanning = false
                self.stopping = false
                self.progress = nil
                self.cancellation = nil
                if self.pendingRestoreRefresh { self.pendingRestoreRefresh = false; self.scan(); return }
                guard self.scanGeneration == generation else { return }
                self.tree = tree
                if self.tree?.folder(self.path) == nil { self.path = root }
                self.lastOpened = [:]
                if self.wantsLastOpened { self.loadLastOpened() }
            }
        }
    }

    func stop() {
        stopLastOpened()
        pendingRestoreRefresh = false
        guard scanning else { return }
        cancellation?.cancel()
        stopping = true
    }

    func invalidateAfterRestore(_ paths: [String]) {
        guard paths.contains(where: { $0 == root || $0.hasPrefix(root + "/") }) else { return }
        scanGeneration = UUID(); needsRestoreRefresh = true; pendingRestoreRefresh = false
        cancellation?.cancel(); progress = nil
        if scanning { stopping = true }
        stopDuplicates(); duplicates = nil; duplicateReport = nil; duplicateStopped = false
        stopLastOpened(); lastOpenedGeneration = UUID(); lastOpened = [:]
        basket = [:]; selectionIdentities = [:]; selectionRequirements = [:]; selectionSizeStates = [:]
        tree = nil; outcome = nil; outcomeIsWarning = false
        if !SpaceLens.invalidateCache(at: cache) { outcomeIsWarning = true; outcome = tr("The old space cache could not be cleared; scan again before using saved results") }
    }

    func open(_ path: String) { if tree?.folder(path) != nil { self.path = path } }

    func refusal(_ path: String) -> String? { ManualRemoval.refusal(path, home: root) }

    func toggle(_ path: String, bytes: Int64) {
        guard !working else { return }
        if basket[path] != nil { basket[path] = nil; selectionIdentities[path] = nil; selectionRequirements[path] = nil; selectionSizeStates[path] = nil; return }
        guard refusal(path) == nil else { return }
        guard let identity = ManualRemoval.reviewIdentity(path) else { outcomeIsWarning = true; outcome = tr("Could not verify the selected item; refresh before selecting it"); return }
        // A folder already holds what is under it; picking one replaces its picked insides,
        // and an inside path is not picked again on top of its picked folder.
        if basket.keys.contains(where: { path.hasPrefix($0 + "/") }) { return }
        for key in basket.keys where key.hasPrefix(path + "/") { basket[key] = nil; selectionIdentities[key] = nil; selectionRequirements[key] = nil; selectionSizeStates[key] = nil }
        selectionSizeStates[path] = sizeState(path)
        basket[path] = bytes
        selectionIdentities[path] = identity
    }

    func isCovered(_ path: String) -> Bool { basket.keys.contains { path.hasPrefix($0 + "/") } }

    /// One line per path for the confirmation, biggest first.
    var basketLines: [String] {
        basket.sorted { $0.value > $1.value }.map { AppSize.text($0.value, state: sizeState($0.key)) + "  " + FSPath.tilde($0.key) }
    }

    func trash() {
        guard !scanning, !working else { return }
        let picked = basket
        guard !picked.isEmpty else { return }
        let measured = picked.filter { sizeState($0.key) != .unavailable && sizeState($0.key) != .unmeasured }
        stopDuplicates()
        working = true
        exitRequested = false
        let lease = AppExitGuard.beginManualRemoval { self.exitRequested = true }
        let root = root
        let incomplete = Set(picked.keys.filter { sizeState($0) != .complete })
        let identities = selectionIdentities, remove = self.remove
        let required = picked.keys.reduce(into: [String: String]()) { result, path in
            result.merge(selectionRequirements[path] ?? [:]) { first, _ in first }
        }
        Task.detached(priority: .userInitiated) {
            let result = remove(picked.keys.sorted(), measured, root, incomplete, identities, required)
            await MainActor.run { self.afterTrash(result); AppExitGuard.endManualRemoval(lease) }
        }
    }

    func afterTrash(_ result: CleanResult) {
        working = false
        let removed = Set(result.removed)
        if !removed.isEmpty {
            lastOpenedGeneration = UUID(); lastOpenedCancellation?.cancel()
            lastOpened = lastOpened.filter { path, _ in !removed.contains { path == $0 || path.hasPrefix($0 + "/") } }
        }
        let cacheCleared = removed.isEmpty || SpaceLens.invalidateCache(at: cache)
        for p in removed { basket[p] = nil; selectionIdentities[p] = nil; selectionRequirements[p] = nil; selectionSizeStates[p] = nil }
        if let t = tree {
            let updated = t.removing(removed)
            tree = updated
            SpaceLens.save(updated, to: cache)
            if updated.folder(path) == nil { path = root }
        }
        if let groups = duplicates {
            duplicates = groups.compactMap { g in
                var g = g
                g.paths.removeAll { p in removed.contains { p == $0 || p.hasPrefix($0 + "/") } }
                guard g.paths.count > 1 else { return nil }
                g.reclaimable = g.paths.dropFirst().reduce(0) { $0 + (g.privateBytes?[$1] ?? 0) }
                g.reclaimableState = g.paths.dropFirst().allSatisfy { g.privateBytes?[$0] != nil } ? .complete : (g.reclaimable > 0 ? .incomplete : .unavailable)
                return g
            }
        }
        duplicateReport?.groups = duplicates ?? []
        var parts = ManualRemoval.feedback(result)
        outcomeIsWarning = !result.failed.isEmpty || !cacheCleared
        if !cacheCleared { parts.append(tr("The old space cache could not be cleared; scan again before using saved results")) }
        outcome = parts.joined(separator: " ")
        if wantsLastOpened { loadLastOpened() }
    }

    /// Keep one physical metadata reader until it returns, including after cancellation.
    func loadLastOpened() {
        wantsLastOpened = true
        guard !loadingLastOpened, !scanning, !working else { return }
        let files = (tree?.large ?? []).prefix(3000).map(\.path).filter { lastOpened[$0] == nil }
        guard !files.isEmpty else { return }
        let generation = lastOpenedGeneration, token = ScanCancellation(), read = readLastOpened
        lastOpenedCancellation = token; loadingLastOpened = true
        Task.detached(priority: .utility) {
            var found: [String: Date?] = [:]
            for file in files {
                if token.isCancelled { break }
                let value = read(file)
                if token.isCancelled { break }
                found[file] = .some(value)
            }
            let result = found
            await MainActor.run {
                self.loadingLastOpened = false; self.lastOpenedCancellation = nil
                if self.wantsLastOpened && !token.isCancelled && self.lastOpenedGeneration == generation {
                    self.lastOpened.merge(result) { _, new in new }
                }
                if self.wantsLastOpened { self.loadLastOpened() }
            }
        }
    }

    func stopLastOpened() {
        wantsLastOpened = false
        lastOpenedCancellation?.cancel()
    }

    var duplicateSizeText: String {
        let groups = duplicates ?? [], bytes = groups.reduce(Int64(0)) { $0 + $1.reclaimable }
        let states = groups.map { $0.reclaimableState ?? .unavailable } +
            (duplicateReport?.complete == true && !duplicateStopped ? [] : [.incomplete])
        return AppSize.text(bytes, state: AppSize.combined(states, bytes: bytes))
    }

    func findDuplicates() {
        guard !working else { return }
        if duplicateInFlight {
            pendingDuplicate = true; duplicateCancellation?.cancel(); stoppingDuplicates = true
            return
        }
        duplicateInFlight = true
        duplicateStopped = false
        let token = ScanCancellation()
        duplicateCancellation = token
        findingDuplicates = true
        stoppingDuplicates = false
        duplicateProgress = nil
        let roots = Duplicates.defaultRoots(home: root)
        let search = searchDuplicates
        Task.detached(priority: .userInitiated) {
            let report = search(roots, token) { p in
                Task { @MainActor in if self.duplicateCancellation === token && !token.isCancelled { self.duplicateProgress = p } }
            }
            await MainActor.run {
                self.duplicateInFlight = false
                self.duplicateCancellation = nil
                let pending = self.pendingDuplicate; self.pendingDuplicate = false
                self.findingDuplicates = false
                self.stoppingDuplicates = false
                self.duplicateProgress = nil
                if pending { self.findDuplicates(); return }
                if !token.isCancelled { self.duplicateReport = report; self.duplicates = report.groups }
            }
        }
    }

    func stopDuplicates() {
        if duplicateInFlight { duplicateStopped = true }
        duplicateCancellation?.cancel()
        pendingDuplicate = false
        stoppingDuplicates = duplicateInFlight
        duplicateProgress = nil
    }

    /// Picks every copy but the oldest one in each group.
    func pickAllButOldest() {
        for g in duplicates ?? [] {
            for p in g.paths.dropFirst() where basket[p] == nil && refusal(p) == nil { toggleDuplicate(p, group: g) }
        }
    }

    func toggleDuplicate(_ path: String, group: DuplicateGroup) {
        guard !working else { return }
        if basket[path] != nil { toggle(path, bytes: 0); return }
        guard let keeper = group.paths.first, path != keeper, let identities = group.reviewIdentities,
              let selected = identities[path], let retained = identities[keeper],
              ManualRemoval.reviewIdentity(path) == selected, ManualRemoval.reviewIdentity(keeper) == retained else {
            outcomeIsWarning = true
            outcome = tr("Duplicate comparison changed; compare the files again")
            return
        }
        toggle(path, bytes: group.privateBytes?[path] ?? 0)
        if basket[path] != nil {
            selectionIdentities[path] = selected
            selectionRequirements[path] = [keeper: retained]
            selectionSizeStates[path] = group.privateBytes?[path] == nil ? .unavailable : .complete
        }
    }

    func clearBasket() { guard !working else { return }; basket = [:]; selectionIdentities = [:]; selectionRequirements = [:]; selectionSizeStates = [:] }
}

struct SpacePage: View {
    @ObservedObject var model: SpaceLensModel
    @Binding var tab: SpaceTab
    @State private var confirming = false
    @State private var olderThan = 0

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 12)
            if model.exitRequested && model.working {
                Text(tr("Wait for the selected files to finish moving before quitting.")).font(.callout).foregroundStyle(.orange).padding(.horizontal, 28)
            }
            if let tree = model.tree, !tree.complete {
                Text(tr("Some locations were not fully measured. Sizes and chart areas show only known data."))
                    .font(.callout).foregroundStyle(.orange).padding(.horizontal, 28).padding(.bottom, 8)
            }
            if let outcome = model.outcome {
                HStack(alignment: .top) {
                    Label(outcome, systemImage: model.outcomeIsWarning ? "exclamationmark.triangle" : "trash").font(.callout).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                    Spacer()
                    Button { model.outcome = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        .accessibilityLabel(tr("Dismiss")).help(tr("Dismiss"))
                }
                .padding(12).glass(radius: 12).padding(.horizontal, 28).padding(.bottom, 10)
            }
            switch tab {
            case .browse: browse
            case .large: largeList
            case .duplicates: duplicateList
            }
            footer
        }
        .onAppear {
            if model.tree == nil { model.scan() }
            if tab == .large { model.loadLastOpened() }
        }
        .onChange(of: tab) { t in
            if t == .large { model.loadLastOpened() } else { model.stopLastOpened() }
            if t != .duplicates { model.stopDuplicates() }
        }
        .onDisappear { model.stopLastOpened(); model.stopDuplicates() }
        .sheet(isPresented: $confirming) {
            ConfirmSheet(title: tr("Move %1$@ to the Trash?", model.basketSizeText),
                         summary: tr("%1$@ you picked go to the Trash. Each one is checked again first; anything a program has open is skipped.",
                                     trCount(model.basket.count, "%1$@ item", "%1$@ items")),
                         destructive: false, heading: tr("What will be moved to the Trash"), lines: model.basketLines,
                         footnote: tr("You can put them back from the Trash. Moves are listed in ~/Library/Logs/Thermo/clean.log."),
                         confirmTitle: tr("Move to Trash"),
                         confirm: { confirming = false; model.trash() }, cancel: { confirming = false })
        }
    }

    // MARK: Header and footer

    var header: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "square.grid.3x3.topleft.filled", color: .cyan, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Space Lens")).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
            Picker("", selection: $tab) {
                Text(tr("Folders")).tag(SpaceTab.browse)
                Text(tr("Large files")).tag(SpaceTab.large)
                Text(tr("Duplicates")).tag(SpaceTab.duplicates)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 250)
            .accessibilityLabel(tr("Show"))
        }
    }

    var subtitle: String {
        if model.stopping { return tr("Stopping…") }
        if model.scanning {
            guard let p = model.progress else { return tr("Measuring your home folder…") }
            return tr("Measuring… %1$@ files, %2$@", String(p.files), ByteFormat.string(p.bytes))
        }
        guard let t = model.tree, let top = t.folder(t.root) else { return tr("Size unavailable") }
        return tr("Home folder %1$@ · measured %2$@", top.entry.sizeText, AgeFormat.string(t.scanned))
    }

    var footer: some View {
        HStack(spacing: 10) {
            if model.scanning || model.working {
                ProgressView().controlSize(.small)
                if model.scanning {
                    Button(tr("Stop")) { model.stop() }.buttonStyle(PillButtonStyle()).disabled(model.stopping)
                }
            } else {
                Button(tr("Measure again")) { model.scan() }.buttonStyle(PillButtonStyle()).disabled(model.working)
            }
            if !model.basket.isEmpty {
                Button(tr("Clear")) { model.clearBasket() }.buttonStyle(PillButtonStyle()).disabled(model.working)
            }
            Spacer()
            Text(model.basket.isEmpty ? tr("Tick files or folders to remove them") : trCount(model.basket.count, "%1$@ picked", "%1$@ picked"))
                .font(.callout).foregroundStyle(.white.opacity(0.55))
            Button(model.basket.isEmpty ? tr("Move to Trash") : tr("Review %1$@…", model.basketSizeText)) { confirming = true }
                .buttonStyle(PillButtonStyle(prominent: true, color: .cyan))
                .disabled(model.basket.isEmpty || model.working || model.scanning)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(Color.black.opacity(0.2))
    }

    // MARK: Folders

    @ViewBuilder var browse: some View {
        if let t = model.tree, let f = model.folder {
            VStack(alignment: .leading, spacing: 10) {
                pathBar(t)
                Treemap(entries: f.children, parentBytes: f.entry.bytes, picked: Set(model.basket.keys)) { e in
                    if e.isDir { model.open(e.path) }
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.horizontal, 28).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(f.children) { entryRow($0, of: f.entry.bytes) }
                    if f.otherCount > 0 {
                        HStack {
                            Text(trCount(f.otherCount, "%1$@ smaller item", "%1$@ smaller items")).font(.caption).foregroundStyle(.white.opacity(0.45))
                            Spacer()
                            Text(ByteFormat.string(f.otherBytes)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    if f.children.isEmpty && f.otherCount == 0 && f.entry.effectiveSizeState == .complete {
                        Text(tr("Empty")).foregroundStyle(.secondary).padding(.top, 20)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 16)
            }
        } else {
            VStack(spacing: 12) {
                if model.scanning { ProgressView() }
                Text(model.scanning ? tr("Measuring your home folder once; after that every folder opens at once.") : tr("This location could not be measured. Check access and scan again."))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func pathBar(_ t: SpaceTree) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if model.path != t.root {
                    Button { model.open((model.path as NSString).deletingLastPathComponent) } label: {
                        Image(systemName: "chevron.left").font(.caption.weight(.semibold)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8)).accessibilityLabel(tr("Back")).help(tr("Back"))
                }
                let trail = t.trail(to: model.path)
                ForEach(Array(trail.enumerated()), id: \.element.path) { i, e in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35)) }
                    Button { model.open(e.path) } label: {
                        Text(i == 0 ? "~" : e.name).font(.system(size: 12, weight: i == trail.count - 1 ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(i == trail.count - 1 ? 1 : 0.65)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                Text(model.folder?.entry.sizeText ?? tr("Size unavailable")).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                    .padding(.leading, 6)
            }
        }
    }

    func entryRow(_ e: SpaceEntry, of total: Int64) -> some View {
        let picked = model.basket[e.path] != nil || model.isCovered(e.path)
        let refusal = model.refusal(e.path)
        let canOpen = e.isDir && model.tree?.folder(e.path) != nil
        return HStack(spacing: 10) {
            tick(e.path, bytes: e.bytes, picked: picked, refusal: refusal, name: e.name)
            Image(nsImage: NSWorkspace.shared.icon(forFile: e.path)).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).font(.system(size: 13)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                Text([e.isDir ? trCount(e.files, "%1$@ file", "%1$@ files") : nil, e.newest.map { tr("changed %1$@", AgeFormat.string($0)) }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 8)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Color.cyan.opacity(0.7))
                        .frame(width: max(2, g.size.width * CGFloat(Double(e.bytes) / Double(max(total, 1)))))
                }
            }
            .frame(width: 90, height: 5).accessibilityHidden(true)
            Text(e.sizeText).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                .frame(minWidth: 76, alignment: .trailing)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(canOpen ? 0.5 : 0))
                .frame(width: 14).accessibilityHidden(true)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(picked ? 0.1 : 0.03)))
        .contentShape(Rectangle())
        .onTapGesture { if canOpen { model.open(e.path) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(canOpen ? .isButton : [])
        .contextMenu { pathMenu(e.path) }
    }

    func tick(_ path: String, bytes: Int64, picked: Bool, refusal: String?, name: String, action: (() -> Void)? = nil) -> some View {
        Button { if let action { action() } else { model.toggle(path, bytes: bytes) } } label: {
            Image(systemName: refusal != nil ? "lock.fill" : picked ? "checkmark.circle.fill" : "circle")
                .font(refusal != nil ? .caption : .body)
                .foregroundStyle(picked ? Color.cyan : .white.opacity(refusal != nil ? 0.3 : 0.5))
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(refusal != nil || model.working || (model.isCovered(path) && model.basket[path] == nil))
        .help(refusal ?? (picked ? tr("Picked to move to the Trash") : tr("Pick to move to the Trash")))
        .accessibilityLabel(tr("Select %1$@", name))
        .accessibilityValue(picked ? tr("Selected") : tr("Not selected"))
    }

    @ViewBuilder func pathMenu(_ path: String) -> some View {
        Button(tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        Button(tr("Copy path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
    }

    // MARK: Large files

    var largeFiles: [LargeFile] {
        let all = model.tree?.large ?? []
        guard olderThan > 0 else { return all }
        let cutoff = Date().addingTimeInterval(-Double(olderThan) * 86400)
        return all.filter { f in
            SpaceLens.notOpened(since: cutoff, lastOpened: model.lastOpened[f.path] ?? nil)
        }
    }

    @ViewBuilder var largeList: some View {
        HStack {
            Text(tr("Files of 100 MB or more in your home folder.")).font(.caption).foregroundStyle(.white.opacity(0.5))
            Spacer()
            if model.loadingLastOpened { ProgressView().controlSize(.small).accessibilityLabel(tr("Checking last opened dates")) }
            Picker(tr("Not opened for"), selection: $olderThan) {
                Text(tr("Any age")).tag(0)
                Text(tr("Not opened for 3 months")).tag(90)
                Text(tr("Not opened for a year")).tag(365)
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 210)
            .accessibilityLabel(tr("Not opened for"))
        }
        .padding(.horizontal, 28).padding(.bottom, 8)
        ScrollView {
            LazyVStack(spacing: 2) {
                let files = largeFiles
                if olderThan > 0 {
                    let unknown = (model.tree?.large ?? []).filter { (model.lastOpened[$0.path] ?? nil) == nil }.count
                    if unknown > 0 {
                        Text(tr("%1$@ files have no known last opened date and are excluded from this filter.", String(unknown)))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(files) { largeRow($0) }
                if files.isEmpty {
                    Text(model.tree == nil ? tr("Measuring your home folder…") : tr("No matching items")).foregroundStyle(.secondary).padding(.top, 30)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 16)
        }
    }

    func largeRow(_ f: LargeFile) -> some View {
        let picked = model.basket[f.path] != nil || model.isCovered(f.path)
        let name = (f.path as NSString).lastPathComponent
        let opened = model.lastOpened[f.path] ?? nil
        return HStack(spacing: 10) {
            tick(f.path, bytes: f.bytes, picked: picked, refusal: model.refusal(f.path), name: name)
            Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                Text(FSPath.tilde((f.path as NSString).deletingLastPathComponent)).font(.caption).foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(opened.map { tr("opened %1$@", AgeFormat.string($0)) } ?? tr("changed %1$@", AgeFormat.string(f.modified)))
                .font(.caption).foregroundStyle(.white.opacity(0.55)).frame(width: 130, alignment: .trailing)
            Text(ByteFormat.string(f.bytes)).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(picked ? 0.1 : 0.03)))
        .contextMenu { pathMenu(f.path) }
    }

    // MARK: Duplicates

    @ViewBuilder var duplicateList: some View {
        HStack(spacing: 10) {
            Text(tr("Identical files of 1 MB or more in Desktop, Documents, Downloads, Movies, Music and Pictures, compared byte for byte."))
                .font(.caption).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.findingDuplicates {
                Button(tr(model.stoppingDuplicates ? "Stopping…" : "Stop")) { model.stopDuplicates() }.buttonStyle(PillButtonStyle()).disabled(model.stoppingDuplicates)
            } else {
                if let d = model.duplicates, !d.isEmpty {
                    Button(tr("Keep the oldest of each")) { model.pickAllButOldest() }.buttonStyle(PillButtonStyle()).disabled(model.working)
                }
                Button(model.duplicates == nil ? tr("Find duplicates") : tr("Look again")) { model.findDuplicates() }
                    .buttonStyle(PillButtonStyle()).disabled(model.working)
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 8)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if model.findingDuplicates {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.duplicateProgress.map { p in p.total > 0 ? "\(p.stage) \(p.done)/\(p.total)" : p.stage } ?? tr("Looking…"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)
                } else {
                    if model.duplicateStopped {
                        Label(tr("Duplicate scan stopped. Displayed results may be out of date; run it again."), systemImage: "pause.circle").foregroundStyle(.secondary)
                    }
                    if let report = model.duplicateReport, !report.complete {
                        Label(tr("Duplicate scan is incomplete. Some locations could not be compared."), systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        DisclosureGroup(tr("Locations requiring another check")) {
                            ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                                Text(FSPath.tilde(issue.path) + ": " + issue.reason).font(.caption).textSelection(.enabled)
                            }
                            if report.omittedIssueCount > 0 {
                                Text(tr("%1$@ additional scan issues were omitted.", String(report.omittedIssueCount))).font(.caption)
                            }
                        }
                    }
                    if let groups = model.duplicates {
                        if groups.isEmpty {
                            if model.duplicateReport?.complete == true && !model.duplicateStopped {
                                Label(tr("No duplicate files found."), systemImage: "checkmark.circle").foregroundStyle(.secondary).padding(.top, 30)
                            } else {
                                Text(tr("No confirmed duplicate groups in this incomplete scan.")).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(tr("%1$@ could be freed by keeping one copy of each.", model.duplicateSizeText))
                                .font(.callout).foregroundStyle(.white.opacity(0.75))
                            ForEach(groups) { duplicateCard($0) }
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 16)
        }
    }

    func duplicateCard(_ g: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text((g.paths.first.map { ($0 as NSString).lastPathComponent }) ?? "").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(tr("%1$@ copies of %2$@", String(g.paths.count), ByteFormat.string(g.size))).font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }
            ForEach(Array(g.paths.enumerated()), id: \.element) { i, p in
                let picked = model.basket[p] != nil || model.isCovered(p)
                HStack(spacing: 8) {
                    tick(p, bytes: g.privateBytes?[p] ?? 0, picked: picked, refusal: i == 0 ? tr("This copy is kept as the comparison reference") : model.refusal(p), name: (p as NSString).lastPathComponent, action: { model.toggleDuplicate(p, group: g) })
                    Text(FSPath.tilde(p)).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.75)).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    if i == 0 {
                        Text(tr("oldest")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.green.opacity(0.18)))
                    }
                    Spacer()
                }
                .contextMenu { pathMenu(p) }
            }
        }
        .padding(12).glass(radius: 12)
    }
}

/// A one-level treemap of a folder: each child a tile with area by size. Clicking a folder opens it.
struct Treemap: View {
    let entries: [SpaceEntry]
    let parentBytes: Int64
    let picked: Set<String>
    let open: (SpaceEntry) -> Void

    var body: some View {
        GeometryReader { g in
            let shown = Array(entries.prefix(60))
            let rects = Self.squarify(shown.map { Double(max($0.bytes, 1)) }, in: CGRect(origin: .zero, size: g.size),
                                      total: Double(max(parentBytes, 1)))
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white.opacity(0.04))
                ForEach(shown.indices, id: \.self) { i in tile(shown[i], rects[i], index: i) }
            }
        }
    }

    func tile(_ e: SpaceEntry, _ r: CGRect, index: Int) -> some View {
        let hue = e.isDir ? 0.5 + Double(index % 6) * 0.035 : 0.62
        let color = Color(hue: hue, saturation: e.isDir ? 0.55 : 0.2, brightness: 0.55 - Double(index % 3) * 0.06)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(picked.contains(e.path) ? Color.red.opacity(0.55) : color)
            if r.width > 54 && r.height > 28 {
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(e.sizeText).font(.system(size: 10).monospacedDigit()).opacity(0.7)
                }
                .foregroundStyle(.white).padding(5)
            }
        }
        .frame(width: max(0, r.width - 2), height: max(0, r.height - 2))
        .offset(x: r.minX + 1, y: r.minY + 1)
        .contentShape(Rectangle())
        .onTapGesture { open(e) }
        .help("\(e.name) · \(e.sizeText)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(e.name), \(e.sizeText)")
        .accessibilityAddTraits(e.isDir ? .isButton : [])
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk): rows of tiles kept close to square. Values are
    /// sorted biggest first; space for what is not shown (`total` minus the values) is left empty.
    static func squarify(_ values: [Double], in bounds: CGRect, total: Double) -> [CGRect] {
        guard !values.isEmpty, bounds.width > 0, bounds.height > 0 else { return values.map { _ in .zero } }
        let sum = values.reduce(0, +)
        // The shown items fill the share of the box they hold of the folder.
        let share = min(1, max(sum / max(total, sum), 0.05))
        var rect = bounds
        if bounds.width >= bounds.height { rect.size.width *= share } else { rect.size.height *= share }
        let scale = Double(rect.width * rect.height) / sum
        let areas = values.map { $0 * scale }
        var out: [CGRect] = []
        var row: [Double] = []
        var i = 0

        func worst(_ row: [Double], _ side: Double) -> Double {
            let s = row.reduce(0, +)
            guard s > 0, let mx = row.max(), let mn = row.min() else { return .infinity }
            return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
        }
        func layout(_ row: [Double]) {
            let s = row.reduce(0, +)
            if rect.width >= rect.height {
                let w = CGFloat(s) / rect.height
                var y = rect.minY
                for a in row {
                    let h = CGFloat(a) / w
                    out.append(CGRect(x: rect.minX, y: y, width: w, height: h)); y += h
                }
                rect = CGRect(x: rect.minX + w, y: rect.minY, width: max(0, rect.width - w), height: rect.height)
            } else {
                let h = CGFloat(s) / rect.width
                var x = rect.minX
                for a in row {
                    let w = CGFloat(a) / h
                    out.append(CGRect(x: x, y: rect.minY, width: w, height: h)); x += w
                }
                rect = CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: max(0, rect.height - h))
            }
        }
        while i < areas.count {
            let side = Double(min(rect.width, rect.height))
            let a = areas[i]
            if row.isEmpty || worst(row + [a], side) <= worst(row, side) {
                row.append(a); i += 1
            } else {
                layout(row); row = []
            }
        }
        if !row.isEmpty { layout(row) }
        return out
    }
}
