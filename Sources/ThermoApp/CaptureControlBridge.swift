import AgentCore
import CaptureFeature
import CaptureScriptCore
import ModuleKit

/// Assembly translation only; signed transport/authentication remains in AppControlHost.
@MainActor enum CaptureControlBridge {
    static func cancelActive(){BuiltinNativeFeatures.capture.makeControl(AppModels.shared.nativeFeatures).cancelActive()}
    static func handle(_ request:AppControlRequest) async->AppControlResponse {
        await handle(request,control:BuiltinNativeFeatures.capture.makeControl(AppModels.shared.nativeFeatures))
    }
    static func handle(_ request:AppControlRequest,control:any CaptureApplicationControl) async->AppControlResponse {
        func encode(_ result:CaptureControlResult)->AppControlResponse {
            do{let data=try JSONEncoder().encode(result.report);return .init(request:request,succeeded:result.succeeded,values:["capture":String(decoding:data,as:UTF8.self)],issue:result.succeeded ? nil:result.report.issue)}
            catch{return .init(request:request,succeeded:false,issue:error.localizedDescription)}
        }
        func failure(_ message:String)->AppControlResponse {
            let report=CaptureCLIReport(id:request.id,phase:.failed,issue:message)
            do{let data=try JSONEncoder().encode(report);return .init(request:request,succeeded:false,values:["capture":String(decoding:data,as:UTF8.self)],issue:message)}
            catch{return .init(request:request,succeeded:false,issue:error.localizedDescription)}
        }
        let operation:CaptureControlRequest.Operation
        switch request.action {
        case "capture.actions":
            guard request.arguments.isEmpty else{return failure("Unexpected capture arguments.")};operation = .actions
        case "capture.status","capture.cancel":
            guard request.arguments.keys.allSatisfy({$0=="id"}) else{return failure("Unexpected capture arguments.")}
            let id:UUID?
            if let raw=request.arguments["id"]{guard let value=UUID(uuidString:raw) else{return failure("Invalid capture request ID.")};id=value}else{id=nil}
            operation=request.action=="capture.status" ? .status(id):.cancel(id)
        case "capture.run":
            guard request.arguments.keys.sorted()==["source"],let source=request.arguments["source"] else{return failure(CaptureScriptFailure.invalidSource.localizedDescription)}
            operation = .run(source)
        case "capture.action":
            guard request.arguments.keys.sorted()==["action"],let name=request.arguments["action"] else{return failure("Unknown action or synchronous capture script API is not available.")}
            operation = .action(name)
        default:return failure("Unsupported capture control operation.")
        }
        return encode(await control.handle(.init(id:request.id,operation:operation,dryRun:request.dryRun)))
    }
}
