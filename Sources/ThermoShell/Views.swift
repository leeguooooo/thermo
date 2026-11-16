import SystemServicesAPI
import ModuleKit
import ThermoUI
import CleanKit
import Charts
import SwiftUI
import ThermoKit
import ThermoL10n

struct PopoverView: View {
    @ObservedObject private var modules = ModuleCenter.shared
    @ObservedObject var monitor: SystemPresentation
    @AppStorage(L10n.defaultsKey) private var language = "system"
    @AppStorage(MenuBarPreferences.leftKey) private var menuLeftClick = "panel"
    @AppStorage(MenuBarPreferences.rightKey) private var menuRightClick = "menu"
    var body: some View {
        let _ = L10n.apply(preference: language)
        content.id(language)
    }
    var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if renderingPreview { mainSections } else {
                ScrollView(.vertical) { mainSections }.frame(minHeight: 120, idealHeight: 640, maxHeight: 640)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.s), GridItem(.flexible(), spacing: Theme.Space.s)], spacing: Theme.Space.s) {
                    Group {
                        CleanScreenButton(); AWDLButton(); IdleAwakeButton(); FocusButton()
                        if monitor.snapshot?.battery != nil { BatteryCareButton() }
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).strokeBorder(Theme.hairline))
                }.environment(\.featureRowCompact, true)
            }
            footer
        }
        .padding(Theme.Space.m).frame(width: 372)
        .background(LinearGradient(colors: [Theme.canvas, Theme.canvasDeep], startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark).environment(\.windowSamplingActive, monitor.popoverOpen)
    }
    private var mainSections: some View {
        VStack(alignment: .leading, spacing: 8) {
            if modules.isOn(BuiltinModuleManifests.performance.id) {
                if monitor.iconHidden {
                    Label(tr("The menu bar icon is hidden behind the notch. Hold ⌘ and drag other icons out of the menu bar to make room, or open Thermo from the Dock."), systemImage: "eye.slash")
                        .font(Theme.caption).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { monitor.iconHidden = false }
                }
                if let content = ShellState.shared.nativeFeatures.compactPanel(.init(BuiltinModuleManifests.performance.id,"overview")) { content }
                if monitor.snapshot?.battery != nil || renderingPreview {
                    LidAwakeSwitch(monitor: monitor).padding(Theme.Space.m - 2)
                        .background(RoundedRectangle(cornerRadius: Theme.radius - 1, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius - 1, style: .continuous).strokeBorder(Theme.hairline))
                }
            } else {
                Text(tr("This feature is switched off.")).font(Theme.body).foregroundStyle(Theme.textSecondary)
                Button(tr("Settings")) { MainWindow.show(.settings) }.buttonStyle(PillButtonStyle())
            }
        }
    }
    // MARK: Footer

    var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                PanelButton(title: tr("Open Console"), symbol: "macwindow", prominent: true) { MainWindow.show(.overview) }
                Spacer(minLength: 0)
                ModulePanelLinks()
                shortcut("stethoscope", tr("AI Agent Diagnostics"), .native(.init(BuiltinModuleManifests.agents.id,"home")))
                ForEach(ShellNativeCatalog.catalog.menuEntries.filter{modules.isOn($0.ref.module)}) {entry in
                    if entry.hasContent {
                        Menu{NativeFeatureMenuView(ref:entry.ref,placement:.popover)} label:{Image(systemName:entry.symbol).frame(width:22)}
                            .menuStyle(.borderlessButton).fixedSize().help(tr(entry.title))
                    } else {
                        Button{ShellState.shared.nativeFeatures.activate(entry.ref)} label:{Image(systemName:entry.symbol).frame(width:22)}
                            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr(entry.title))
                    }
                }
                shortcut("clock.arrow.circlepath", tr("History"), .native(.init(BuiltinModuleManifests.history.id,"home")))
                // An icon like its neighbours: with a text button the English row overflowed the 372 pt panel.
                shortcut("slider.horizontal.3", tr("Customize menu bar…"), .settings)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 22) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("Quit Thermo"))
            }
            let left = (MenuClickAction(rawValue: menuLeftClick) ?? .panel).label
            let right = (MenuClickAction(rawValue: menuRightClick) ?? .menu).label
            // When both clicks open this panel the hint says nothing the person does not already see.
            if left != right {
                Text(tr("Left click: %1$@ · Right click: %2$@", left, right))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    func shortcut(_ symbol: String, _ title: String, _ page: MainPage) -> some View {
        Button { MainWindow.show(page) } label: { Image(systemName: symbol).frame(width: 22) }
            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(title).accessibilityLabel(title)
    }
}


struct SettingsView: View {
    @ObservedObject private var installation = AppInstallationMonitor.shared
    @ObservedObject var monitor: SystemPresentation
    @AppStorage(Settings.showInDock) private var showInDock = true
    @AppStorage(Settings.slowdownAlerts) private var slowdownAlerts = true
    @ObservedObject var updates: Updates
    @ObservedObject private var notifications = NotificationAccess.shared
    @ObservedObject private var loginItem = LoginItemAccess.shared
    @AppStorage(MenuBarPreferences.primaryKey) private var menuPrimary = "cpu"
    @AppStorage(MenuBarPreferences.secondaryKey) private var menuSecondary = "none"
    @AppStorage(MenuBarPreferences.presentationKey) private var menuPresentation = "both"
    @AppStorage(MenuBarPreferences.layoutKey) private var menuLayout = "horizontal"
    @AppStorage(MenuBarPreferences.leftKey) private var menuLeft = "panel"
    @AppStorage(MenuBarPreferences.rightKey) private var menuRight = "menu"
    @AppStorage(Settings.interval) private var interval = 2.0
    @AppStorage(Settings.alertsEnabled) private var alertsEnabled = false
    @AppStorage(Settings.alertThreshold) private var alertThreshold = 90.0
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false
    @AppStorage(L10n.defaultsKey) private var language = "system"
    @ObservedObject private var modules = ModuleCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            if installation.needsRestart {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("An update is installed. Restart Thermo to use it.")).font(Theme.heading)
                    Text(tr("Running Thermo %1$@. Saving and recording protections still apply when restarting.", AppInfo.version))
                        .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    Button(tr("Restart Thermo")) { installation.restart() }
                        .buttonStyle(PillButtonStyle(prominent: true)).disabled(installation.restarting)
                    if let issue = installation.issue { Text(issue).foregroundStyle(Theme.caution) }
                }.padding().background(Theme.caution.opacity(0.1)).cornerRadius(Theme.radius)
            }
            section(tr("Features")) {
                Button{MainWindow.show(.features)}label:{
                    HStack(spacing:Theme.Space.m){Image(systemName:"puzzlepiece.extension").frame(width:22);Text(tr("Open Feature Center"));Spacer();Image(systemName:"chevron.right")}
                        .font(Theme.body).foregroundStyle(Theme.textPrimary).padding(Theme.Space.m)
                }.buttonStyle(.plain)
            }
            // Features with their own panel: one group of rows, each opening its panel.
            section(tr("Tools")) {
                CleanScreenButton()
                InspectorDivider(inset: 46)
                IdleAwakeButton()
                InspectorDivider(inset: 46)
                FocusButton()
                InspectorDivider(inset: 46)
                AWDLButton()
                InspectorDivider(inset: 46)
                BatteryCareButton()
                ModuleSettingsControls(center: modules, models: .shared)
            }
            section(tr("General")) {
                row(tr("Language")) {
                    Picker("", selection: $language) {
                        Text(tr("System")).tag("system")
                        ForEach(Language.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .onChange(of: language) { L10n.apply(preference: $0) }
                }
                Group {
                    row(tr("Primary metric")) {
                        Picker(tr("Primary metric"), selection: $menuPrimary) { ForEach(MenuMetric.allCases) { Text($0.label).tag($0.rawValue) } }.labelsHidden()
                    }
                    row(tr("Second metric")) {
                        Picker(tr("Second metric"), selection: $menuSecondary) {
                            Text(tr("No second metric")).tag("none")
                            ForEach(MenuMetric.allCases) { Text($0.label).tag($0.rawValue) }
                        }.labelsHidden()
                    }
                    row(tr("Menu bar shows")) {
                        Picker(tr("Menu bar shows"), selection: $menuPresentation) {
                            Text(tr("Icon and live data")).tag("both")
                            Text(tr("Icon only")).tag("icon")
                            Text(tr("Live data only")).tag("data")
                        }.labelsHidden()
                    }
                    row(tr("Menu bar layout")) {
                        Picker(tr("Menu bar layout"), selection: $menuLayout) {
                            Text(tr("Horizontal")).tag("horizontal")
                            Text(tr("Two lines")).tag("stacked")
                        }.labelsHidden()
                    }
                    row(tr("Left click")) {
                        Picker(tr("Left click"), selection: $menuLeft) {
                            Text(tr("Panel")).tag("panel"); Text(tr("Main console")).tag("console"); Text(tr("Menu")).tag("menu")
                        }.labelsHidden()
                    }
                    row(tr("Right click")) {
                        Picker(tr("Right click"), selection: $menuRight) {
                            Text(tr("Panel")).tag("panel"); Text(tr("Main console")).tag("console"); Text(tr("Menu")).tag("menu")
                        }.labelsHidden()
                    }
                }
                row(tr("Update every")) {
                    Picker("", selection: $interval) {
                        Text(tr("%1$@ s", "0.5")).tag(0.5); Text(tr("%1$@ s", "1")).tag(1.0); Text(tr("%1$@ s", "2")).tag(2.0); Text(tr("%1$@ s", "5")).tag(5.0)
                    }
                    .onChange(of: interval) { _ in monitor.reschedule() }
                }
                row(tr("Fahrenheit")) { Toggle("", isOn: $fahrenheit) }
                row(tr("Show in Dock")) { Toggle("", isOn: $showInDock) }
                row(tr("Launch at login"), last: true) {
                    Toggle("", isOn: Binding(get: { loginItem.requested }, set: { loginItem.setRequested($0) }))
                        .disabled(loginItem.state == .unknown || loginItem.state == .unavailable)
                }
            }
            if loginItem.state == .needsApproval || loginItem.state == .unavailable || loginItem.error != nil {
                statusPanel {
                    if loginItem.state == .needsApproval {
                        HStack {
                            Label(tr("Launch at login is waiting for macOS approval."), systemImage: "hourglass")
                            Spacer(minLength: Theme.Space.s)
                            Button(tr("Open Login Items settings")) { loginItem.openSettings() }
                                .buttonStyle(PillButtonStyle()).controlSize(.small)
                        }
                    } else if loginItem.state == .unavailable {
                        Label(tr("macOS could not find Thermo’s login item. Open the installed app and try again."), systemImage: "exclamationmark.triangle")
                    }
                    if let error = loginItem.error {
                        Text(error).foregroundStyle(Theme.caution).textSelection(.enabled)
                    }
                }
            }
            section(tr("Alerts")) {
                row(tr("Warn me before my Mac gets slow")) {
                    Toggle("", isOn: $slowdownAlerts)
                        .onChange(of: slowdownAlerts) { enabled in if enabled { notifications.request() } }
                }
                row(tr("Alert when hot"), last: !alertsEnabled) {
                    Toggle("", isOn: $alertsEnabled)
                        .onChange(of: alertsEnabled) { on in if on { SystemPresentation.requestNotificationPermission() } }
                }
                if alertsEnabled {
                    // Label on the left, value and stepper on the right, like every other row.
                    row(tr("Threshold"), last: true) {
                        Text(fahrenheit ? tr("%1$@ °F", Settings.thresholdText(alertThreshold, fahrenheit: true)) : tr("%1$@ °C", Settings.thresholdText(alertThreshold, fahrenheit: false)))
                            .font(Theme.figure(.row)).foregroundStyle(Theme.textPrimary).contentTransition(.numericText())
                        Stepper("", value: Binding(
                            get: {
                                let value = Settings.thresholdValue(alertThreshold)
                                return fahrenheit ? value * 9 / 5 + 32 : value
                            },
                            set: { alertThreshold = Settings.thresholdValue(fahrenheit ? ($0 - 32) * 5 / 9 : $0) }
                        ), in: fahrenheit ? 140...221 : 60...105, step: fahrenheit ? 1.8 : 1)
                            .accessibilityValue(Text(Settings.thresholdText(alertThreshold, fahrenheit: fahrenheit)))
                    }
                }
            }
            if slowdownAlerts || alertsEnabled {
                notificationStatus
            }
            section(tr("AI agents")) {
                AgentAccessRow().padding(Theme.Space.l)
            }
            section(tr("System helper")) {
                row(tr("Status: %1$@", helperText), last: true, labelControl: false) {  // the section title already names it
                    if [.running, .notRunning, .needsApproval, .outdated].contains(monitor.helperState) {
                        HStack(spacing: 8) {
                            if monitor.uninstallingHelper || monitor.settingUp {
                                ProgressView().controlSize(.small)
                                Text(tr(monitor.uninstallingHelper ? "Uninstalling…" : "Setting up…")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            }
                            if monitor.helperState != .needsApproval {
                                Button(tr("Reinstall…")) { monitor.installHelperWithPassword() }
                                    .buttonStyle(PillButtonStyle()).controlSize(.small)
                                    .help(tr("Reinstalling keeps fan settings but ends active charging and low-latency sessions."))
                                    .disabled(monitor.helperBusy || monitor.settingUp)
                            }
                            Button(tr("Uninstall")) { monitor.uninstallHelper() }
                                .buttonStyle(PillButtonStyle()).controlSize(.small)
                                .disabled(monitor.helperBusy || monitor.settingUp)
                        }
                    }
                }
            }
            section(tr("About")) {
                if updates.enabled {
                    row(tr("Check for updates automatically")) {
                        Toggle("", isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }))
                    }
                }
                row("Thermo \(AppInfo.version)", labelControl: false) {
                    HStack {
                        if updates.enabled {
                            Button(tr("Check for Updates…")) { updates.checkForUpdates() }
                                .buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small)
                                .disabled(!updates.canCheck)
                                .help(updates.canCheck ? tr("Checks for a newer version of Thermo.") : tr("An update check is temporarily unavailable."))
                        }
                        Button(tr("Quit Thermo")) { NSApp.terminate(nil) }
                            .buttonStyle(PillButtonStyle()).controlSize(.small)
                    }
                }
                row(tr("App package source"), last: true, labelControl: false) {
                    if let commit = AppInfo.buildMetadata.sourceCommit {
                        Text(commit + " · " + tr(AppInfo.workingTreeLabel))
                            .font(Theme.mono).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    } else { Text(tr("Unknown")).font(Theme.secondary).foregroundStyle(Theme.textTertiary) }
                }
            }
        }
        .toggleStyle(.switch)
        .pickerStyle(.menu)
        .onAppear { notifications.refresh(); loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notifications.refresh(); loginItem.refresh()
        }
    }

    @ViewBuilder var notificationStatus: some View {
        statusPanel {
            switch notifications.state {
            case .unknown:
                Label(tr("Checking notification permission…"), systemImage: "hourglass")
            case .unavailable:
                Label(tr("Notifications require an app bundle."), systemImage: "bell.slash")
            case .notRequested:
                Label(tr("Notification permission has not been requested."), systemImage: "bell.badge")
                Button(tr("Allow notifications")) { notifications.request() }
                    .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(notifications.requesting)
            case .denied:
                Label(tr("Notifications are disabled in macOS."), systemImage: "bell.slash")
                Button(tr("Open notification settings")) { notifications.openSettings() }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
            case .bannersDisabled:
                Label(tr("Notifications are authorized, but banners are disabled."), systemImage: "bell")
                Button(tr("Open notification settings")) { notifications.openSettings() }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
            case .allowed:
                Label(tr("macOS has authorized notifications."), systemImage: "checkmark.circle")
            }
            if let error = notifications.error {
                Text(error).foregroundStyle(Theme.caution).textSelection(.enabled)
            }
            if notifications.requesting { ProgressView().controlSize(.small) }
        }
    }

    /// A status note under a group: quiet text, its buttons at hand.
    func statusPanel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) { content() }
            .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
            .glass(radius: Theme.radius)
    }

    /// One group of settings, the way System Settings draws them: a quiet title, then the rows in one panel.
    func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        let rows = content()
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: title)
            InspectorPanel { rows }
        }
    }

    func row<C: View>(_ title: String, last: Bool = false, labelControl: Bool = true, @ViewBuilder _ control: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Text(title).font(Theme.body).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Space.s)
                if labelControl {
                    control().labelsHidden().fixedSize().accessibilityLabel(title)
                } else {
                    control().labelsHidden().fixedSize()
                }
            }
            .padding(.horizontal, Theme.Space.l).frame(minHeight: 44)
            if !last { InspectorDivider(inset: Theme.Space.l) }
        }
    }

    var helperText: String {
        switch monitor.helperState {
        case .running: return tr("running")
        case .notRunning: return tr("not responding")
        case .notInstalled: return tr("not installed")
        case .needsApproval: return tr("waiting for approval")
        case .outdated: return tr("outdated")
        case .unknown: return tr("Checking…")
        }
    }
}
