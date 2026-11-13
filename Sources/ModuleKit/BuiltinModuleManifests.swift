import Foundation

/// Built-in command declarations are shared by the App, CLI help/validation and MCP tools.
public enum BuiltinModuleManifests {
    private typealias P = ModuleManifest.Command.Parameter
    private static func flag(_ name: String, _ summary: String) -> P { .init(name:name,kind:.boolean,summary:summary) }
    private static let json = flag("json", "Return JSON instead of human-readable text.")
    private static let dryRun = flag("dry-run", "Review what would change without applying changes.")
    private static let yes = flag("yes", "Confirm the reviewed operation. Required for changes without an interactive terminal.")
    private static let budget = P(name:"budget",kind:.string,summary:"Positive time budget in seconds, for example 30 or 0.5.")
    private static let roots = P(name:"root",kind:.path,summary:"Project roots to scan.",repeats:true)
    private static let selectors = P(name:"targets",kind:.string,required:true,summary:"safe, a category or exact item IDs from a reviewed scan.",repeats:true)
    private static let mode = [flag("trash","Move supported items to Trash."), flag("permanent","Permanently remove eligible selected items after confirmation.")]
    private static let scanOptions = [roots,P(name:"older-than",kind:.string,summary:"Retention such as 30, 2w, 6m or 1y."),budget,flag("exact","Measure exact sizes.")]

    public static let disk = ModuleManifest(
        id:"dev.thermo.disk",name:"Disk Cleanup",summary:"Finds caches, leftovers and old files that can go, and removes what you pick.",
        symbol:"sparkles",version:"1.0.0",launch:.onDemand,enabledByDefault:true,
        entries:[.init(id:"scan",kind:.page,title:"Smart Scan",symbol:"sparkles",scene:"disk"),
                 .init(id:"overview",kind:.page,title:"Where the space is",symbol:"chart.pie",scene:"disk:overview")],
        commands:[
            .init(id:"scan",title:"Scan disk cleanup",summary:"Find cleanable categories and item IDs without removing anything.",parameters:
                [P(name:"categories",kind:.string,summary:"Category names or ai.",repeats:true)] + scanOptions +
                [flag("all","Include all categories."),flag("csv","Return CSV."),flag("stream","Return newline-delimited scan events."),json],cli:["clean"]),
            .init(id:"overview",title:"Measure disk space",summary:"Measure where disk space is used within a time budget.",parameters:[budget,flag("stream","Return newline-delimited events."),json],cli:["clean","overview"]),
            .init(id:"run",title:"Clean selected items",summary:"Clean exact selected items with existing protection, confirmation and history rules.",mutates:true,parameters:
                [selectors] + scanOptions + [flag("rescan","Make a new scan instead of using the reviewed cache.")] + mode + [dryRun,yes,json],cli:["clean","run"]),
            .init(id:"plan",title:"Save cleanup plan",summary:"Save a one-shot, time-limited plan for review. Does not clean files.",mutates:true,parameters:
                [selectors,roots,budget,flag("rescan","Create a new scan.")] + mode + [json],cli:["clean","plan"]),
            .init(id:"apply",title:"Apply cleanup plan",summary:"Apply a reviewed plan once. Its file scope and removal mode cannot be changed.",mutates:true,parameters:
                [P(name:"plan",kind:.string,required:true,summary:"Reviewed cleanup plan UUID."),dryRun,yes,json],cli:["clean","apply"]),
            .init(id:"log",title:"Read cleanup history",summary:"Read recorded cleanup operations.",parameters:[flag("all","Include every record."),json],cli:["clean","log"]),
            .init(id:"whitelist",title:"Manage protected paths",summary:"List protected paths, or explicitly add/remove paths from cleanup protection.",mutates:true,parameters:
                [P(name:"action",kind:.string,summary:"list, add or remove; defaults to list."),P(name:"paths",kind:.path,summary:"Paths to protect or unprotect.",repeats:true),dryRun,json],cli:["clean","whitelist"]),
            .init(id:"restore",title:"Restore cleanup batch",summary:"Restore one reviewed Trash batch with ownership and identity checks.",mutates:true,parameters:
                [P(name:"batch",kind:.string,required:true,summary:"Trash batch ID."),dryRun,yes,json],cli:["clean","restore"]),
            .init(id:"empty-trash",title:"Empty cleanup batch",summary:"Permanently remove only one reviewed Trash batch after confirmation.",mutates:true,parameters:
                [P(name:"batch",kind:.string,required:true,summary:"Trash batch ID."),dryRun,yes,json],cli:["clean","empty-trash"]),
            .init(id:"repair-worktrees",title:"Repair worktree registrations",summary:"Review or repair Git worktree registrations for one repository.",mutates:true,parameters:
                [P(name:"root",kind:.path,required:true,summary:"Repository path."),dryRun,yes,json],cli:["clean","repair-worktrees"])
        ])
    public static let all = [disk]
}

public enum ModulePreferences {
    public static let appDomain = "dev.thermo.app"
    public static func key(_ id: String) -> String { "module.enabled." + id }
    public static func isEnabled(_ manifest: ModuleManifest, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey:key(manifest.id)) == nil ? manifest.enabledByDefault : defaults.bool(forKey:key(manifest.id))
    }
}
