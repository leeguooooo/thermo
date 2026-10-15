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
    @Published var exitRequested = false
    @Published private(set) var background = BackgroundStartupReport.requiresAuthorization
    @Published private(set) var authorizing = false
    private var generation = UUID()
    private var refreshInFlight = false
    private var restartAfterCurrent = false
    private let read: @Sendable () -> StartupReport
    private let change: @Sendable (Bool, StartupItem) throws -> Void
    private let readBackground: @Sendable () -> BackgroundStartupReport

    init(read: @escaping @Sendable () -> StartupReport = { StartupItems.scan() },
         change: @escaping @Sendable (Bool, StartupItem) throws -> Void = { enabled, item in _ = try StartupItems.setEnabled(enabled, item: item) },
         readBackground: @escaping @Sendable () -> BackgroundStartupReport = { BackgroundStartupItems.readAuthorized() }) {
        self.read = read; self.change = change; self.readBackground = readBackground
    }

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
                if restart { self.refresh(); return }
                guard self.generation == token else {
                    return
                }
                self.report = report
                if let background = report.background, background.status != .requiresAuthorization || self.background.status == .requiresAuthorization { self.background = background }
                self.loading = false
            }
        }
    }

    func retire() { generation = UUID(); restartAfterCurrent = false; loading = false }

    func inspectBackground() {
        guard !busy else { return }
        working = true; authorizing = true; exitRequested = false; message = nil
        let reader = readBackground
        Task.detached(priority: .utility) {
            let result = reader()
            await MainActor.run { self.background = result; self.authorizing = false; self.working = false }
        }
    }

    func apply(_ item: StartupItem) {
        guard !busy, let enabled = item.enabled else { return }
        working = true
        exitRequested = false
        let change = self.change, read = self.read
        Task.detached(priority: .utility) {
            let message: String
            do {
                try change(!enabled, item)
                message = "Startup state verified"
            } catch { message = error.localizedDescription }
            let report = read()
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
    @State private var backgroundReview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Startup items")).font(.system(size: 22, weight: .semibold))
                    Text(tr("User and shared startup items, plus system services")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                SoftwareTabPicker(tab: $tab)
            }
            Text(tr("Changes background startup eligibility; does not stop or start a running program."))
                .font(.callout).foregroundStyle(.secondary)
            if let message = model.message { Text(message).font(.callout).textSelection(.enabled) }
            if model.exitRequested { Text(tr(model.authorizing ? "Wait for the background inspection to finish or cancel authorization." : "Wait for the startup change to finish before quitting.")).font(.callout).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    backgroundItems
                    if let issues = model.report?.issues, !issues.isEmpty {
                        DisclosureGroup(tr("%1$@ startup files or states need review", String(issues.count))) {
                            ForEach(issues, id: \.self) { Text(tr($0)).font(.callout).textSelection(.enabled) }
                        }.font(.callout).foregroundStyle(.orange)
                    }
                    ForEach(model.report?.items ?? []) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "power").foregroundStyle(.indigo).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.label).font(.headline).textSelection(.enabled)
                                Text(item.effectiveScope.title).font(.caption).foregroundStyle(.secondary)
                                if item.requiresAdministrator { Text(tr("Administrator approval required")).font(.caption).foregroundStyle(.secondary) }
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
                        Text(tr("No launch services found. Other login items are managed in System Settings."))
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
                footnote: item.requiresAdministrator ? tr("macOS will request administrator approval. Changes system startup eligibility; running services keep running. You can reverse the change here; History records the result.") : tr("Undo this change here or with thermo apps startup. The change is recorded in History."),
                confirmTitle: item.enabled == true ? tr("Disable") : tr("Enable"),
                confirm: { reviewed = nil; model.apply(item) }, cancel: { reviewed = nil })
        }
        .sheet(isPresented: $backgroundReview) {
            ConfirmSheet(title: tr("Read login and background items?"), summary: tr("Administrator approval reads this Mac's registration data; this view shows the current user and system scope."),
                destructive: false, heading: tr("Read-only system query"), lines: ["/usr/bin/sfltool dumpbtm"],
                footnote: tr("Registration requests and macOS approval are shown separately. Manage switches in System Settings."),
                confirmTitle: tr("Read with approval…"), confirm: { backgroundReview = false; model.inspectBackground() }, cancel: { backgroundReview = false })
        }
    }

    var backgroundItems: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("Login and background registrations")).font(.headline)
                Spacer()
                Button(tr(model.authorizing ? "Reading…" : "Read with approval…")) { backgroundReview = true }
                    .buttonStyle(PillButtonStyle()).disabled(model.busy)
            }
            if model.background.status == .requiresAuthorization {
                Text(tr("Modern registration status needs an explicit administrator read. An unread list is not an empty list.")).font(.callout).foregroundStyle(.secondary)
            }
            if let date = model.background.observedAt { Text(tr("Checked at %1$@", date.formatted(date: .numeric, time: .standard))).font(.caption).foregroundStyle(.secondary) }
            ForEach(model.background.issues, id: \.self) { Text(tr($0)).font(.caption).foregroundStyle(.orange) }
            ForEach(model.background.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.headline)
                    Text(item.identifier ?? item.uuid).font(.caption).textSelection(.enabled)
                    if let path = item.executable ?? item.path { Text(path).font(.caption).textSelection(.enabled) }
                    Text(tr("Requested: %1$@ · Allowed by macOS: %2$@", state(item.requested), state(item.allowed))).font(.caption)
                    Text(item.kind ?? tr("Unknown")).font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).glass(radius: 12)
            }
            if model.background.status == .available && model.background.items.isEmpty { Text(tr("No registrations found in the inspected user and system scope.")).font(.callout).foregroundStyle(.secondary) }
            Text(tr("Registration data is not a running-process status. Use System Settings to manage these entries.")).font(.caption).foregroundStyle(.secondary)
        }.padding(14).glass(radius: 14)
    }
    func state(_ flag: Bool?) -> String { flag.map { $0 ? tr("Yes") : tr("No") } ?? tr("Unknown") }
}
