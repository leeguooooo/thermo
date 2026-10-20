import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

@MainActor
final class AppUpdatesModel: ObservableObject {
    @Published var channel = "homebrew"
    @Published private(set) var report: AppUpdateReport?
    @Published private(set) var loading = false
    @Published private(set) var working = false
    @Published private(set) var result: AppUpdateResult?
    @Published var exitRequested = false
    var busy: Bool { loading || working || AppModels.shared.nativeUpdates.installing }
    private var generation = UUID()
    private var inFlight = false
    private var pending: Bool?
    private let read: @Sendable (Bool) -> AppUpdateReport
    private let install: @Sendable (AppUpdate) -> AppUpdateResult

    init(read: @escaping @Sendable (Bool) -> AppUpdateReport = { AppUpdates.scan(refreshCatalog: $0) },
         install: @escaping @Sendable (AppUpdate) -> AppUpdateResult = { AppUpdates.install($0) }) {
        self.read = read; self.install = install
    }

    func refresh(catalog: Bool = false) {
        guard !working else { return }
        if inFlight { pending = (pending ?? false) || catalog; loading = true; return }
        inFlight = true; loading = true
        let token = UUID(); generation = token
        let read = self.read
        Task.detached(priority: .utility) {
            let report = read(catalog)
            await MainActor.run {
                self.inFlight = false
                let pending = self.pending; self.pending = nil
                if self.generation == token { self.report = report; self.loading = false }
                if let pending { self.refresh(catalog: pending) }
            }
        }
    }

    func retire() { generation = UUID(); pending = nil; loading = false }

    func apply(_ item: AppUpdate) {
        guard !busy, item.blocked == nil else { return }
        working = true; result = nil; exitRequested = false
        let install = self.install, read = self.read
        Task.detached(priority: .utility) {
            let result = install(item)
            let report = read(false)
            await MainActor.run {
                self.result = result; self.report = report; self.working = false
            }
        }
    }
}

struct AppUpdatesPage: View {
    @ObservedObject var model: AppUpdatesModel
    @ObservedObject var native: NativeUpdatesModel
    @Binding var tab: AppsTab
    @State private var reviewed: AppUpdate?
    @State private var showSkipped = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: tr("Software"), subtitle: tr("App updates")) {
                ThermoTabs(selection: $model.channel, options: [("homebrew", "Homebrew"), ("native", tr("Other apps"))],
                           size: .small, label: tr("Update source"))
            } below: {
                SoftwareTabPicker(tab: $tab)
            }
            .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pageTop).padding(.bottom, Theme.Space.l)
            if model.channel == "native" { NativeUpdatesPanel(model: native) }
            else { homebrewContent }
        }
        .onAppear { if model.channel == "homebrew" { model.refresh() } }
        .onChange(of: model.channel) { value in if value == "homebrew", model.report == nil { model.refresh() } }
        .onDisappear { model.retire(); native.retire() }
        .sheet(item: $reviewed) { item in
            ConfirmSheet(title: tr("Update %1$@?", item.name),
                summary: item.installedVersions.joined(separator: ", ") + " → " + item.targetVersion,
                destructive: false, heading: tr("Applications to replace"), lines: item.appPaths,
                footnote: tr("Homebrew runs the installation steps and may update bundled tools. Thermo cannot automatically roll this update back. Quit the app first."),
                confirmTitle: tr("Update"), confirm: { reviewed = nil; model.apply(item) }, cancel: { reviewed = nil })
        }
    }

    var homebrewContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let result = model.result {
                    Text(tr(result.message)).font(Theme.secondary)
                        .foregroundStyle(result.outcome == "succeeded" ? Theme.good : Theme.caution).textSelection(.enabled)
                }
                if model.exitRequested && model.working {
                    Text(tr("Wait for installation and verification to finish before quitting Thermo."))
                        .font(Theme.secondary).foregroundStyle(Theme.caution)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader(title: "Homebrew") {
                        HStack(spacing: Theme.Space.xs) {
                            if let report = model.report {
                                Text((report.catalogRefreshed ? tr("Homebrew catalog refreshed") : tr("Using Homebrew's current metadata; refresh the catalog to check for newer releases"))
                                     + " · " + report.checked.formatted(date: .omitted, time: .shortened))
                                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            }
                            InfoButton(text: tr("Homebrew apps only. App Store and other app updaters are managed separately."))
                        }
                    }
                    ForEach(model.report?.issues ?? [], id: \.self) { Text(tr($0)).font(Theme.secondary).foregroundStyle(Theme.caution) }
                    let items = model.report?.items ?? []
                    if model.report == nil {
                        SkeletonList(rows: 3)
                    } else if items.isEmpty {
                        if let report = model.report, report.issues.isEmpty {
                            InspectorPanel {
                                EmptyState(symbol: "checkmark.circle", title: tr("Homebrew's current metadata lists no supported app updates. This does not check every app on your Mac."))
                            }
                        }
                    } else {
                        RowList(items: items, inset: 44) { item in
                            HStack(alignment: .center, spacing: Theme.Space.m) {
                                Image(systemName: "arrow.down.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.accent).frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(item.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                        Text(item.token).font(Theme.mono).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
                                    }
                                    Text(item.installedVersions.joined(separator: ", ") + " → " + item.targetVersion)
                                        .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                                    if let why = item.blocked { Text(tr(why)).font(Theme.caption).foregroundStyle(Theme.caution) }
                                }
                                Spacer()
                                Button(tr("Update…")) { reviewed = item }.buttonStyle(PillButtonStyle()).controlSize(.small)
                                    .fixedSize().disabled(model.busy || item.blocked != nil)
                            }
                            .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
                            .hoverHighlight()
                        }
                    }
                    if let report = model.report, !report.skipped.isEmpty {
                        DisclosureGroup(isExpanded: $showSkipped) {
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                ForEach(report.skipped.keys.sorted(), id: \.self) { token in
                                    Text(token + ": " + tr(report.skipped[token] ?? "")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                        .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading).textSelection(.enabled)
                                }
                            }.padding(.top, Theme.Space.xs)
                        } label: {
                            Text(tr("Not offered for installation (%1$@)", String(report.skipped.count))).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m).glass()
                    }
                }
                .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.Space.s).padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: Theme.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ActionBar {
                Button(tr("Open App Store updates")) { NSWorkspace.shared.open(URL(string: "macappstore://showUpdates")!) }
                    .buttonStyle(PillButtonStyle())
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if model.working { Text(tr("Installing and verifying…")).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                else {
                    Button(tr("Refresh catalog and check")) { model.refresh(catalog: true) }
                        .buttonStyle(PillButtonStyle()).disabled(model.busy)
                }
            }
        }
    }
}
