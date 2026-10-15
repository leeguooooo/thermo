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
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("App updates")).font(.system(size: 22, weight: .semibold))
            SoftwareTabPicker(tab: $tab)
            Picker(tr("Update source"), selection: $model.channel) {
                Text("Homebrew").tag("homebrew")
                Text(tr("Other apps")).tag("native")
            }.pickerStyle(.segmented).frame(width: 240)
            if model.channel == "native" { NativeUpdatesPanel(model: native) }
            else { homebrewContent }
        }
        .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 14)
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
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Homebrew apps only. App Store and other app updaters are managed separately."))
                .font(.callout).foregroundStyle(.secondary)
            if let report = model.report {
                Text((report.catalogRefreshed ? tr("Homebrew catalog refreshed") : tr("Using Homebrew's current metadata; refresh the catalog to check for newer releases"))
                     + " · " + report.checked.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result = model.result {
                Text(tr(result.message)).font(.callout).foregroundStyle(result.outcome == "succeeded" ? Color.green : .orange).textSelection(.enabled)
            }
            if model.exitRequested && model.working {
                Text(tr("Wait for installation and verification to finish before quitting Thermo."))
                    .font(.callout).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.report?.issues ?? [], id: \.self) { Text(tr($0)).font(.callout).foregroundStyle(.orange) }
                    ForEach(model.report?.items ?? []) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "arrow.down.circle").foregroundStyle(.indigo).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.name).font(.headline)
                                Text(item.installedVersions.joined(separator: ", ") + " → " + item.targetVersion).font(.callout).monospacedDigit()
                                Text(item.token).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let why = item.blocked { Text(tr(why)).font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                            Button(tr("Update…")) { reviewed = item }.buttonStyle(PillButtonStyle())
                                .fixedSize().disabled(model.busy || item.blocked != nil)
                        }.padding(14).glass(radius: 14)
                    }
                    if let report = model.report, !report.skipped.isEmpty {
                        DisclosureGroup(tr("Not offered for installation (%1$@)", String(report.skipped.count)), isExpanded: $showSkipped) {
                            ForEach(report.skipped.keys.sorted(), id: \.self) { token in
                                Text(token + ": " + tr(report.skipped[token] ?? "")).font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading).textSelection(.enabled)
                            }
                        }
                    }
                    if let report = model.report, report.items.isEmpty, report.issues.isEmpty {
                        Text(tr("Homebrew's current metadata lists no supported app updates. This does not check every app on your Mac."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button(tr("Open App Store updates")) { NSWorkspace.shared.open(URL(string: "macappstore://showUpdates")!) }
                    .buttonStyle(PillButtonStyle())
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if model.working { Text(tr("Installing and verifying…")).font(.caption).foregroundStyle(.secondary) }
                else {
                    Button(tr("Refresh catalog and check")) { model.refresh(catalog: true) }
                        .buttonStyle(PillButtonStyle()).disabled(model.busy)
                }
            }
        }
    }
}
