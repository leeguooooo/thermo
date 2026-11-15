import AgentCore
import AppKit
import CleanKit
import Foundation
import ModuleKernelCore
import ModuleKit
import ThermoL10n

/// An owned-fixture UI acceptance host. It uses production broker, rules, confirmation and undo.
@MainActor final class PermissionQA:NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification) {
        L10n.override = .simplifiedChinese
        Task {await run()}
    }
    private func run() async {
        var checks:[String:Any]=[:]
        let root=URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Caches/Thermo-permission-QA-"+UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try Data("Owned Thermo permission UI QA\n".utf8).write(to:root.appendingPathComponent(".owner"))
            for scenario in ["cancel","allow"] {
                let file=root.appendingPathComponent("owned-"+scenario+".txt"),content=Data(("Owned QA "+scenario+"\n").utf8)
                try content.write(to:file)
                let id="com.example.thermo-permission-qa."+scenario
                let manifest=ModuleManifest(id:id,name:"Thermo QA "+scenario,summary:"",symbol:"doc",version:"1.0.0",capabilities:[Capability("files.delete:"+root.path)!])
                let log=ModuleAccessLog(home:root.appendingPathComponent("logs").path)
                let broker=ModuleKernel.broker(for:manifest,log:log,confirm:{request in await ModuleKernel.confirm(request)})
                let answer=await broker.request("files.delete:"+file.path,payload:Data(#"{"op":"trash"}"#.utf8))
                let summary=log.summary(module:id)
                switch answer {
                case let .failure(error):
                    checks[scenario] = ["outcome":error.outcome.rawValue,"message":error.message,"originalExists":FileManager.default.fileExists(atPath:file.path),"declined":summary.declined]
                case .success:
                    guard let record=OperationJournal.readReport(limit:50).records.first(where:{$0.subject==id && $0.items.contains(where:{$0.target==file.path})}),
                          let batch=record.undo?.ref else{throw NSError(domain:"permission-qa",code:1,userInfo:[NSLocalizedDescriptionKey:"No owned undo batch recorded"])}
                    let review=try TrashBatches.restore(id:batch,dryRun:true)
                    guard review.items.count==1,review.items.allSatisfy({$0.original==file.path}),let identity=review.reviewIdentity else{throw NSError(domain:"permission-qa",code:2,userInfo:[NSLocalizedDescriptionKey:"Unexpected undo scope"])}
                    let restored=try TrashBatches.restore(id:batch,reviewIdentity:identity,reviewedDestinations:Set(review.items.filter{$0.status=="restored"}.map(\.destination)))
                    checks[scenario] = ["outcome":"allowed","deletedLog":summary.deleted.contains(file.path),"journalBatch":batch,"restored":restored.items.allSatisfy{$0.status=="restored"},"originalBytesMatch":(try? Data(contentsOf:file))==content]
                }
                if FileManager.default.fileExists(atPath:file.path),try Data(contentsOf:file)==content {try FileManager.default.removeItem(at:file)}
            }
        } catch {checks["error"]=error.localizedDescription}
        let result=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("permission-ui-result.json")
        checks["fixtureRoot"]=root.path
        checks["sourceCommit"]=Bundle.main.object(forInfoDictionaryKey:"ThermoSourceCommit") as? String ?? "unknown"
        try? JSONSerialization.data(withJSONObject:checks,options:[.sortedKeys,.prettyPrinted]).write(to:result)
        let done=NSAlert();done.messageText="Thermo 权限 QA 已结束";done.informativeText=result.path;done.addButton(withTitle:"完成");done.runModal()
        NSApp.terminate(nil)
    }
}
MainActor.assumeIsolated {
    let app=NSApplication.shared
    let delegate=PermissionQA()
    app.delegate=delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate){app.run()}
}
