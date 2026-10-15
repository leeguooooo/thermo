import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

@MainActor
final class StartupItemsModel: ObservableObject {
    @Published private(set) var report: StartupReport?
    @Published private(set) var loading = false
    @Published private(set) var working = false
    var busy: Bool { loading || working }
    @Published private(set) var message: String?
    private var generation = UUID()
    private var refreshInFlight = false
    private var restartAfterCurrent = false
    private let read: @Sendable () -> StartupReport

    init(read: @escaping @Sendable () -> StartupReport = { StartupItems.scan() }) { self.read = read }

    func refresh() {
        guard !working else { return }
        if refreshInFlight { restartAfterCurrent = true; loading = true; return }
        refreshInFlight = true
        loading = true
        let token = UUID()
        generation = token
        let read = self.read
        Task.detached(priority: .utility) {
            let report = read()
            await MainActor.run {
                self.refreshInFlight = false
                let restart = self.restartAfterCurrent
                self.restartAfterCurrent = false
                guard self.generation == token else {
                    if restart { self.refresh() }
                    return
                }
                self.report = report
                self.loading = false
            }
        }
    }

    func retire() { generation = UUID(); restartAfterCurrent = false; loading = false }

    func apply(_ item: StartupItem) {
        guard !busy, let enabled = item.enabled else { return }
        working = true
        Task.detached(priority: .utility) {
            let message: String
            do {
                _ = try StartupItems.setEnabled(!enabled, item: item)
                message = "Startup state verified"
            } catch { message = error.localizedDescription }
            let report = StartupItems.scan()
            await MainActor.run {
                self.message = tr(message)
                self.report = report
                self.working = false
            }
        }
    }
}

struct StartupItemsPage: View {
    @ObservedObject var model: StartupItemsModel
    @Binding var tab: AppsTab
    @State private var reviewed: StartupItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Startup items")).font(.system(size: 22, weight: .semibold))
                    Text(tr("Your user LaunchAgents")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                SoftwareTabPicker(tab: $tab)
            }
            Text(tr("Changes background startup eligibility; does not stop or start a running program."))
                .font(.callout).foregroundStyle(.secondary)
            if let message = model.message { Text(message).font(.callout).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.report?.issues ?? [], id: \.self) { Text(tr($0)).font(.callout).foregroundStyle(.orange) }
                    ForEach(model.report?.items ?? []) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "power").foregroundStyle(.indigo).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.label).font(.headline).textSelection(.enabled)
                                Text(item.program ?? item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Text(item.enabled.map { $0 ? tr("Enabled") : tr("Disabled") } ?? tr("Unknown"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let why = item.blocked { Text(tr(why)).font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                            Button(item.enabled == true ? tr("Disable…") : tr("Enable…")) { reviewed = item }
                                .buttonStyle(PillButtonStyle()).disabled(model.busy || item.blocked != nil || item.enabled == nil)
                        }.padding(14).glass(radius: 14)
                    }
                    if let report = model.report, report.items.isEmpty {
                        Text(tr("No user LaunchAgents found. Other login items are managed in System Settings."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button(tr("Open Login Items")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }.buttonStyle(PillButtonStyle())
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(tr("Refresh")) { model.refresh() }.buttonStyle(PillButtonStyle()).disabled(model.busy)
            }
        }
        .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 14)
        .onAppear { model.refresh() }.onDisappear { model.retire() }
        .sheet(item: $reviewed) { item in
            ConfirmSheet(title: item.enabled == true ? tr("Disable startup item?") : tr("Enable startup item?"),
                summary: tr("Changes background startup eligibility; does not stop or start a running program."),
                destructive: false, heading: tr("Startup items"), lines: [item.label, item.path],
                footnote: tr("Undo this change here or with thermo apps startup. The change is recorded in History."),
                confirmTitle: item.enabled == true ? tr("Disable") : tr("Enable"),
                confirm: { reviewed = nil; model.apply(item) }, cancel: { reviewed = nil })
        }
    }
}
