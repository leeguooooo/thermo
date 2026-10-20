import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

enum SpaceTab: String, Hashable, CaseIterable {
    case browse, large, duplicates
}

struct ManualRemovalReview: Identifiable, Sendable {
    let id = UUID()
    let selection: [String: Int64]
    let measured: [String: Int64]
    let incomplete: Set<String>
    let identities: [String: String]
    let required: [String: String]
    let sizeText: String
    let lines: [String]
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

    func removalReview() -> ManualRemovalReview? {
        guard !scanning, !working, !basket.isEmpty else { return nil }
        return ManualRemovalReview(selection: basket,
            measured: basket.filter { sizeState($0.key) != .unavailable && sizeState($0.key) != .unmeasured },
            incomplete: Set(basket.keys.filter { sizeState($0) != .complete }), identities: selectionIdentities,
            required: basket.keys.reduce(into: [String: String]()) { result, path in
                result.merge(selectionRequirements[path] ?? [:]) { first, _ in first }
            }, sizeText: basketSizeText, lines: basketLines)
    }

    func trash(review: ManualRemovalReview? = nil) {
        guard !working else { return }
        guard let current = removalReview() else {
            if review != nil { outcomeIsWarning = true; outcome = tr("Selection changed after review; review the items again.") }
            return
        }
        let frozen = review ?? current
        guard frozen.selection == current.selection, frozen.measured == current.measured,
              frozen.incomplete == current.incomplete, frozen.identities == current.identities, frozen.required == current.required else {
            outcomeIsWarning = true; outcome = tr("Selection changed after review; review the items again."); return
        }
        let picked = frozen.selection, measured = frozen.measured, incomplete = frozen.incomplete
        let identities = frozen.identities, required = frozen.required, remove = self.remove, root = root
        stopDuplicates()
        working = true; exitRequested = false
        let lease = AppExitGuard.beginManualRemoval { self.exitRequested = true }
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
        clearDuplicateSelectionsForNewScan()
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

    private func clearDuplicateSelectionsForNewScan() {
        let selected = Array(selectionRequirements.keys)
        for path in selected {
            basket[path] = nil; selectionIdentities[path] = nil
            selectionRequirements[path] = nil; selectionSizeStates[path] = nil
        }
        if !selected.isEmpty {
            outcomeIsWarning = false
            outcome = tr("%1$@ previous duplicate selections cleared; choose files from the new comparison.", String(selected.count))
        }
    }

    private struct DuplicateChoice {
        let path: String, identity: String, keeper: String, keeperIdentity: String
        let bytes: Int64?
    }

    private func duplicateChoices(in groups: [DuplicateGroup], only path: String? = nil) -> [DuplicateChoice]? {
        guard !findingDuplicates else {
            outcomeIsWarning = true
            outcome = tr("Wait for the duplicate scan to finish before choosing files.")
            return nil
        }
        func changed() {
            outcomeIsWarning = true; outcome = tr("Duplicate comparison changed; compare the files again")
        }
        let currentGroups = Set(duplicates ?? [])
        var choices: [DuplicateChoice] = []
        for group in groups {
            guard currentGroups.contains(group), group.paths.count > 1,
                  let keeper = group.paths.first, let identities = group.reviewIdentities,
                  let retained = identities[keeper] else { changed(); return nil }
            let candidates = path.map { [$0] } ?? Array(group.paths.dropFirst())
            guard candidates.allSatisfy({ $0 != keeper && group.paths.contains($0) }) else { changed(); return nil }
            guard basket[keeper] == nil, !isCovered(keeper), !candidates.contains(where: isCovered) else {
                outcomeIsWarning = true
                outcome = tr("A copy to keep or a containing folder is already selected. Deselect overlapping items before choosing duplicates.")
                return nil
            }
            guard ManualRemoval.reviewIdentity(keeper) == retained else { changed(); return nil }
            for candidate in candidates where refusal(candidate) == nil {
                guard let identity = identities[candidate], ManualRemoval.reviewIdentity(candidate) == identity else { changed(); return nil }
                choices.append(DuplicateChoice(path: candidate, identity: identity, keeper: keeper,
                                               keeperIdentity: retained, bytes: group.privateBytes?[candidate]))
            }
        }
        return choices
    }

    private func applyDuplicateChoices(_ choices: [DuplicateChoice]) {
        if !choices.isEmpty { outcome = nil; outcomeIsWarning = false }
        for choice in choices {
            basket[choice.path] = choice.bytes ?? 0
            selectionIdentities[choice.path] = choice.identity
            selectionRequirements[choice.path] = [choice.keeper: choice.keeperIdentity]
            selectionSizeStates[choice.path] = choice.bytes == nil ? .unavailable : .complete
        }
    }

    /// Review every choice first, including files already selected on another page.
    func pickAllButOldest() {
        guard !working, let choices = duplicateChoices(in: duplicates ?? []) else { return }
        applyDuplicateChoices(choices)
    }

    func toggleDuplicate(_ path: String, group: DuplicateGroup) {
        guard !working else { return }
        if basket[path] != nil { toggle(path, bytes: 0); return }
        guard let choices = duplicateChoices(in: [group], only: path) else { return }
        applyDuplicateChoices(choices)
    }

    func clearBasket() { guard !working else { return }; basket = [:]; selectionIdentities = [:]; selectionRequirements = [:]; selectionSizeStates = [:] }

    /// Whether `path` can be ticked by a select-all: not refused, not inside a picked folder.
    func pickable(_ path: String) -> Bool { refusal(path) == nil && !isCovered(path) }

    /// Picks every listed path that is not picked yet, each through the same checks as one tick.
    func pick(_ files: [(path: String, bytes: Int64)]) {
        guard !working else { return }
        for file in files where basket[file.path] == nil && pickable(file.path) { toggle(file.path, bytes: file.bytes) }
    }

    /// Unpicks every listed path that is picked.
    func unpick(_ paths: [String]) {
        guard !working else { return }
        for path in paths where basket[path] != nil { toggle(path, bytes: 0) }
    }

    /// Picks every copy but the kept one in `group`, with the same review as "Keep the oldest of each".
    func pickAllButOldest(in group: DuplicateGroup) {
        guard !working, let choices = duplicateChoices(in: [group]) else { return }
        applyDuplicateChoices(choices)
    }
}

struct SpacePage: View {
    @ObservedObject var model: SpaceLensModel
    @Binding var tab: SpaceTab
    @State private var confirming: ManualRemovalReview?
    @State private var olderThan = 0

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pageTop).padding(.bottom, Theme.Space.l)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if model.exitRequested && model.working {
                    Text(tr("Wait for the selected files to finish moving before quitting.")).font(Theme.body).foregroundStyle(Theme.caution)
                }
                if let outcome = model.outcome {
                    NoticeBanner(text: outcome, dismiss: { model.outcome = nil })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, model.outcome != nil || (model.exitRequested && model.working) ? Theme.Space.m : 0)
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
        .sheet(item: $confirming) { review in
            ConfirmSheet(title: tr("Move %1$@ to the Trash?", review.sizeText),
                         summary: tr("%1$@ you picked go to the Trash. Each one is checked again first; anything a program has open is skipped.",
                                     trCount(review.selection.count, "%1$@ item", "%1$@ items")),
                         destructive: false, heading: tr("What will be moved to the Trash"), lines: review.lines,
                         footnote: tr("You can put them back from the Trash. Moves are listed in ~/Library/Logs/Thermo/clean.log."),
                         confirmTitle: tr("Move to Trash"),
                         confirm: { confirming = nil; model.trash(review: review) }, cancel: { confirming = nil })
        }
    }

    // MARK: Header and footer

    var header: some View {
        PageHeader(title: tr("Space Lens"), subtitle: subtitle) {
            if let tree = model.tree, !tree.complete {
                Label(tr("Scan incomplete"), systemImage: "exclamationmark.triangle").font(Theme.caption).foregroundStyle(Theme.caution)
                InfoButton(text: tr("Some locations were not fully measured. Sizes and chart areas show only known data."))
            }
        } below: {
            ThermoTabs(selection: $tab, options: [(.browse, tr("Folders")), (.large, tr("Large files")), (.duplicates, tr("Duplicates"))],
                       label: tr("Show"))
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
        ActionBar {
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
                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
            Button(model.basket.isEmpty ? tr("Move to Trash") : tr("Review %1$@…", model.basketSizeText)) { confirming = model.removalReview() }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(model.basket.isEmpty || model.working || model.scanning)
        }
    }

    // MARK: Folders

    @ViewBuilder var browse: some View {
        if let t = model.tree, let f = model.folder {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    // The page's hero: the folder drawn to scale.
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        pathBar(t)
                        Treemap(entries: f.children, parentBytes: f.entry.bytes, picked: Set(model.basket.keys)) { e in
                            if e.isDir { model.open(e.path) }
                        }
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous))
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(f.children.enumerated()), id: \.element.id) { i, e in
                            if i > 0 { InspectorDivider(inset: 72) }
                            entryRow(e, of: f.entry.bytes)
                        }
                        if f.otherCount > 0 {
                            if !f.children.isEmpty { InspectorDivider(inset: 0) }
                            HStack {
                                Text(trCount(f.otherCount, "%1$@ smaller item", "%1$@ smaller items")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                Spacer()
                                Text(ByteFormat.string(f.otherBytes)).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.s)
                        }
                        if f.children.isEmpty && f.otherCount == 0 && f.entry.effectiveSizeState == .complete {
                            EmptyState(symbol: "folder", title: tr("Empty"))
                        }
                    }
                    .glass()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }
                .padding(.horizontal, Theme.pagePadding).padding(.bottom, Theme.Space.xl)
            }
        } else if model.scanning {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous).fill(Theme.surface).frame(height: 220)
                        .overlay(Text(tr("Measuring your home folder once; after that every folder opens at once."))
                            .font(Theme.secondary).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center).padding())
                    SkeletonList(rows: 6)
                }
                .padding(.horizontal, Theme.pagePadding).padding(.bottom, Theme.Space.xl)
            }
        } else {
            EmptyState(symbol: "exclamationmark.triangle", title: tr("This location could not be measured. Check access and scan again."))
                .frame(maxHeight: .infinity)
        }
    }

    func pathBar(_ t: SpaceTree) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xs) {
                if model.path != t.root {
                    Button { model.open((model.path as NSString).deletingLastPathComponent) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).accessibilityLabel(tr("Back")).help(tr("Back"))
                }
                let trail = t.trail(to: model.path)
                ForEach(Array(trail.enumerated()), id: \.element.path) { i, e in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.textTertiary) }
                    Button { model.open(e.path) } label: {
                        Text(i == 0 ? "~" : e.name).font(i == trail.count - 1 ? Theme.sectionTitle : Theme.secondary)
                            .foregroundStyle(i == trail.count - 1 ? Theme.textPrimary : Theme.textSecondary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                Text(model.folder?.entry.sizeText ?? tr("Size unavailable")).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 6).contentTransition(.numericText())
            }
        }
    }

    func entryRow(_ e: SpaceEntry, of total: Int64) -> some View {
        let picked = model.basket[e.path] != nil || model.isCovered(e.path)
        let refusal = model.refusal(e.path)
        let canOpen = e.isDir && model.tree?.folder(e.path) != nil
        return HStack(spacing: Theme.Space.s + 2) {
            tick(e.path, bytes: e.bytes, picked: picked, refusal: refusal, name: e.name)
            Image(nsImage: NSWorkspace.shared.icon(forFile: e.path)).resizable().frame(width: 22, height: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Text([e.isDir ? trCount(e.files, "%1$@ file", "%1$@ files") : nil, e.newest.map { tr("changed %1$@", AgeFormat.string($0)) }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(Theme.accent.opacity(0.8))
                        .frame(width: max(2, g.size.width * CGFloat(Double(e.bytes) / Double(max(total, 1)))))
                }
            }
            .frame(width: 80, height: 4).accessibilityHidden(true)
            Text(e.sizeText).font(Theme.figure(.row, weight: .medium)).foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 76, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textTertiary.opacity(canOpen ? 1 : 0))
                .frame(width: 14).accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.s)
        .background(picked ? Theme.accent.opacity(0.07) : .clear)
        .contentShape(Rectangle())
        .hoverHighlight()
        .onTapGesture { if canOpen { model.open(e.path) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(canOpen ? .isButton : [])
        .contextMenu { pathMenu(e.path) }
    }

    func tick(_ path: String, bytes: Int64, picked: Bool, refusal: String?, name: String, action: (() -> Void)? = nil) -> some View {
        SelectToggle(selected: picked, locked: refusal != nil && !picked, label: tr("Select %1$@", name)) {
            if let action { action() } else { model.toggle(path, bytes: bytes) }
        }
        .disabled(model.working || (model.isCovered(path) && model.basket[path] == nil))
        .help(refusal ?? (picked ? tr("Picked to move to the Trash") : tr("Pick to move to the Trash")))
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
        let files = largeFiles
        let pickable = files.filter { model.basket[$0.path] != nil || model.pickable($0.path) }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    SelectAllButton(title: tr("Large files"), available: pickable.count,
                                    selected: pickable.filter { model.basket[$0.path] != nil }.count,
                                    selectAll: { model.pick(pickable.map { ($0.path, $0.bytes) }) },
                                    clear: { model.unpick(pickable.map(\.path)) })
                        .disabled(model.working)
                    InfoButton(text: tr("Files of 100 MB or more in your home folder."))
                    Spacer()
                    if model.loadingLastOpened { ProgressView().controlSize(.small).accessibilityLabel(tr("Checking last opened dates")) }
                    Picker(tr("Not opened for"), selection: $olderThan) {
                        Text(tr("Any age")).tag(0)
                        Text(tr("Not opened for 3 months")).tag(90)
                        Text(tr("Not opened for a year")).tag(365)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                    .accessibilityLabel(tr("Not opened for"))
                }
                .padding(.horizontal, 2)
                if olderThan > 0 {
                    let unknown = (model.tree?.large ?? []).filter { (model.lastOpened[$0.path] ?? nil) == nil }.count
                    if unknown > 0 {
                        Text(tr("%1$@ files have no known last opened date and are excluded from this filter.", String(unknown)))
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if files.isEmpty {
                    if model.tree == nil { SkeletonList(rows: 6) } else { EmptyState(symbol: "doc", title: tr("No matching items")) }
                } else {
                    RowList(items: files, inset: 76) { largeRow($0) }
                }
            }
            .padding(.horizontal, Theme.pagePadding).padding(.bottom, Theme.Space.xl)
        }
    }

    func largeRow(_ f: LargeFile) -> some View {
        let picked = model.basket[f.path] != nil || model.isCovered(f.path)
        let name = (f.path as NSString).lastPathComponent
        let opened = model.lastOpened[f.path] ?? nil
        return HStack(spacing: Theme.Space.s + 2) {
            tick(f.path, bytes: f.bytes, picked: picked, refusal: model.refusal(f.path), name: name)
            Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 22, height: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Text(FSPath.tilde((f.path as NSString).deletingLastPathComponent)).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.s)
            Text(opened.map { tr("opened %1$@", AgeFormat.string($0)) } ?? tr("changed %1$@", AgeFormat.string(f.modified)))
                .font(Theme.caption).foregroundStyle(Theme.textSecondary).frame(width: 130, alignment: .trailing)
            Text(ByteFormat.string(f.bytes)).font(Theme.figure(.row, weight: .medium)).foregroundStyle(Theme.textPrimary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.s)
        .background(picked ? Theme.accent.opacity(0.07) : .clear)
        .hoverHighlight()
        .contextMenu { pathMenu(f.path) }
    }

    // MARK: Duplicates

    @ViewBuilder var duplicateList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    if let groups = model.duplicates, !groups.isEmpty, !model.findingDuplicates {
                        let copies = groups.flatMap { $0.paths.dropFirst() }
                        SelectAllButton(title: tr("Duplicates"), available: copies.count,
                                        selected: copies.filter { model.basket[$0] != nil }.count,
                                        selectAll: { model.pickAllButOldest() },
                                        clear: { model.unpick(Array(copies)) })
                            .disabled(model.working)
                    } else {
                        Text(tr("Duplicates")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary)
                    }
                    InfoButton(text: tr("Identical files of 1 MB or more in Desktop, Documents, Downloads, Movies, Music and Pictures, compared byte for byte."))
                    Spacer()
                    if model.findingDuplicates {
                        Button(tr(model.stoppingDuplicates ? "Stopping…" : "Stop")) { model.stopDuplicates() }
                            .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.stoppingDuplicates)
                    } else {
                        if let d = model.duplicates, !d.isEmpty {
                            Button(tr("Keep the oldest of each")) { model.pickAllButOldest() }
                                .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.working)
                        }
                        Button(model.duplicates == nil ? tr("Find duplicates") : tr("Look again")) { model.findDuplicates() }
                            .buttonStyle(PillButtonStyle(prominent: model.duplicates == nil)).controlSize(.small).disabled(model.working)
                    }
                }
                .padding(.horizontal, 2)
                if model.findingDuplicates {
                    NoticeBanner(text: model.duplicateProgress.map { p in p.total > 0 ? "\(p.stage) \(p.done)/\(p.total)" : p.stage } ?? tr("Looking…"), busy: true)
                    SkeletonList(rows: 4)
                } else {
                    if model.duplicateStopped {
                        Label(tr("Duplicate scan stopped. Displayed results may be out of date; run it again."), systemImage: "pause.circle")
                            .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    }
                    if let report = model.duplicateReport, !report.complete {
                        Label(tr("Duplicate scan is incomplete. Some locations could not be compared."), systemImage: "exclamationmark.triangle")
                            .font(Theme.secondary).foregroundStyle(Theme.caution)
                        DisclosureGroup(tr("Locations requiring another check")) {
                            ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                                Text(FSPath.tilde(issue.path) + ": " + issue.reason).font(Theme.caption).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                            }
                            if report.omittedIssueCount > 0 {
                                Text(tr("%1$@ additional scan issues were omitted.", String(report.omittedIssueCount))).font(Theme.caption)
                            }
                        }
                        .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    }
                    if let groups = model.duplicates {
                        if groups.isEmpty {
                            if model.duplicateReport?.complete == true && !model.duplicateStopped {
                                EmptyState(symbol: "checkmark.circle", title: tr("No duplicate files found."))
                            } else {
                                EmptyState(symbol: "questionmark.circle", title: tr("No confirmed duplicate groups in this incomplete scan."))
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Text(model.duplicateSizeText).font(Theme.figure(.metric)).foregroundStyle(Theme.textPrimary)
                                    .contentTransition(.numericText())
                                Text(tr("%1$@ could be freed by keeping one copy of each.", model.duplicateSizeText))
                                    .font(Theme.secondary).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            .padding(.horizontal, 2)
                            ForEach(groups) { duplicateCard($0) }
                        }
                    } else {
                        EmptyState(symbol: "doc.on.doc", title: tr("Find duplicates"),
                                   detail: tr("Identical files of 1 MB or more in Desktop, Documents, Downloads, Movies, Music and Pictures, compared byte for byte."))
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding).padding(.bottom, Theme.Space.xl)
        }
    }

    func duplicateCard(_ g: DuplicateGroup) -> some View {
        let copies = Array(g.paths.dropFirst())
        let pickedCount = copies.filter { model.basket[$0] != nil }.count
        return InspectorPanel {
            HStack(spacing: Theme.Space.s) {
                Button {
                    if pickedCount == copies.count { model.unpick(copies) } else { model.pickAllButOldest(in: g) }
                } label: {
                    SelectionBox(state: pickedCount == 0 ? .none : pickedCount >= copies.count ? .all : .some)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(model.working)
                .accessibilityLabel(tr("Select all in %1$@", (g.paths.first.map { ($0 as NSString).lastPathComponent }) ?? ""))
                .accessibilityValue(tr("%1$@ of %2$@ selected", String(pickedCount), String(copies.count)))
                Text((g.paths.first.map { ($0 as NSString).lastPathComponent }) ?? "").font(Theme.rowTitle)
                    .foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(tr("%1$@ copies of %2$@", String(g.paths.count), ByteFormat.string(g.size))).font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.s)
            ForEach(Array(g.paths.enumerated()), id: \.element) { i, p in
                let picked = model.basket[p] != nil || model.isCovered(p)
                InspectorDivider(inset: 46)
                HStack(spacing: Theme.Space.s) {
                    tick(p, bytes: g.privateBytes?[p] ?? 0, picked: picked, refusal: i == 0 ? tr("This copy is kept as the comparison reference") : model.refusal(p), name: (p as NSString).lastPathComponent, action: { model.toggleDuplicate(p, group: g) })
                    Text(FSPath.tilde(p)).font(Theme.mono).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    if i == 0 { StatusTag(text: tr("oldest"), color: Theme.good) }
                    Spacer()
                }
                .padding(.leading, Theme.Space.m + 2 + 16).padding(.trailing, Theme.Space.m + 2).padding(.vertical, 4)
                .background(picked ? Theme.accent.opacity(0.07) : .clear)
                .contextMenu { pathMenu(p) }
            }
        }
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
                Rectangle().fill(Theme.surface)
                ForEach(shown.indices, id: \.self) { i in tile(shown[i], rects[i], index: i) }
            }
        }
    }

    func tile(_ e: SpaceEntry, _ r: CGRect, index: Int) -> some View {
        let hue = e.isDir ? 0.5 + Double(index % 6) * 0.035 : 0.62
        let color = Color(hue: hue, saturation: e.isDir ? 0.55 : 0.2, brightness: 0.55 - Double(index % 3) * 0.06)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(picked.contains(e.path) ? Theme.danger.opacity(0.55) : color)
            if r.width > 54 && r.height > 28 {
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.name).font(Theme.label).lineLimit(1)
                    Text(e.sizeText).font(Theme.caption.monospacedDigit()).opacity(0.7)
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
