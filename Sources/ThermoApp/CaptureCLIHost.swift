import AgentCore
import CaptureCore
import CaptureScriptCore
import Foundation

/// Bounded, process-lifetime request history. A disconnected client never restarts a mutation.
@MainActor final class CaptureCLIHost {
    static let shared=CaptureCLIHost(workspace:.shared)
    let workspace:CaptureWorkspace
    private var reports:[UUID:CaptureCLIReport]=[:]
    private var order:[UUID]=[]
    private var seen:Set<UUID>=[]
    private var active:UUID?
    private var task:Task<CaptureScriptResult,Error>?
    init(workspace:CaptureWorkspace){self.workspace=workspace}
    func cancelActive(){task?.cancel()}
    func handle(_ request:AppControlRequest) async -> AppControlResponse {
        func reply(_ report:CaptureCLIReport,_ success:Bool=true) -> AppControlResponse {
            do {let data=try JSONEncoder().encode(report);return .init(request:request,succeeded:success,values:["capture":String(decoding:data,as:UTF8.self)],issue:success ? nil : report.issue)}
            catch{return .init(request:request,succeeded:false,issue:error.localizedDescription)}
        }
        func failure(_ text:String)->AppControlResponse{reply(.init(id:request.id,phase:.failed,issue:text),false)}
        switch request.action {
        case "capture.actions":
            guard request.arguments.isEmpty else{return failure("Unexpected capture arguments.")}
            var values=CaptureAction.allCases.map{CaptureScriptValue.object(["id":.string($0.rawValue),"title":.string($0.title),"scriptSupported":.bool($0.supportsScript)])}
            values.insert(.object(["id":.string("status"),"title":.string("Capture workspace status"),"scriptSupported":.bool(true)]),at:0)
            return reply(.init(phase:.succeeded,result:.init(value:.array(values),logs:[])))
        case "capture.status","capture.cancel":
            guard request.arguments.keys.allSatisfy({$0 == "id"}) else{return failure("Unexpected capture arguments.")}
            let id:UUID?
            if let raw=request.arguments["id"] {guard let value=UUID(uuidString:raw) else{return failure("Invalid capture request ID.")};id=value} else{id=order.last}
            guard let id else {
                if request.action == "capture.cancel"{return failure("A capture request ID is required to cancel.")}
                return reply(.init(phase:.idle))
            }
            guard var report=reports[id] else{return reply(.init(id:id,phase:.unknown,issue:"This request is not in this running App's history. Its outcome is unconfirmed; no operation was repeated."),false)}
            if request.action == "capture.cancel" {
                guard request.arguments["id"] != nil else{return failure("An explicit capture request ID is required to cancel.")}
                if request.dryRun{return reply(.init(id:id,phase:.validated))}
                if active == id {report.cancelRequested=true;reports[id]=report;task?.cancel()}
            }
            return reply(report)
        case "capture.run","capture.action":break
        default:return failure("Unsupported capture control operation.")
        }
        let source:String
        if request.action == "capture.run" {
            guard request.arguments.keys.sorted() == ["source"],let value=request.arguments["source"],!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,value.utf8.count<=16384 else{return failure(CaptureScriptFailure.invalidSource.localizedDescription)}
            source=value
        } else {
            guard request.arguments.keys.sorted() == ["action"],let raw=request.arguments["action"],raw == "status" || CaptureAction(rawValue:raw)?.supportsScript == true else{return failure("Unknown action or synchronous capture script API is not available.")}
            guard let data=try? JSONEncoder().encode(raw) else{return failure("Invalid capture action.")}
            source="return thermo.perform("+String(decoding:data,as:UTF8.self)+");"
        }
        if request.dryRun{return reply(.init(id:request.id,phase:.validated,result:.init(value:.object(["changesMade":.bool(false),"syntaxChecked":.bool(false)]),logs:[])))}
        if seen.contains(request.id){return failure("Capture request ID was already received. Query status instead of replaying it.")}
        guard seen.count<100_000 else{return failure("Capture request limit reached; restart Thermo when idle.")}
        seen.insert(request.id)
        guard active == nil,!workspace.scriptRunning,!workspace.captureBusy else{return failure("Another capture operation is in progress. No action started.")}
        reports[request.id] = .init(id:request.id,phase:.running);order.append(request.id)
        while order.count>32 {reports.removeValue(forKey:order.removeFirst())}
        active=request.id
        let work=Task{try await workspace.executeScript(source,timeout:280)};task=work
        var final:CaptureCLIReport
        do{final = .init(id:request.id,phase:.succeeded,result:try await work.value)}
        catch{final = .init(id:request.id,phase:work.isCancelled || (error as? CaptureScriptFailure) == .cancelled || error is CancellationError ? .cancelled : .failed,issue:captureFailureMessage(error))}
        final.cancelRequested=reports[request.id]?.cancelRequested ?? false
        reports[request.id]=final;active=nil;task=nil
        return reply(final,final.phase == .succeeded)
    }
}
