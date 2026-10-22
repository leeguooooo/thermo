import Foundation
import AgentCore
import CaptureScriptCore
import ThermoKit

struct CaptureCommand {
    let app:App
    static func request(rest:[String],args:Args) throws -> AppControlRequest {
        let sub=rest.first ?? "status"
        switch sub {
        case "status","cancel":
            guard rest.count<=2,sub != "cancel" || rest.count == 2 else{throw CLIError("capture cancel requires an explicit request UUID")}
            var values:[String:String]=[:]
            if rest.count == 2 {guard UUID(uuidString:rest[1]) != nil else{throw CLIError("invalid capture request UUID")};values["id"]=rest[1]}
            return .init(action:"capture."+sub,arguments:values,dryRun:args.has("dry-run"))
        case "actions":guard rest.count == 1 else{throw CLIError("capture actions takes no arguments")};return .init(action:"capture.actions")
        case "action":guard rest.count == 2 else{throw CLIError("capture action requires an action ID")};return .init(action:"capture.action",arguments:["action":rest[1]],dryRun:args.has("dry-run"))
        case "run":
            guard rest.count == 1,(args.options["code"] != nil) != (args.options["file"] != nil) else{throw CLIError("capture run requires exactly one of --code or --file")}
            let source:String
            if let code=args.options["code"]{source=code} else {
                let url=URL(fileURLWithPath:args.options["file"]!),values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                guard values.isRegularFile == true,values.isSymbolicLink != true,(values.fileSize ?? Int.max)<=16384,let value=String(data:try Data(contentsOf:url),encoding:.utf8) else{throw CLIError("script file must be a regular UTF-8 file up to 16384 bytes")};source=value
            }
            guard !source.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,source.utf8.count<=16384 else{throw CLIError("script source must contain 1…16384 UTF-8 bytes")}
            return .init(action:"capture.run",arguments:["source":source],dryRun:args.has("dry-run"))
        default:throw CLIError("Run thermo capture --help.")
        }
    }
    func run(_ rest:[String]) throws {
        let request=try Self.request(rest:rest,args:app.args)
        let directory=app.args.options["control-directory"].map{URL(fileURLWithPath:$0)} ?? AppControlTransport.directory
        guard let timeout=Int(app.args.options["timeout"] ?? (["capture.run","capture.action"].contains(request.action) ? "290" : "15")),(1...300).contains(timeout) else{throw CLIError("--timeout must be 1…300 seconds")}
        let trust:LocalControlPeerTrust?
        if let team=CodeSignature.teamIdentifier(){trust=try LocalControlPeerTrust(team:team,developmentExecutable:URL(fileURLWithPath:"/unused-in-production"),role:.app)}else{trust=nil}
        let response:AppControlResponse
        do{response=try AppControlTransport.request(request,directory:directory,timeout:timeout,authorizeServer:{trust?.accepts(auditToken:$0) ?? true})}
        catch{
            let recovery=["capture.run","capture.action"].contains(request.action) ? request.id.uuidString : request.arguments["id"]
            let suffix=recovery.map{"\nCapture request ID: "+$0+". Query capture status with this ID before another run."} ?? ""
            throw CLIError(error.localizedDescription+suffix,exitCode:3)
        }
        guard let encoded=response.values["capture"],let data=encoded.data(using:.utf8) else{
            let issue=response.issue ?? "The App did not return a capture report."
            throw CLIError(issue+(issue.contains("Unsupported App control operation") ? " Start or update a Thermo App build that includes Capture control." : ""),exitCode:3)
        }
        let report=try JSONDecoder().decode(CaptureCLIReport.self,from:data)
        guard report.schema == 1 else{throw CLIError("unsupported capture report schema",exitCode:3)}
        let expected=["capture.run","capture.action"].contains(request.action) ? request.id : request.arguments["id"].flatMap(UUID.init(uuidString:))
        if let expected,report.id != expected{throw CLIError("Capture result ID does not match; query status before another action.",exitCode:3)}
        if app.args.has("json"){print(Export.json(report))}
        else {
            print("capture \(report.phase.rawValue)"+(report.id.map{" · "+$0.uuidString} ?? ""))
            if let result=report.result{for log in result.logs{print(log)};print(Export.json(result.value))}
            if let issue=report.issue{print(issue)}
        }
        guard response.succeeded else{throw CLIError(report.issue ?? "Capture operation did not succeed.",exitCode:report.phase == .cancelled ? 130 : 3)}
    }
}
