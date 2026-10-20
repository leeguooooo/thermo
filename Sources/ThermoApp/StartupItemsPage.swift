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
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: tr("Software"), subtitle: tr("User and shared startup items, plus system services")) {
                EmptyView()
            } below: {
                SoftwareTabPicker(tab: $tab)
            }
            .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pageTop).padding(.bottom, Theme.Space.l)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let message = model.message { NoticeBanner(text: message) }
                if model.exitRequested {
                    Text(tr(model.authorizing ? "Wait for the background inspection to finish or cancel authorization." : "Wait for the startup change to finish before quitting."))
                        .font(Theme.secondary).foregroundStyle(Theme.caution)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    launchServices
                    backgroundItems
                }
                .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.Space.s).padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: Theme.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ActionBar {
                Button(tr("Open Login Items")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }.buttonStyle(PillButtonStyle())
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(tr("Refresh")) { model.refresh() }.buttonStyle(PillButtonStyle()).disabled(model.busy)
            }
        }
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

    /// Launch agents and daemons Thermo can switch on or off, one row each.
    var launchServices: some View {
        let items = model.report?.items ?? []
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: tr("Startup items")) {
                HStack(spacing: Theme.Space.xs) {
                    if model.report != nil {
                        Text(String(items.count)).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                    InfoButton(text: tr("Changes background startup eligibility; does not stop or start a running program."))
                }
            }
            if let issues = model.report?.issues, !issues.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(issues, id: \.self) { Text(tr($0)).font(Theme.caption).foregroundStyle(Theme.textSecondary).textSelection(.enabled) }
                    }.padding(.top, Theme.Space.xs)
                } label: {
                    Label(tr("%1$@ startup files or states need review", String(issues.count)), systemImage: "exclamationmark.triangle")
                        .font(Theme.secondary).foregroundStyle(Theme.caution)
                }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.caution.opacity(0.07)))
            }
            if model.report == nil {
                SkeletonList(rows: 4)
            } else if items.isEmpty {
                InspectorPanel { EmptyState(symbol: "power", title: tr("No launch services found. Other login items are managed in System Settings.")) }
            } else {
                RowList(items: items, inset: 44) { item in
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                        Image(systemName: "power").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(item.enabled == true ? Theme.good : Theme.textTertiary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.label).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1).textSelection(.enabled)
                                StatusTag(text: item.enabled.map { $0 ? tr("Enabled") : tr("Disabled") } ?? tr("Unknown"),
                                          color: item.enabled == true ? Theme.good : Theme.textSecondary)
                                if item.requiresAdministrator { StatusTag(text: tr("Administrator approval required")) }
                            }
                            Text(item.effectiveScope.title + " · " + (item.program ?? item.path))
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled).help(item.program ?? item.path)
                            if let why = item.blocked { Text(tr(why)).font(Theme.caption).foregroundStyle(Theme.caution) }
                        }
                        Spacer(minLength: Theme.Space.s)
                        Button(item.enabled == true ? tr("Disable…") : tr("Enable…")) { reviewed = item }
                            .buttonStyle(PillButtonStyle()).controlSize(.small)
                            .disabled(model.busy || item.blocked != nil || item.enabled == nil)
                    }
                    .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
                    .hoverHighlight()
                }
            }
        }
    }

    var backgroundItems: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: tr("Login and background registrations")) {
                HStack(spacing: Theme.Space.s) {
                    if let date = model.background.observedAt {
                        Text(tr("Checked at %1$@", date.formatted(date: .numeric, time: .standard)))
                            .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                    InfoButton(text: tr("Registration data is not a running-process status. Use System Settings to manage these entries."))
                    Button(tr(model.authorizing ? "Reading…" : "Read with approval…")) { backgroundReview = true }
                        .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.busy)
                }
            }
            ForEach(model.background.issues, id: \.self) { Text(tr($0)).font(Theme.caption).foregroundStyle(Theme.caution) }
            if model.background.status == .requiresAuthorization {
                InspectorPanel {
                    EmptyState(symbol: "lock", title: tr("Modern registration status needs an explicit administrator read. An unread list is not an empty list."))
                }
            } else if model.background.status == .available && model.background.items.isEmpty {
                InspectorPanel { EmptyState(symbol: "checkmark.circle", title: tr("No registrations found in the inspected user and system scope.")) }
            } else if !model.background.items.isEmpty {
                RowList(items: model.background.items, inset: Theme.Space.m) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            StatusTag(text: item.kind ?? tr("Unknown"))
                            Spacer()
                            Text(tr("Requested: %1$@ · Allowed by macOS: %2$@", state(item.requested), state(item.allowed)))
                                .font(Theme.caption).foregroundStyle(item.allowed == false ? Theme.caution : Theme.textSecondary)
                        }
                        Text(item.identifier ?? item.uuid).font(Theme.mono).foregroundStyle(Theme.textTertiary).lineLimit(1).textSelection(.enabled)
                        if let path = item.executable ?? item.path {
                            Text(path).font(Theme.mono).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    func state(_ flag: Bool?) -> String { flag.map { $0 ? tr("Yes") : tr("No") } ?? tr("Unknown") }
}
