import AgentDoctor
import AppKit
import SwiftUI
import ThermoL10n

@MainActor final class ClaudeDiagnosticsModel:ObservableObject {
    let work=FeatureTasks()
    @Published private(set) var report:ClaudeLocalReport?
    @Published private(set) var scanning=false
    private let scanLocal:@Sendable ()->ClaudeLocalReport
    init(enabled:@escaping ()->Bool = {true},scan:@escaping @Sendable ()->ClaudeLocalReport = {ClaudeLocalDiagnostics().scan()}) {work.enabled=enabled;scanLocal=scan}
    func scan() {
        guard work.acceptsWork,!scanning else{return};scanning=true
        let scan=scanLocal
        work.run(priority:.userInitiated,onSkipped:{[weak self] in self?.scanning=false}) {
            let result=scan()
            await MainActor.run {
                guard self.work.acceptsWork else{return}
                self.report=result;self.scanning=false
            }
        }
    }
    func stopFeature(){work.stop()}
    func finishFeatureStop() async {await work.finish();report=nil;scanning=false}
}

@MainActor
struct ClaudeLocalDiagnosticsView: View {
    @ObservedObject var model:ClaudeDiagnosticsModel
    private var report:ClaudeLocalReport? {model.report}
    private var scanning:Bool {model.scanning}
    @State private var expanded = false
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: tr("Claude local diagnostics")) {
                Button(scanning ? tr("Checking…") : tr("Check this Mac")) { scan() }
                    .buttonStyle(PillButtonStyle()).disabled(scanning)
            }
            InspectorPanel {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text(tr("Read-only checks of local installation identifiers, telemetry settings and routing configuration. No account login, network probe or identifier reset."))
                        .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    if let report {
                        Text(tr("Some results remain unknown. This report cannot predict account suspension or establish what Claude sends."))
                            .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                        Text(report.generatedAt).font(.caption.monospaced()).foregroundStyle(Theme.textTertiary)
                        HStack {
                            Button(tr("Save redacted report…")) { save(report) }.buttonStyle(PillButtonStyle())
                            Link(tr("Open IP Check"), destination: URL(string: "https://ip-check.leeguoo.com/#local-diagnostics")!)
                        }
                        DisclosureGroup(tr("Inspect results"), isExpanded: $expanded) {
                            VStack(alignment: .leading, spacing: Theme.Space.m) {
                                ForEach(report.checks) { check in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tr(check.title)).font(.headline)
                                        Text(tr(check.status.displayName) + " · " + tr(check.value)).font(Theme.secondary)
                                        Text(check.source).font(.caption.monospaced()).foregroundStyle(Theme.textTertiary)
                                        if !check.note.isEmpty { Text(tr(check.note)).font(Theme.secondary).foregroundStyle(Theme.textSecondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(.top, Theme.Space.s)
                        }
                    }
                    if let exportError { Text(exportError).foregroundStyle(Theme.danger) }
                }.padding(Theme.Space.m)
            }
        }
    }
    private func scan() {exportError=nil;model.scan()}
    private func save(_ report: ClaudeLocalReport) {
        guard model.work.acceptsWork else{return}
        let panel = NSSavePanel(); panel.nameFieldStringValue = "thermo-claude-diagnostics.json"
        guard panel.runModal() == .OK, model.work.acceptsWork, let url = panel.url else { return }
        do {
            try Data(report.json.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { exportError = tr("Could not save the diagnostic report.") }
    }
}
