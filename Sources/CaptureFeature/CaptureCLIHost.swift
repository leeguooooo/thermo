import CaptureControlAPI
import CaptureCore
import CaptureScriptCore
import Foundation

/// Process-lifetime history is independent of the currently enabled native session.
@MainActor final class CaptureCLIHost {
    private var reports:[UUID:CaptureCLIReport]=[:]
    private var order:[UUID]=[]
    private var seen=Set<UUID>()
    private var active:UUID?
    private var task:Task<CaptureScriptResult,Error>?
    func cancelActive(){task?.cancel()}
    func handle(_ request:CaptureControlRequest,access:CaptureExecutionAccess) async->CaptureControlResult {
        func reply(_ report:CaptureCLIReport,_ success:Bool = true)->CaptureControlResult{.init(report:report,succeeded:success)}
        func failure(_ message:String)->CaptureControlResult{reply(.init(id:request.id,phase:.failed,issue:message),false)}
        switch request.operation {
        case .actions:
            var values=CaptureAction.allCases.map{CaptureScriptValue.object(["id":.string($0.rawValue),"title":.string($0.title),"scriptSupported":.bool($0.supportsScript)])}
            values.insert(.object(["id":.string("status"),"title":.string("Capture workspace status"),"scriptSupported":.bool(true)]),at:0)
            return reply(.init(phase:.succeeded,result:.init(value:.array(values),logs:[])))
        case .status(let explicit),.cancel(let explicit):
            let cancel:Bool;if case .cancel=request.operation{cancel=true}else{cancel=false}
            guard let id=explicit ?? order.last else {
                return cancel ? failure("A capture request ID is required to cancel."):reply(.init(phase:.idle))
            }
            guard var report=reports[id] else{return reply(.init(id:id,phase:.unknown,issue:"This request is not in this running App's history. Its outcome is unconfirmed; no operation was repeated."),false)}
            if cancel {
                guard explicit != nil else{return failure("An explicit capture request ID is required to cancel.")}
                if request.dryRun{return reply(.init(id:id,phase:.validated))}
                if active==id{report.cancelRequested=true;reports[id]=report;task?.cancel()}
            }
            return reply(report)
        case .run,.action:break
        }
        guard access.canUse() else{return failure("This feature is switched off. Switch on Screenshots and pins in Settings to use it.")}
        let source:String
        switch request.operation {
        case let .run(value):
            guard !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,value.utf8.count<=16384 else{return failure(CaptureScriptFailure.invalidSource.localizedDescription)}
            source=value
        case let .action(raw):
            guard raw=="status" || CaptureAction(rawValue:raw)?.supportsScript == true else{return failure("Unknown action or synchronous capture script API is not available.")}
            guard let data=try? JSONEncoder().encode(raw) else{return failure("Invalid capture action.")}
            source="return thermo.perform("+String(decoding:data,as:UTF8.self)+");"
        default:return failure("Unsupported capture control operation.")
        }
        if request.dryRun{return reply(.init(id:request.id,phase:.validated,result:.init(value:.object(["changesMade":.bool(false),"syntaxChecked":.bool(false)]),logs:[])))}
        guard !seen.contains(request.id) else{return failure("Capture request ID was already received. Query status instead of replaying it.")}
        guard seen.count<100_000 else{return failure("Capture request limit reached; restart Thermo when idle.")}
        seen.insert(request.id)
        guard let workspace=access.workspace() else{return failure("This feature is switched off. Switch on Screenshots and pins in Settings to use it.")}
        guard active==nil,!workspace.scriptRunning,!workspace.nativeScriptBusy,workspace.editorWork.count==0,!workspace.editorWork.hasOperations,!workspace.captureBusy else{return failure("Another capture operation is in progress. No action started.")}
        reports[request.id] = .init(id:request.id,phase:.running);order.append(request.id)
        while order.count>32{reports.removeValue(forKey:order.removeFirst())}
        active=request.id
        let work=Task{try await workspace.executeScript(source,timeout:280)};task=work
        var final:CaptureCLIReport
        do{final = .init(id:request.id,phase:.succeeded,result:try await work.value)}
        catch{final = .init(id:request.id,phase:work.isCancelled || (error as? CaptureScriptFailure) == .cancelled || error is CancellationError ? .cancelled:.failed,issue:captureFailureMessage(error))}
        final.cancelRequested=reports[request.id]?.cancelRequested ?? false
        reports[request.id]=final;active=nil;task=nil
        return reply(final,final.phase == .succeeded)
    }
}
