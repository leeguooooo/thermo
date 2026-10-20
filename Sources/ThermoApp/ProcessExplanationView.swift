import AgentCore
import AgentDoctor
import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

struct ProcessInspectionTarget: Identifiable {
    let identity: ProcessIdentity
    var candidates: [ProcessIdentity] = []
    var id: String { "\(identity.pid):\(identity.started.timeIntervalSince1970)" }
    var choices: [ProcessIdentity] {
        var seen = Set<Int32>()
        return ([identity] + candidates).filter { seen.insert($0.pid).inserted }
    }
}

@MainActor final class ProcessExplanationModel: ObservableObject {
    @Published private(set) var report: ProcessExplanation?
    @Published private(set) var loading = false
    @Published private(set) var problem: String?
    private static let queue = DispatchQueue(label: "dev.thermo.process-explanation", qos: .utility)
    private var token: ScanCancellation?
    private let reader: @Sendable (ProcessIdentity) throws -> ProcessExplanation
    init(reader: @escaping @Sendable (ProcessIdentity) throws -> ProcessExplanation = { try ProcessExplanation.capture($0.pid, expected: $0) }) { self.reader = reader }
    func load(_ expected: ProcessIdentity) {
        guard !loading else { return }
        let token = ScanCancellation(); self.token = token
        loading = true; report = nil; problem = nil
        let read = reader
        Self.queue.async { [weak self] in
            guard !token.isCancelled else { return }
            let result = Result { try read(expected) }
            DispatchQueue.main.async {
                guard let self, self.token === token, !token.isCancelled else { return }
                self.loading = false
                switch result {
                case .success(let report): self.report = report
                case .failure(let error): self.problem = tr(error.localizedDescription)
                }
            }
        }
    }
    func stop() { token?.cancel(); token = nil; loading = false }
}

@MainActor struct ProcessExplanationView: View {
    let target: ProcessInspectionTarget
    @StateObject private var model = ProcessExplanationModel()
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPID: Int32?
    private var expected: ProcessIdentity { target.choices.first { $0.pid == selectedPID } ?? target.identity }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(tr("Why is this running?")).font(Theme.heading).foregroundStyle(Theme.textPrimary)
            if target.choices.count > 1 {
                Picker(tr("Processes from this reading"), selection: Binding(get: { expected.pid }, set: { pid in
                    selectedPID = pid; model.stop(); model.load(expected)
                })) {
                    ForEach(target.choices, id: \.pid) { value in Text("PID \(value.pid) · " + Redact.text((value.executable as NSString).lastPathComponent)).tag(value.pid) }
                }
            }
            Text("PID \(expected.pid) · " + String(reflecting: Redact.text(expected.executable))).font(Theme.caption).textSelection(.enabled)
            if model.loading { ProgressView(tr("Reading process evidence…")) }
            if let problem = model.problem { Text(problem).foregroundStyle(Theme.caution) }
            ScrollView {
                if let report = model.report {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(tr("Observed at %1$@", report.sampled.formatted(date: .omitted, time: .standard))).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        if let application = report.application {
                            Text(tr(report.attribution == .executableLocation ? "Executable located inside: %1$@" : "Observed ancestor application: %1$@", application)).font(Theme.body)
                        } else { Text(tr("No application attribution was established")).font(Theme.body) }
                        Text(tr("A current parent chain does not prove the original launcher or a publisher's identity.")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        ForEach(report.issues, id: \.self) { Text(tr($0)).font(Theme.caption).foregroundStyle(Theme.caution) }
                        Text(tr("Observed parent chain")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary).padding(.top, Theme.Space.s)
                        ForEach(report.chain) { node in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(node.name) · PID \(String(node.pid)) → \(String(node.parentPID)) · UID \(String(node.uid))").font(Theme.rowTitle)
                                Text(node.executable).font(Theme.mono)
                                Text(tr("Started at %1$@", node.started.formatted(date: .abbreviated, time: .standard))).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                if let cwd = node.workingDirectory { Text(tr("Working directory: %1$@", cwd)).font(Theme.caption) }
                                if !node.args.isEmpty { Text(node.args.map { String(reflecting: $0) }.joined(separator: " ")).font(Theme.mono) }
                            }.textSelection(.enabled)
                        }
                        Text(tr("Observed descendant processes")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary).padding(.top, Theme.Space.s)
                        if let descendants=report.descendants {
                            ForEach(descendants.children) { child in
                                VStack(alignment:.leading,spacing:3) {
                                    Text("\(child.name) · PID \(String(child.pid)) → \(String(child.parentPID)) · UID \(String(child.uid))").font(Theme.label)
                                    Text(child.executable).font(Theme.mono)
                                }.padding(.leading,CGFloat(child.depth-1)*12).textSelection(.enabled)
                            }
                            if descendants.state == .noneObserved { Text(tr("No descendants were observed in this process reading.")).font(Theme.caption) }
                            if descendants.state == .unavailable { Text(tr("Descendant relationships are unavailable.")).font(Theme.caption).foregroundStyle(Theme.caution) }
                            if !descendants.queryComplete { Text(tr("The descendant reading is incomplete; some relationships could not be verified.")).font(Theme.caption).foregroundStyle(Theme.caution) }
                            if descendants.limited { Text(tr("The descendant reading reached an inspection limit.")).font(Theme.caption).foregroundStyle(Theme.caution) }
                        } else { Text(tr("Descendant relationships are unavailable.")).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                        Text(tr("Processes can start, exit or change parents after this reading. This tree does not prove the original launcher.")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        Text(tr("Git context near the process working directory")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary).padding(.top, Theme.Space.s)
                        if let git=report.gitContext,git.state == .observed {
                            if let root=git.root { Text(tr("Repository: %1$@",root)).font(Theme.mono).textSelection(.enabled) }
                            if let branch=git.branch { Text(tr("Branch: %1$@",branch)).font(Theme.caption).textSelection(.enabled) }
                            if git.detached == true { Text(tr("Detached HEAD")).font(Theme.caption) }
                            if let commit=git.commit { Text(tr("HEAD: %1$@",commit)).font(Theme.mono).textSelection(.enabled) }
                            if !git.queryComplete { Text(tr("The branch was observed, but its commit could not be established.")).font(Theme.caption).foregroundStyle(Theme.caution) }
                        } else {
                            Text(tr(report.gitContext?.state == .noneObserved ? "No Git marker was observed in the working directory or its inspected parents." : "Git context is unavailable or changed during inspection.")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Text(tr("Working directory metadata does not prove which project the process is using. Git status, remotes and repository scripts are not inspected.")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        Text(tr("Observed cwd and vnode descriptor paths")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary).padding(.top, Theme.Space.s)
                        if let paths = report.observedPaths {
                            if paths.isEmpty { Text(tr("No paths were observed; this does not prove the process has no open files.")).font(Theme.caption) }
                            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in Text(path).font(Theme.mono).textSelection(.enabled) }
                        } else { Text(tr("Path inspection is unavailable for this process")).font(Theme.caption) }
                        Text(tr("Observed TCP listeners")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary).padding(.top, Theme.Space.s)
                        if let listeners = report.listeners {
                            ForEach(listeners.endpoints, id: \.self) { endpoint in
                                Text(endpoint.label + " · " + endpoint.family + " · " + addressKind(endpoint.addressKind)).font(Theme.mono).textSelection(.enabled)
                            }
                            if listeners.state == .noneObserved { Text(tr("No TCP listeners were observed; this does not prove none exist.")).font(Theme.caption) }
                            if listeners.state == .unavailable { Text(tr("TCP listener inspection is unavailable")).font(Theme.caption).foregroundStyle(Theme.caution) }
                            if !listeners.queryComplete { Text(tr("TCP listener reading is incomplete")).font(Theme.caption).foregroundStyle(Theme.caution) }
                            if listeners.limited { Text(tr("TCP listener reading reached a limit")).font(Theme.caption).foregroundStyle(Theme.caution) }
                        } else { Text(tr("TCP listener inspection is unavailable")).font(Theme.caption) }
                        Text(tr("A listening address does not prove internet reachability.")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        Text(tr("Observed process power assertions")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary).padding(.top, Theme.Space.s)
                        if let power = report.sleepAssertions {
                            ForEach(Array(power.assertions.enumerated()), id: \.offset) { _, assertion in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(assertion.type + " · " + tr(assertion.active == true ? "Active request" : assertion.active == false ? "Inactive request" : "Unknown assertion level")).font(Theme.label)
                                    Text(sleepRequest(assertion.request)).font(Theme.caption)
                                    if let name = assertion.name { Text(name).font(Theme.caption).textSelection(.enabled) }
                                }
                            }
                            if power.state == .noneObserved { Text(tr("No process assertions were observed; other mechanisms may still prevent sleep.")).font(Theme.caption) }
                            if power.state == .unavailable { Text(tr("Power assertion inspection is unavailable")).font(Theme.caption).foregroundStyle(Theme.caution) }
                            if !power.queryComplete { Text(tr("Power assertion reading is incomplete")).font(Theme.caption).foregroundStyle(Theme.caution) }
                            if power.limited { Text(tr("Power assertion reading reached a limit")).font(Theme.caption).foregroundStyle(Theme.caution) }
                        } else { Text(tr("Power assertion inspection is unavailable")).font(Theme.caption) }
                        Text(tr("Power requests do not guarantee prevention of lid-close, low-battery or policy-driven sleep.")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        Text(tr("Observed launchd service registrations")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary).padding(.top, Theme.Space.s)
                        if let services = report.launchServices {
                            ForEach(services.registrations, id: \.self) { service in
                                let state = service.serviceState.map { " · \($0)" } ?? ""
                                let summary = "\(service.domain)/\(service.label) · PID \(service.pid)\(state)"
                                Text(summary).font(Theme.mono).textSelection(.enabled)
                            }
                            if !services.queriedDomains.isEmpty { Text(tr("Launchd query scope: %1$@", services.queriedDomains.joined(separator: ", "))).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                            if services.state == .noneObserved { Text(tr("No direct registration was observed in the queried launchd domains.")).font(Theme.caption) }
                            if services.state == .unavailable { Text(tr("Launchd registration inspection is unavailable")).font(Theme.caption).foregroundStyle(Theme.caution) }
                            if !services.queryComplete { Text(tr("Launchd registration reading is incomplete")).font(Theme.caption).foregroundStyle(Theme.caution) }
                        } else { Text(tr("Launchd registration inspection is unavailable")).font(Theme.caption) }
                        Text(tr("A registration does not prove the original launcher. Service attribution uses only the exact PID.")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        Text(tr("Memory mappings were not inspected.")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(tr("Known credential patterns are masked. Custom arguments and assertion names may contain personal data.")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            HStack {
                Button(tr("Refresh")) { model.load(expected) }.buttonStyle(PillButtonStyle()).disabled(model.loading)
                Spacer()
                Button(tr("Close")) { dismiss() }.buttonStyle(PillButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(Theme.Space.xl).frame(width: 600, height: 520)
        .background(Theme.canvas)
        // The same dark look as the window it opens from, whatever the system appearance.
        .preferredColorScheme(.dark)
            .onAppear { model.load(expected) }.onDisappear { model.stop() }
    }
    private func addressKind(_ value: ProcessListeners.Endpoint.AddressKind) -> String {
        switch value {
        case .loopback: return tr("Loopback bind address")
        case .wildcardAddress: return tr("Wildcard bind address")
        case .specifiedAddress: return tr("Specific bind address")
        }
    }
    private func sleepRequest(_ value: ProcessSleepAssertions.Assertion.Request) -> String {
        switch value {
        case .idleSystem: return tr("Idle system sleep request")
        case .idleDisplayAndSystem: return tr("Idle display and system sleep request")
        case .diskIdle: return tr("Disk idle request; not a system sleep block")
        case .systemSleep: return tr("System sleep request; power policy still applies")
        case .other: return tr("Other power assertion; effect not interpreted")
        }
    }
}
