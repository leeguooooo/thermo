import AppKit
import AgentCore
import CleanKit
import SwiftUI
import ThermoKit
import ThermoL10n

struct AWDLBackend: Sendable {
    var read: @Sendable () async throws -> AWDLSessionState
    var begin: @Sendable (Int,String) async throws -> Void
    var end: @Sendable () async throws -> Void
    var reset: @Sendable () -> Void
    var record: @Sendable (String,String,String?) -> Void = { _,_,_ in }
    var flush: @Sendable () async -> Void = {}
    static func live() -> Self {
        // Dedicated connection: a fan-query timeout must not close this session.
        let client=HelperClient()
        let history=DispatchQueue(label:"dev.thermo.awdl.history",qos:.utility)
        return .init(read:{ try await client.awdlState() },begin:{ try await client.beginAWDL(seconds:$0,sessionID:$1) },
                     end:{ try await client.endAWDL() },reset:{ client.reset() },record:{ action,status,detail in
            let entry=OperationRecord(feature:"network",action:action,items:[.init(target:"awdl0",status:status,detail:detail)])
            history.async { OperationJournal.record(entry) }
        },flush:{ await withCheckedContinuation { continuation in history.async { continuation.resume() } } })
    }
}

@MainActor final class AWDLModel: ObservableObject {
    static let shared=AWDLModel()
    @Published private(set) var state: AWDLSessionState?
    @Published private(set) var busy=false
    @Published private(set) var issue: String?
    @Published private(set) var quitRequested=false
    private var sessionID: String?
    private var viewers=0
    private var poll: Task<Void,Never>?
    private let backend: AWDLBackend
    private let exit: @MainActor () -> Void
    private func failure(_ error: Error) -> String { (error as? FanControlError)?.description ?? error.localizedDescription }
    init(backend: AWDLBackend = .live(),exit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.backend=backend;self.exit=exit
    }
    deinit { poll?.cancel();backend.reset() }
    var needsQuitRecovery: Bool { sessionID != nil }
    var lostSessionConnection: Bool { sessionID != nil && state?.phase == .active && state?.sessionID == sessionID && state?.ownedByCaller == false }
    var canStart: Bool { !busy && sessionID == nil && state?.phase == .idle && state?.interfaceQueryComplete == true && state?.interface != nil }
    var canStop: Bool { !busy && (sessionID != nil || state?.phase == .recovering || state?.phase == .blocked || state?.ownedByCaller == true) }
    func open() { viewers+=1;refresh() }
    func close() { viewers=max(0,viewers-1);updatePolling() }
    func refresh() {
        guard !busy else { return };busy=true;issue=nil
        Task { await readLatest();finish(allowStop:false) }
    }
    func start(seconds: Int) {
        guard canStart,(60...3600).contains(seconds) else { return }
        let id=UUID().uuidString;sessionID=id;busy=true;issue=nil
        Task {
            do { try await backend.begin(seconds,id);backend.record("awdlBegin","done",nil) }
            catch {
                if error is AWDLClientError { sessionID=nil }
                issue=failure(error)
                backend.record("awdlBegin","failed",issue)
            }
            await readLatest();finish(allowStop:true)
        }
    }
    func stop() {
        guard canStop else { return };busy=true;issue=nil
        Task {
            do { try await backend.end() } catch { issue=failure(error);backend.record("awdlRestore","failed",issue) }
            await readLatest();finish(allowStop:false)
        }
    }
    /// Returns true to cancel normal termination while recovery is unconfirmed.
    func requestQuit() -> Bool {
        if quitRequested { return true }
        guard needsQuitRecovery else { return false }
        quitRequested=true
        if !busy { stop() }
        return true
    }
    private func readLatest() async {
        do {
            let value=try await backend.read();state=value
            let previous=sessionID
            if value.phase == .active,value.ownedByCaller { sessionID=value.sessionID }
            else if value.phase == .idle || (value.phase == .active && value.sessionID != sessionID) { sessionID=nil }
            if previous != nil,sessionID == nil { backend.record("awdlRestore","done",value.lastEndReason) }
        } catch { state=nil;issue=failure(error) }
    }
    private func finish(allowStop: Bool) {
        busy=false
        if quitRequested,sessionID == nil {
            busy=true;updatePolling()
            Task { await backend.flush();busy=false;quitRequested=false;exit() }
            return
        }
        if quitRequested,allowStop { stop();return }
        updatePolling()
    }
    private var shouldPoll: Bool {
        sessionID != nil || (viewers > 0 && state.map { $0.phase != .idle } == true)
    }
    private func updatePolling() {
        guard shouldPoll else { poll?.cancel();poll=nil;return }
        guard poll == nil else { return }
        poll=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds:1_000_000_000) } catch { return }
                guard let model=self else { return }
                guard model.shouldPoll else { model.poll=nil;return }
                if !model.busy { model.busy=true;await model.readLatest();model.finish(allowStop:false) }
            }
        }
    }
}

struct AWDLButton: View {
    @State private var showing=false
    @ObservedObject private var model=AWDLModel.shared
    var body: some View {
        Button { showing=true } label: {
            HStack {
                Label(tr("Network low latency"),systemImage:"network")
                if model.needsQuitRecovery { Text(tr(model.state?.phase == .active ? "On" : "Check recovery")).font(.caption).foregroundStyle(.orange) }
            }
        }.sheet(isPresented:$showing) { AWDLPanel(model:model) }
    }
}

struct AWDLPanel: View {
    @ObservedObject var model: AWDLModel
    @Environment(\.dismiss) private var dismiss
    @State private var seconds=300
    var configureHelper: () -> Void = { AppModels.shared.monitor.installHelper() }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Label(tr("Network low latency"),systemImage:"network").font(.title2.weight(.semibold))
            Text(tr("Temporarily pauses AWDL. AirDrop and other peer-to-peer features may be unavailable until the session ends."))
                .font(.callout).foregroundStyle(.secondary)
            Text(tr("The previous interface state is restored when you stop, the time expires or this app disconnects. Recovery must be confirmed before normal exit."))
                .font(.caption).foregroundStyle(.secondary)
            if let state=model.state {
                Text(status(state)).font(.headline)
                if state.phase == .active,let remaining=state.remainingSeconds {
                    Text(tr("Exits in %1$@ seconds",String(remaining))).monospacedDigit()
                }
                if let interface=state.interface {
                    Text(tr(interface.up ? "Observed AWDL interface: up" : "Observed AWDL interface: down")).font(.caption)
                } else { Text(tr(state.interfaceQueryComplete ? "AWDL is not present on this Mac." : "The AWDL interface could not be verified.")).font(.caption).foregroundStyle(.orange) }
                if let error=state.error { Text(tr(error)).font(.caption).foregroundStyle(.orange) }
                if model.lostSessionConnection { Text(tr("The session connection was lost. Its recovery still needs confirmation.")).font(.caption).foregroundStyle(.orange) }
                else if state.phase == .active,!state.ownedByCaller { Text(tr("Another Thermo process is using this mode.")).font(.caption).foregroundStyle(.secondary) }
                if state.phase == .idle,let reason=endedReason(state.lastEndReason) { Text(reason).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(tr("AWDL session state is unknown.")).foregroundStyle(.orange)
                Button(tr("Set up or update Thermo's helper"),action:configureHelper)
            }
            if let issue=model.issue,issue != model.state?.error { Text(tr(issue)).font(.caption).foregroundStyle(.orange) }
            if model.quitRequested {
                Text(tr(model.needsQuitRecovery ? "Waiting for AWDL recovery before quitting. Retry recovery if it remains unconfirmed." : "Finishing exit preparation…"))
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Picker(tr("Duration"),selection:$seconds) {
                    ForEach([60,300,900,1800,3600],id:\.self) { Text(trCount($0/60,"%1$@ minute","%1$@ minutes")).tag($0) }
                }.disabled(!model.canStart).frame(maxWidth:240)
                Spacer()
                Button(tr("Start low latency")) { model.start(seconds:seconds) }.disabled(!model.canStart)
                Button(tr("Stop and restore")) { model.stop() }.disabled(!model.canStop)
            }
            HStack {
                Button(tr("Refresh")) { model.refresh() }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer();Button(tr("Close")) { dismiss() }
            }
        }.padding(24).frame(width:540)
            .onAppear { model.open() }.onDisappear { model.close() }
    }
    private func status(_ state: AWDLSessionState) -> String {
        switch state.phase {
        case .idle: return tr("No low-latency session is active.")
        case .active: return tr(state.interface?.up == false && state.interfaceQueryComplete ? "Low-latency session active" : "Session requested; interface state needs verification")
        case .recovering: return tr("Restoring the previous AWDL state…")
        case .blocked: return tr("AWDL recovery must be checked.")
        }
    }
    private func endedReason(_ reason: String?) -> String? {
        switch reason {
        case "expired": return tr("The session time elapsed; the previous interface state was restored.")
        case "interfaceReplaced": return tr("The original interface changed. The old session ended without changing the new interface.")
        case "bootChanged": return tr("The Mac restarted; the previous session was not resumed.")
        default: return nil
        }
    }
}
