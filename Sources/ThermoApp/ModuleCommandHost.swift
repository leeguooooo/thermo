import AgentCore
import Foundation
import ModuleKit

@MainActor enum ModuleCommandHost {
    private static var active = Set<String>()
    static func handle(_ request: AppControlRequest, center: ModuleCenter = .shared) async -> AppControlResponse {
        func reply(_ result: String? = nil, _ issue: String? = nil) -> AppControlResponse {
            .init(request:request,succeeded:issue == nil,values:result.map { ["moduleResult":$0] } ?? [:],issue:issue)
        }
        guard request.arguments.keys.sorted() == ["arguments","command","module"],
              let id = request.arguments["module"],let command = request.arguments["command"],let text = request.arguments["arguments"] else { return reply(nil,"Unexpected module arguments.") }
        guard center.loaded else { return reply(nil,"Modules are not ready yet. No command started.") }
        guard let status = center.statuses.first(where:{$0.manifest.id == id}),status.enabled else { return reply(nil,"The module is switched off or unavailable.") }
        do {
            let catalog = try ModuleCommandCatalog([status.manifest],enabled:{_ in true})
            guard let entry = catalog.entries.first(where:{$0.command.id == command}) else { return reply(nil,"The module did not declare this command.") }
            let arguments = try JSONDecoder().decode([String:ModuleArgument].self,from:Data(text.utf8))
            try entry.validate(arguments)
            if request.dryRun { return reply("{\"validated\":true,\"changesMade\":false}") }
            guard active.insert(id).inserted else { return reply(nil,"Another command is running in this module. No action started.") }
            defer { active.remove(id) }
            let result = try await center.manager.run(id,command:command,arguments:JSONEncoder().encode(arguments))
            guard result.count <= 4*1024*1024 else { return reply(nil,"Module output exceeds 4 MiB. The command may have completed; inspect its activity before another action.") }
            _ = try JSONSerialization.jsonObject(with:result,options:.fragmentsAllowed)
            return reply(String(decoding:result,as:UTF8.self))
        } catch { return reply(nil,String(describing:error)) }
    }
}
