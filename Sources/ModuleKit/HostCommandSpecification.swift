import Foundation

/// Kernel CLI names are reserved while they are owned by the kernel. A migration removes its
/// kernel rows and adds the module declaration in the same change.
public enum HostCommandSpecification {
    public static let text = """
    capture|capture [status] [REQUEST_ID] [--control-directory DIR] [--timeout SEC] [--json]|app
    capture actions|capture actions [--control-directory DIR] [--timeout SEC] [--json]|app
    capture action|capture action ACTION_ID [--dry-run] [--control-directory DIR] [--timeout SEC] [--json]|app
    capture run|capture run (--code SOURCE | --file PATH) [--dry-run] [--control-directory DIR] [--timeout SEC] [--json]|app
    capture cancel|capture cancel REQUEST_ID [--dry-run] [--control-directory DIR] [--timeout SEC] [--json]|app
    search|search [query] [TEXT…] [--limit N] [--json]|local-search-index
    search status|search status [--json]|local-search-index
    search index|search index [--root DIR] [--json]|local-search-index
    search open|search open [--json]|app
    search settings|search settings [--json]|app
    search use-command-space|search use-command-space [--yes] [--dry-run] [--json]|app
    search give-back-command-space|search give-back-command-space [--yes] [--dry-run] [--json]|app
    temps|temps [--json|--csv]|cli
    fans|fans [--json|--csv]|cli
    power|power [--json|--csv]|cli
    battery|battery [--json|--csv]|cli
    charge|charge [status] [--probe] [--json]|helper8-or-read-only-probe
    charge status|charge status [--probe] [--json]|helper8-or-read-only-probe
    charge limit80|charge limit80 [--dry-run] [--json]|helper8-foreground-lease
    charge full|charge full [--dry-run] [--json]|helper8-foreground-lease
    charge recover|charge recover [--json]|helper8-orphan-recovery
    watch|watch [--count N] [--interval SEC] [--json|--csv]|cli
    list|list [--json|--csv]|cli
    get|get KEY… [--json|--csv]|cli
    bench|bench [--json|--csv]|cli
    fan status|fan status [--json|--csv]|helper
    fan set|fan set ID_or_all RPM_or_max [--dry-run] [--json]|helper
    fan curve|fan curve ID_or_all CURVE [--sensor cpu_or_gpu_or_max] [--dry-run] [--json]|helper
    fan auto|fan auto [ID_or_all] [--dry-run] [--json]|helper
    helper status|helper status [--json|--csv]|helper
    helper install|helper install [--dry-run] [--json]|helper
    helper uninstall|helper uninstall [--dry-run] [--json]|helper
    activity|activity [--json]|cli
    memory|memory [--json]|cli
    pulse|pulse [--json|--csv]|cli
    pulse why|pulse why [--for SEC] [--json]|cli
    pulse end|pulse end PID [--dry-run] [--yes] [--json]|cli
    pulse inspect|pulse inspect NAME_or_PID [--json]|cli
    pulse explain|pulse explain PID [--json]|cli
    pulse history|pulse history [--since 6h] [--json]|app-recorded-history
    pulse quit|pulse quit NAME_or_PID [--dry-run] [--yes] [--json]|cli
    pulse restart|pulse restart NAME_or_PID [--dry-run] [--yes] [--json]|cli
    pulse chrome|pulse chrome [--app BROWSER] [--watch SEC] [--measure] [--json|--csv]|browser
    pulse chrome close|pulse chrome close [URL] [--ids IDS] [--app BROWSER] [--title TITLE] [--dry-run] [--yes] [--json]|browser
    agents|agents [--all] [--json|--csv] [--root PROJECT] [--encoding ENCODING]|cli
    agents sessions|agents sessions [--json]|cli
    agents context|agents context [--encoding ENCODING] [--agent AGENT] [--root PROJECT] [--json]|cli
    agents health|agents health [--agent AGENT] [--since DATE] [--json]|read-only-local-diagnostics
    agents claude-local|agents claude-local [--json]|read-only-local-diagnostics
    agents claude-profiles|agents claude-profiles [--json]|read-only-local-diagnostics
    agents usage|agents usage [--encoding ENCODING] [--sort text|structured|time|errors|instructions] [--all] [--since DATE] [--agent AGENT] [--log-file FILE] [--tail] [--limit N] [--json]|cli
    agents compare|agents compare FILE [--json]|cli
    agents inspect-all|agents inspect-all [--protocol handshake|2026-07-28] [--agent AGENT] [--encoding ENCODING] [--timeout SEC] [--budget SEC] [--dry-run] [--json] [--root PROJECT]|mcp
    agents inspect|agents inspect NAME [--protocol handshake|2026-07-28] [--encoding ENCODING] [--agent AGENT] [--timeout SEC] [--json] [--root PROJECT]|mcp
    agents list|agents list [AREA] [--json|--csv] [--root PROJECT] [--encoding ENCODING]|cli
    agents show|agents show NAME [--area AREA] [--agent AGENT] [--json|--csv] [--root PROJECT] [--encoding ENCODING]|cli
    agents fix|agents fix [NAME] [--action N] [--area AREA] [--agent AGENT] [--all] [--dry-run] [--yes] [--json] [--root PROJECT] [--encoding ENCODING]|cli
    agents disable|agents disable NAME [--area AREA] [--agent AGENT] [--all] [--dry-run] [--yes] [--json] [--root PROJECT] [--encoding ENCODING]|cli
    agents updates|agents updates [--check] [--json] [--root PROJECT]|cli
    agents update|agents update [NAME] [--area AREA] [--agent AGENT] [--all] [--dry-run] [--yes] [--json] [--root PROJECT]|cli
    agents uninstall|agents uninstall NAME [--area AREA] [--agent AGENT] [--all] [--dry-run] [--yes] [--json] [--root PROJECT] [--encoding ENCODING]|cli
    agents run|agents run NAME --action N [--area AREA] [--agent AGENT] [--all] [--dry-run] [--yes] [--json] [--root PROJECT] [--encoding ENCODING]|cli
    apps|apps [--exact] [--json]|cli
    apps uninstall|apps uninstall NAME [--data-only] [--with-data] [--dry-run] [--yes] [--json]|cli
    apps leftovers|apps leftovers [remove ID…] [--dry-run] [--yes] [--json]|cli
    apps startup|apps startup [--authorize-background] [--json]|cli
    apps startup enable|apps startup enable LABEL_or_PATH [--dry-run] [--yes] [--json]|cli
    apps startup disable|apps startup disable LABEL_or_PATH [--dry-run] [--yes] [--json]|cli
    apps updates|apps updates [--refresh-catalog] [--json]|cli
    apps updates apply|apps updates apply TOKEN [--dry-run] [--yes] [--json]|cli
    apps updates sources|apps updates sources [--json]|cli
    apps updates check|apps updates check NAME [--dry-run] [--json]|cli
    apps updates install|apps updates install NAME [--dry-run] [--yes] [--json]|cli
    apps updates recovery|apps updates recovery [inspect_or_restore_or_trash-backup ID] [--dry-run] [--yes] [--json]|cli
    space|space [PATH] [--no-cache] [--all] [--json]|cli
    space large|space large [--older-than DAYS] [--json]|cli
    space dupes|space dupes [PATH…] [--json]|cli
    space dupes remove|space dupes remove PATH… --keep PATH [--dry-run] [--yes] [--json]|cli
    space trash|space trash PATH… [--dry-run] [--yes] [--json]|cli
    space archive|space archive PATH --to HOST:/PATH [--remove-local] [--inactive-development] [--dry-run] [--yes] [--json]|ssh
    tabs list|tabs list [--app BROWSER] [--json]|browser
    tabs groups|tabs groups [--app BROWSER] [--json]|browser
    tabs group|tabs group NAME --ids IDS [--by-site] [--dry-run] [--yes] [--json]|browser
    tabs archive|tabs archive [--ids IDS] [--group NAME] [--window ID|--all-windows] [--name NAME] [--dry-run] [--yes] [--json]|browser
    tabs saved|tabs saved [--json]|cli
    tabs show|tabs show UUID [--json]|cli
    tabs restore|tabs restore UUID [--window ID] [--dry-run] [--yes] [--json]|browser
    tabs forget|tabs forget UUID [--dry-run] [--yes] [--json]|cli
    tabs organize|tabs organize [--app BROWSER] [--ids IDS] [--window ID|--all-windows] [--dry-run] [--yes] [--json]|browser
    tabs organized|tabs organized [--json]|cli
    tabs undo-organize|tabs undo-organize UUID [--dry-run] [--yes] [--json]|browser
    tabs auto|tabs auto [on|off] [--dry-run] [--yes] [--json]|app-worker
    tabs rule|tabs rule [add DOMAIN NAME|remove UUID] [--color COLOR] [--dry-run] [--yes] [--json]|cli
    awake|awake [status|on|off] [--no-heat-guard] [--dry-run] [--yes] [--json]|helper
    keep-awake|keep-awake [status|start|stop] [--mode display_or_tasks_or_both] [--seconds SEC] [--duration manual] [--dry-run] [--yes] [--json]|app
    awdl|awdl [status|on|recover] [--probe] [--seconds SEC] [--dry-run] [--json]|helper-connection-lease
    settings|settings [KEY [VALUE]] [--dry-run] [--json|--csv]|cli
    history|history [list|show ID] [--limit N] [--json]|cli
    privacy profiles|privacy profiles [--json]|cli
    privacy location|privacy location [--dry-run] [--yes] [--json]|cli
    privacy webrtc|privacy webrtc [--dry-run] [--yes] [--json]|cli
    privacy cookies|privacy cookies [--dry-run] [--yes] [--json]|cli
    privacy restore-browser|privacy restore-browser [--dry-run] [--yes] [--json]|cli
    privacy environment|privacy environment [--dry-run] [--yes] [--json]|cli
    privacy dns|privacy dns [--dry-run] [--yes] [--json]|administrator
    privacy lookup|privacy lookup [--dry-run] [--json]|network
    privacy timezone|privacy timezone set --timezone ZONE_or_restore [--dry-run] [--yes] [--json]|administrator
    claude-reset list|claude-reset list [--json]|cli
    claude-reset run|claude-reset run TARGET… [--dry-run] [--yes] [--json]|cli
    claude-reset batches|claude-reset batches [--json]|cli
    claude-reset restore|claude-reset restore UUID [--dry-run] [--yes] [--json]|cli
    screen|screen [status|start|stop|duration|shortcut|clear-shortcut] [--duration oneMinute_or_twoMinutes_or_fiveMinutes_or_manual] [--key-code N --modifiers N --key-label LABEL] [--dry-run] [--yes] [--json]|app
    app-control|app-control status [--json]|app
    app-control login|app-control login [status|on|off] [--dry-run] [--yes] [--json]|app
    app-control updates|app-control updates [status|check|on|off] [--dry-run] [--yes] [--json]|app
    app-control awdl|app-control awdl [status|on|off] [--seconds SEC] [--dry-run] [--yes] [--json]|app-helper-lease
    app-control helper|app-control helper [status|install|uninstall] [--dry-run] [--yes] [--json]|app
    permissions|permissions [status|notifications|accessibility|login] [--dry-run] [--yes] [--json]|app
    integration|integration [status|link|claude|codex] [--dry-run] [--yes] [--json]|app
    mcp|mcp|stdio-mcp
    capabilities|capabilities [--json]|cli
    """
    public static let aliases = ["temp":"temps","t":"temps","f":"fans","p":"power","b":"battery","w":"watch","ls":"list","agent":"agents","doctor":"agents","app":"apps","config":"settings","status":"pulse"]
    public static var roots: Set<String> {
        Set(text.split(separator:"\n").compactMap { $0.split(separator:"|").first?.split(separator:" ").first.map(String.init) }).union(aliases.keys).union(["help"])
    }
}
