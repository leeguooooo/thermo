import AgentCore
import AppKit
import CleanKit
import SwiftUI

enum AppsTab: String, Hashable, CaseIterable {
    case installed, leftovers, startup, updates

    var title: String {
        switch self {
        case .installed: return tr("Apps")
        case .leftovers: return tr("Leftovers")
        case .startup: return tr("Startup items")
        case .updates: return tr("Updates")
        }
    }
}

struct SoftwareTabPicker: View {
    @Binding var tab: AppsTab
    var body: some View {
        Picker(tr("Show"), selection: $tab) {
            ForEach(AppsTab.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 340)
    }
}

/// Installed apps with their files, and data left behind by apps that are gone. Everything removed
/// goes to the Trash after a confirmation that lists every path.
@MainActor
final class AppsModel: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var measured = 0
    @Published private(set) var loading = false
    @Published private(set) var sizeNotice: String?
    @Published private(set) var running: Set<String> = []
    @Published private(set) var orphans: [OrphanData]?
    @Published private(set) var scanningOrphans = false
    @Published var selectedOrphans: Set<String> = []
    @Published var plan: UninstallPlan?
    @Published private(set) var planning: String?
    @Published private(set) var working = false
    @Published var exitRequested = false
    @Published var outcome: String?
    private var cancellation: ScanCancellation?
    private var reviewCancellation: ScanCancellation?
    private let reviewPlan: @Sendable (InstalledApp, [InstalledApp], Bool, ScanCancellation) -> UninstallPlan
    private let remove: @Sendable (UninstallPlan) -> CleanResult
    private var measurementComplete = false

    init(reviewPlan: @escaping @Sendable (InstalledApp, [InstalledApp], Bool, ScanCancellation) -> UninstallPlan = { app, all, removeApp, token in
        AppUninstaller.plan(app, installed: all, removeApp: removeApp, cancellation: token)
    }, remove: @escaping @Sendable (UninstallPlan) -> CleanResult = { AppUninstaller.uninstall($0) }) {
        self.reviewPlan = reviewPlan; self.remove = remove
    }

    var measuring: Bool { loading }
    var totalBytes: Int64 { apps.reduce(0) { $0 + $1.totalBytes } }
    var totalSizeText: String { AppSize.text(totalBytes, state: AppSize.combined(apps.map(\.totalSizeState), bytes: totalBytes)) }

    func load(ifEmpty: Bool = false, exact: Bool = false) {
        guard !working else { return }
        if ifEmpty, measurementComplete || loading { return }
        cancellation?.cancel()
        let token = ScanCancellation()
        cancellation = token
        loading = true
        measurementComplete = false
        measured = 0
        sizeNotice = nil
        Task.detached(priority: .userInitiated) {
            let found = AppUninstaller.installed(cancellation: token)
            guard !token.isCancelled else { return }
            let busy = Self.runningPaths(found)
            await MainActor.run {
                guard self.cancellation === token else { return }
                self.apps = found
                self.running = busy
            }
            let completed = AppUninstaller.measure(found, cancellation: token, budget: exact ? nil : 60) { app in
                Task { @MainActor in
                    guard self.cancellation === token, let i = self.apps.firstIndex(where: { $0.path == app.path }) else { return }
                    self.apps[i] = app
                    self.measured = self.apps.filter { $0.relatedDataState != nil && $0.relatedDataState != .unmeasured }.count
                }
            }
            await MainActor.run {
                guard self.cancellation === token else { return }
                let latest = Dictionary(completed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
                self.apps = self.apps.map { latest[$0.path] ?? $0 }
                self.measured = self.apps.filter { $0.relatedDataState != nil && $0.relatedDataState != .unmeasured }.count
                self.loading = false
                self.measurementComplete = !token.isCancelled
                self.sizeNotice = token.isCancelled ? tr("Some sizes are unfinished. Known bytes are lower bounds; resume a full measurement when ready.") : nil
                self.cancellation = nil
            }
        }
    }

    /// Resume an interrupted inventory on the next appearance, retaining results until then.
    func stopMeasuring() {
        let interrupted = loading
        cancellation?.cancel()
        cancellation = nil
        loading = false
        if interrupted { sizeNotice = tr("Some sizes are unfinished. Known bytes are lower bounds; resume a full measurement when ready.") }
    }

    func retire() {
        stopMeasuring()
        reviewCancellation?.cancel()
        plan = nil
        // Keep planning occupied until the physical read returns; reopening cannot add a worker.
    }

    nonisolated static func runningPaths(_ apps: [InstalledApp]) -> Set<String> {
        let table = ProcessTable.current(.init(cpu: false))
        return Set(apps.filter { AppUninstaller.runningProcess(in: [$0.path], processes: table) != nil }.map(\.path))
    }

    /// Looks the app's files up again and opens the confirmation.
    func review(_ app: InstalledApp, removeApp: Bool = true) {
        guard planning == nil, !working else { return }
        planning = app.path
        let all = apps
        let token = ScanCancellation()
        reviewCancellation = token
        let buildPlan = reviewPlan
        Task.detached(priority: .userInitiated) {
            let plan = token.isCancelled ? nil : buildPlan(app, all, removeApp, token)
            await MainActor.run {
                guard self.reviewCancellation === token else { return }
                self.planning = nil
                self.reviewCancellation = nil
                if !token.isCancelled { self.plan = plan }
            }
        }
    }

    func uninstall(_ plan: UninstallPlan) {
        guard !working else { return }
        stopMeasuring()
        self.plan = nil
        working = true
        exitRequested = false
        let remove = self.remove
        Task.detached(priority: .userInitiated) {
            let result = remove(plan)
            await MainActor.run {
                self.working = false
                self.outcome = Self.summary([result])
                self.apps = Self.afterUninstall(self.apps, appPath: plan.app.path, removed: Set(result.removed),
                                               reviewed: result.removed.isEmpty ? nil : plan.app)
            }
        }
    }

    func scanOrphans() {
        guard !scanningOrphans else { return }
        scanningOrphans = true
        Task.detached(priority: .userInitiated) {
            let installed = AppUninstaller.installed()
            let known = AppUninstaller.knownBundleIDs(installed: installed, processes: ProcessTable.current(.init(cpu: false)))
            let found = AppUninstaller.orphans(known: known, minimumBytes: 1 << 20)
            await MainActor.run {
                self.orphans = found
                self.selectedOrphans.formIntersection(found.map(\.id))
                self.scanningOrphans = false
            }
        }
    }

    var pickedOrphans: [OrphanData] { (orphans ?? []).filter { selectedOrphans.contains($0.id) && $0.blocked == nil } }

    func removeOrphans() {
        let picked = pickedOrphans
        guard !picked.isEmpty else { return }
        working = true
        Task.detached(priority: .userInitiated) {
            let results = AppUninstaller.removeOrphans(picked)
            await MainActor.run {
                self.working = false
                self.outcome = Self.summary(results)
                self.selectedOrphans = []
                self.orphans = Self.afterRemoval(self.orphans ?? [], removed: Set(results.flatMap(\.removed)))
            }
        }
    }

    /// The list after an uninstall, without measuring every app again: the app leaves the list once its
    /// bundle is gone; otherwise it stays, without the files that moved.
    nonisolated static func afterUninstall(_ apps: [InstalledApp], appPath: String, removed: Set<String>, reviewed: InstalledApp? = nil) -> [InstalledApp] {
        if removed.contains(appPath) || !FileManager.default.fileExists(atPath: appPath) {
            return apps.filter { $0.path != appPath }
        }
        return apps.map { app in
            guard app.path == appPath else { return app }
            var app = reviewed?.path == appPath ? reviewed! : app
            app.leftovers.removeAll { removed.contains($0.path) }
            return app
        }
    }

    /// Leftovers after a removal, without searching again: moved folders drop out, emptied entries go.
    nonisolated static func afterRemoval(_ orphans: [OrphanData], removed: Set<String>) -> [OrphanData] {
        orphans.compactMap { o in
            var o = o
            o.items.removeAll { removed.contains($0.path) }
            return o.items.isEmpty ? nil : o
        }
    }

    nonisolated static func summary(_ results: [CleanResult]) -> String {
        let bytes = results.reduce(Int64(0)) { $0 + $1.bytes }
        let failed = results.flatMap { $0.failed.map { FSPath.tilde($0.key) + ": " + $0.value } }
        var text = tr("Moved %1$@ to the Trash (empty it to get the space back)", AppSize.text(bytes, state: results.contains { $0.bytesIncomplete == true } ? .incomplete : .complete))
        if !failed.isEmpty { text += "\n" + tr("Not moved:") + "\n" + failed.prefix(6).joined(separator: "\n") }
        return text
    }
}

struct AppsPage: View {
    @ObservedObject var model: AppsModel
    let startup: StartupItemsModel
    let updates: AppUpdatesModel
    let native: NativeUpdatesModel
    @Binding var tab: AppsTab
    @State private var search = ""
    @State private var open: Set<String> = []
    @State private var confirmingOrphans = false

    var body: some View {
        Group {
            if tab == .startup { StartupItemsPage(model: startup, tab: $tab) }
            else if tab == .updates { AppUpdatesPage(model: updates, native: native, tab: $tab) }
            else { uninstallBody }
        }
    }

    var uninstallBody: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 14)
            if model.exitRequested && model.working {
                Text(tr("Wait for the app removal operation to finish before quitting."))
                    .font(.callout).foregroundStyle(.orange).padding(.horizontal, 28)
            }
            if let notice = model.sizeNotice {
                Text(notice).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.bottom, 10)
            }
            if let outcome = model.outcome {
                HStack(alignment: .top) {
                    Label(outcome, systemImage: "trash").font(.callout).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                    Spacer()
                    Button { model.outcome = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        .accessibilityLabel(tr("Dismiss")).help(tr("Dismiss"))
                }
                .padding(12).glass(radius: 12).padding(.horizontal, 28).padding(.bottom, 10)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if tab == .installed { installedList } else { leftoverList }
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
            }
            footer
        }
        .onAppear {
            model.load(ifEmpty: true)
            if tab == .leftovers, model.orphans == nil { model.scanOrphans() }
        }
        .onChange(of: tab) { t in if t == .leftovers, model.orphans == nil { model.scanOrphans() } }
        .sheet(item: Binding(get: { model.plan.map(PlanBox.init) }, set: { if $0 == nil { model.plan = nil } })) { box in
            let p = box.plan
            ConfirmSheet(title: p.removesApp ? tr("Uninstall %1$@?", p.app.name) : tr("Remove associated data for %1$@?", p.app.name),
                         summary: p.removesApp ? tr("%1$@ and %2$@ of its files go to the Trash: %3$@ in all.", p.app.name,
                                     String(max(0, p.paths.count - 1)), p.sizeText) : tr("Keep %1$@. Move only the selected associated files to the Trash: %2$@.", p.app.name, p.sizeText),
                         destructive: false, heading: tr("What will be moved to the Trash"),
                         lines: Self.lines(p),
                         retainedLines: Self.retainedLines(p), detailLines: Self.detailLines(p),
                         footnote: p.blocked ?? (p.removesApp ? tr("You can put them back from the Trash. Moves are listed in ~/Library/Logs/Thermo/clean.log.") : tr("Removing selected data can reset settings or sign-in state. Restore it from History before reopening the app.")),
                         confirmTitle: tr("Move to Trash"),
                         confirmEnabled: p.blocked == nil,
                         confirm: { model.uninstall(p) }, cancel: { model.plan = nil })
        }
        .sheet(isPresented: $confirmingOrphans) {
            let picked = model.pickedOrphans
            ConfirmSheet(title: tr("Remove data of %1$@ deleted apps?", String(picked.count)),
                         summary: tr("%1$@ goes to the Trash. Each one is checked again first: still not installed, not running, untouched for 30 days.",
                                     orphanSize(picked)),
                         destructive: false, heading: tr("What will be moved to the Trash"),
                         lines: picked.flatMap { o in o.items.map { $0.sizeText + "  " + FSPath.tilde($0.path) } },
                         footnote: tr("You can put them back from the Trash. Moves are listed in ~/Library/Logs/Thermo/clean.log."),
                         confirmTitle: tr("Move to Trash"),
                         confirm: { confirmingOrphans = false; model.removeOrphans() }, cancel: { confirmingOrphans = false })
        }
    }

    struct PlanBox: Identifiable { let plan: UninstallPlan; var id: String { plan.app.path } }

    static func lines(_ p: UninstallPlan) -> [String] {
        var out = p.removesApp ? [p.app.bundleSizeText + "  " + p.app.path] : []
        out += p.app.leftovers.filter { p.paths.contains($0.path) }.map { $0.sizeText + "  " + FSPath.tilde($0.path) }
        return out
    }

    static func retainedLines(_ p: UninstallPlan) -> [String] {
        var out = p.removesApp ? [] : [tr("App kept: %1$@", FSPath.tilde(p.app.path))]
        if let kept = p.ownershipKept, !kept.isEmpty {
            out.append(tr("Kept: shared data or ownership could not be established"))
            out += kept.map { FSPath.tilde($0) }
        }
        if let kept = p.kept, !kept.isEmpty {
            out.append(tr("Personal data kept"))
            out += kept.map { $0.sizeText + "  " + FSPath.tilde($0.path) }
        }
        if let kept = p.whitelisted, !kept.isEmpty {
            out.append(tr("Kept, whitelisted:"))
            out += kept.map { FSPath.tilde($0) }
        }
        return out
    }

    static func detailLines(_ p: UninstallPlan) -> [String] {
        var out: [String] = []
        if let issues = p.ownership?.issues, !issues.isEmpty {
            out.append(tr("Ownership could not be checked at:"))
            out += issues.map { FSPath.tilde($0) }
        }
        if p.kept?.isEmpty == false {
            out.append(p.removesApp ? tr("Kept, your data (profiles, chat history, mail); remove it in the app first, or with thermo apps uninstall --with-data:") : tr("Personal data kept. To include it while keeping the app, review thermo apps uninstall NAME --data-only --with-data --dry-run first."))
        }
        if p.removesApp, let cask = p.app.cask { out.append(tr("Homebrew installed it: run brew uninstall --cask %1$@ afterwards so Homebrew forgets it.", cask)) }
        if !p.receipts.isEmpty { out.append(tr("Installed by a package (%1$@); files it put outside your home folder stay.", p.receipts.joined(separator: ", "))) }
        return out
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IconTile(symbol: "square.grid.2x2.fill", color: .indigo, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Software")).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer()
                if tab == .installed {
                    TextField(tr("Search"), text: $search).textFieldStyle(.roundedBorder).frame(width: 150)
                        .accessibilityLabel(tr("Search"))
                }
            }
            SoftwareTabPicker(tab: $tab)
        }
    }

    var subtitle: String {
        switch tab {
        case .installed:
            if model.apps.isEmpty { return tr("Looking…") }
            let base = tr("%1$@ apps · %2$@ with their files", String(model.apps.count), model.totalSizeText)
            return model.measuring ? base + " · " + tr("measuring %1$@ of %2$@", String(model.measured), String(model.apps.count)) : base
        case .leftovers:
            guard let o = model.orphans else { return tr("Looking for data of apps that are gone…") }
            return tr("%1$@ in %2$@ apps that are gone", orphanSize(o), String(o.count))
        case .startup: return tr("Startup items")
        case .updates: return tr("Updates")
        }
    }

    var filtered: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = q.isEmpty ? model.apps : model.apps.filter { ($0.name + " " + ($0.bundleID ?? "")).localizedCaseInsensitiveContains(q) }
        return list.sorted { $0.totalBytes > $1.totalBytes }
    }

    func orphanSize(_ items: [OrphanData]) -> String {
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        return AppSize.text(bytes, state: AppSize.combined(items.map(\.sizeState), bytes: bytes))
    }

    @ViewBuilder var installedList: some View {
        let list = filtered
        ForEach(list) { appCard($0) }
        if list.isEmpty {
            Text(model.loading ? tr("Looking…") : tr("No matching items")).foregroundStyle(.secondary).padding(.top, 30)
        }
    }

    func appCard(_ a: InstalledApp) -> some View {
        let expanded = open.contains(a.path)
        let running = model.running.contains(a.path)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(a.name).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        if let v = a.version { Text(v).font(.caption).foregroundStyle(.white.opacity(0.45)).lineLimit(1) }
                        if a.protected != nil { tag(tr("Protected"), .gray) }
                        if running { tag(tr("Running"), .orange) }
                        if a.cask != nil { tag("Homebrew", .yellow) }
                    }
                    Text(a.protected ?? detail(a)).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(a.totalSizeText)
                        .font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                    if a.leftoverBytes > 0 {
                        Text(tr("%1$@ of files", AppSize.text(a.leftoverBytes, state: a.leftoverSizeState))).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                    }
                }
                Button(model.planning == a.path ? tr("Looking…") : tr("Uninstall…")) { model.review(a) }
                    .buttonStyle(PillButtonStyle())
                    .disabled(a.protected != nil || running || model.working || model.planning != nil)
                    .help(a.protected ?? (running ? tr("%1$@ is running; quit it first", a.name) : tr("Lists every file first")))
                Button { toggle(a.path) } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).accessibilityLabel(tr("Details for %1$@", a.name))
                .accessibilityValue(expanded ? tr("Expanded") : tr("Collapsed"))
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(a.path) }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    pathRow(a.path, a.bytes, state: a.bundleSizeState)
                    ForEach(a.leftovers, id: \.path) { pathRow($0.path, $0.bytes, state: $0.effectiveSizeState) }
                    if a.leftovers.isEmpty && a.relatedDataState == .complete {
                        Text(tr("No files of it found in your home folder.")).font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                    Button(tr("Review data only…")) { model.review(a, removeApp: false) }
                        .buttonStyle(PillButtonStyle())
                        .disabled(a.protected != nil || running || model.working || model.planning != nil)
                }
            }
        }
        .padding(14)
        .glass(radius: 14)
        .contextMenu {
            Button(tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)]) }
            if let id = a.bundleID {
                Button(tr("Copy ID")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string) }
            }
        }
    }

    func detail(_ a: InstalledApp) -> String {
        [a.bundleID, FSPath.tilde((a.path as NSString).deletingLastPathComponent)].compactMap { $0 }.joined(separator: " · ")
    }

    func toggle(_ id: String) { if open.contains(id) { open.remove(id) } else { open.insert(id) } }

    func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(color.opacity(0.18)))
    }

    func pathRow(_ path: String, _ bytes: Int64, state: AppSizeState = .complete) -> some View {
        HStack {
            Text(FSPath.tilde(path)).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.75)).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Text(AppSize.text(bytes, state: state)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder var leftoverList: some View {
        if let orphans = model.orphans {
            Text(tr("Data of apps that are no longer installed: not running, untouched for 30 days, and Spotlight knows no app with that ID."))
                .font(.caption).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            ForEach(orphans) { orphanCard($0) }
            if orphans.isEmpty {
                Label(tr("No data left behind by deleted apps."), systemImage: "checkmark.circle").foregroundStyle(.secondary).padding(.top, 30)
            }
        } else {
            Label(tr("Looking…"), systemImage: "hourglass").foregroundStyle(.secondary).padding(.top, 30)
        }
    }

    func orphanCard(_ o: OrphanData) -> some View {
        let ticked = model.selectedOrphans.contains(o.id)
        let expanded = open.contains(o.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { if ticked { model.selectedOrphans.remove(o.id) } else { model.selectedOrphans.insert(o.id) } } label: {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle").font(.title3)
                        .foregroundStyle(ticked ? Color.indigo : .white.opacity(0.5)).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(model.working || o.blocked != nil)
                .accessibilityLabel(tr("Select %1$@", o.bundleID))
                .accessibilityValue(ticked ? tr("Selected") : tr("Not selected"))
                VStack(alignment: .leading, spacing: 3) {
                    Text(o.bundleID).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    Text(o.blocked ?? [trCount(o.items.count, "%1$@ place", "%1$@ places"), o.lastUsed.map { tr("last changed %1$@", AgeFormat.string($0)) }]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Text(o.sizeText).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                Button { toggle(o.id) } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).accessibilityLabel(tr("Details for %1$@", o.bundleID))
                .accessibilityValue(expanded ? tr("Expanded") : tr("Collapsed"))
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(o.id) }
            if expanded {
                if let why = o.blocked { Text(why).font(.caption).foregroundStyle(.orange) }
                VStack(alignment: .leading, spacing: 4) { ForEach(o.items, id: \.path) { pathRow($0.path, $0.bytes, state: $0.effectiveSizeState) } }
            }
        }
        .padding(14)
        .glass(radius: 14, highlighted: ticked)
    }

    var footer: some View {
        HStack(spacing: 10) {
            if tab == .installed {
                if model.measuring || model.working {
                    ProgressView().controlSize(.small)
                    Text(model.working ? tr("Moving to the Trash…") : tr("measuring %1$@ of %2$@", String(model.measured), String(model.apps.count)))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(tr("Running apps, macOS apps, password managers, VPNs and input methods cannot be uninstalled here."))
                        .font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                }
                Spacer()
                if model.loading {
                    Button(tr("Stop")) { model.stopMeasuring() }.buttonStyle(PillButtonStyle())
                } else if model.apps.contains(where: { $0.totalSizeState != .complete }) {
                    Button(tr("Complete size measurement")) { model.load(exact: true) }.buttonStyle(PillButtonStyle()).disabled(model.working)
                }
                Button(tr("Scan again")) { model.load() }.buttonStyle(PillButtonStyle()).disabled(model.loading || model.working)
            } else {
                if model.scanningOrphans || model.working { ProgressView().controlSize(.small) }
                Button(tr("All")) { model.selectedOrphans = Set((model.orphans ?? []).filter { $0.blocked == nil }.map(\.id)) }
                    .buttonStyle(PillButtonStyle()).disabled((model.orphans ?? []).allSatisfy { $0.blocked != nil } || model.working)
                Button(tr("None")) { model.selectedOrphans = [] }.buttonStyle(PillButtonStyle()).disabled(model.selectedOrphans.isEmpty)
                Button(tr("Scan again")) { model.scanOrphans() }.buttonStyle(PillButtonStyle()).disabled(model.scanningOrphans || model.working)
                Spacer()
                Button(tr("Move %1$@ to Trash", orphanSize(model.pickedOrphans))) { confirmingOrphans = true }
                    .buttonStyle(PillButtonStyle(prominent: true, color: .indigo))
                    .disabled(model.pickedOrphans.isEmpty || model.working || model.scanningOrphans)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(Color.black.opacity(0.18))
    }
}
