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
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Why is this running?")).font(.headline)
            if target.choices.count > 1 {
                Picker(tr("Processes from this reading"), selection: Binding(get: { expected.pid }, set: { pid in
                    selectedPID = pid; model.stop(); model.load(expected)
                })) {
                    ForEach(target.choices, id: \.pid) { value in Text("PID \(value.pid) · " + Redact.text((value.executable as NSString).lastPathComponent)).tag(value.pid) }
                }
            }
            Text("PID \(expected.pid) · " + String(reflecting: Redact.text(expected.executable))).font(.caption).textSelection(.enabled)
            if model.loading { ProgressView(tr("Reading process evidence…")) }
            if let problem = model.problem { Text(problem).foregroundStyle(.orange) }
            ScrollView {
                if let report = model.report {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(tr("Observed at %1$@", report.sampled.formatted(date: .omitted, time: .standard))).font(.caption).foregroundStyle(.secondary)
                        if let application = report.application {
                            Text(tr(report.attribution == .executableLocation ? "Executable located inside: %1$@" : "Observed ancestor application: %1$@", application)).font(.callout)
                        } else { Text(tr("No application attribution was established")).font(.callout) }
                        Text(tr("A current parent chain does not prove the original launcher or a publisher's identity.")).font(.caption).foregroundStyle(.secondary)
                        ForEach(report.issues, id: \.self) { Text(tr($0)).font(.caption).foregroundStyle(.orange) }
                        Text(tr("Observed parent chain")).font(.headline)
                        ForEach(report.chain) { node in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(node.name) · PID \(node.pid) → \(node.parentPID) · UID \(node.uid)").font(.callout.weight(.medium))
                                Text(node.executable).font(.caption.monospaced())
                                Text(tr("Started at %1$@", node.started.formatted(date: .abbreviated, time: .standard))).font(.caption).foregroundStyle(.secondary)
                                if let cwd = node.workingDirectory { Text(tr("Working directory: %1$@", cwd)).font(.caption) }
                                if !node.args.isEmpty { Text(node.args.map { String(reflecting: $0) }.joined(separator: " ")).font(.caption.monospaced()) }
                            }.textSelection(.enabled)
                        }
                        Text(tr("Observed cwd and vnode descriptor paths")).font(.headline)
                        if let paths = report.observedPaths {
                            if paths.isEmpty { Text(tr("No paths were observed; this does not prove the process has no open files.")).font(.caption) }
                            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in Text(path).font(.caption.monospaced()).textSelection(.enabled) }
                        } else { Text(tr("Path inspection is unavailable for this process")).font(.caption) }
                        Text(tr("Observed TCP listeners")).font(.headline)
                        if let listeners = report.listeners {
                            ForEach(listeners.endpoints, id: \.self) { endpoint in
                                Text(endpoint.label + " · " + endpoint.family + " · " + addressKind(endpoint.addressKind)).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if listeners.state == .noneObserved { Text(tr("No TCP listeners were observed; this does not prove none exist.")).font(.caption) }
                            if listeners.state == .unavailable { Text(tr("TCP listener inspection is unavailable")).font(.caption).foregroundStyle(.orange) }
                            if !listeners.queryComplete { Text(tr("TCP listener reading is incomplete")).font(.caption).foregroundStyle(.orange) }
                            if listeners.limited { Text(tr("TCP listener reading reached a limit")).font(.caption).foregroundStyle(.orange) }
                        } else { Text(tr("TCP listener inspection is unavailable")).font(.caption) }
                        Text(tr("A listening address does not prove internet reachability.")).font(.caption).foregroundStyle(.secondary)
                        Text(tr("Observed process power assertions")).font(.headline)
                        if let power = report.sleepAssertions {
                            ForEach(Array(power.assertions.enumerated()), id: \.offset) { _, assertion in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(assertion.type + " · " + tr(assertion.active == true ? "Active request" : assertion.active == false ? "Inactive request" : "Unknown assertion level")).font(.caption.weight(.medium))
                                    Text(sleepRequest(assertion.request)).font(.caption)
                                    if let name = assertion.name { Text(name).font(.caption).textSelection(.enabled) }
                                }
                            }
                            if power.state == .noneObserved { Text(tr("No process assertions were observed; other mechanisms may still prevent sleep.")).font(.caption) }
                            if power.state == .unavailable { Text(tr("Power assertion inspection is unavailable")).font(.caption).foregroundStyle(.orange) }
                            if !power.queryComplete { Text(tr("Power assertion reading is incomplete")).font(.caption).foregroundStyle(.orange) }
                            if power.limited { Text(tr("Power assertion reading reached a limit")).font(.caption).foregroundStyle(.orange) }
                        } else { Text(tr("Power assertion inspection is unavailable")).font(.caption) }
                        Text(tr("Power requests do not guarantee prevention of lid-close, low-battery or policy-driven sleep.")).font(.caption).foregroundStyle(.secondary)
                        Text(tr("Memory mappings and launch service registration were not inspected.")).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(tr("Known credential patterns are masked. Custom arguments and assertion names may contain personal data.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(tr("Refresh")) { model.load(expected) }.disabled(model.loading)
                Spacer(); Button(tr("Close")) { dismiss() }
            }
        }.padding(20).frame(width: 600, height: 520)
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
