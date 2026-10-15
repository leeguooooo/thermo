import AgentCore
import Foundation

extension BackgroundStartupItems {
    public static func readWithoutApproval(majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                                          query: (() -> CommandRunner.Result)? = nil) -> BackgroundStartupReport {
        guard majorVersion < 14 else { return .requiresAuthorization }
        return parse((query ?? { CommandRunner.run("/usr/bin/sfltool", arguments: ["dumpbtm"], timeout: 5, outputLimit: 2_097_152) })())
    }

    /// Fixed read-only program. The watchdog may terminate only children of this
    /// authorization shell, never a process selected from the diagnostic output.
    static let authorizationScript = """
    set -u
    [ "$(/usr/bin/id -u)" = 0 ] || exit 77
    owner=$$
    stop_child() {
        parent=$(/bin/ps -p "$1" -o ppid= 2>/dev/null | /usr/bin/tr -d ' ')
        [ "$parent" = "$owner" ] && /bin/kill -TERM "$1" 2>/dev/null || :
    }
    /usr/bin/sfltool dumpbtm &
    query=$!
    (
        /bin/sleep 30
        parent=$(/bin/ps -p "$query" -o ppid= 2>/dev/null | /usr/bin/tr -d ' ')
        [ "$parent" = "$owner" ] && /bin/kill -TERM "$query" 2>/dev/null || :
        /bin/sleep 2
        parent=$(/bin/ps -p "$query" -o ppid= 2>/dev/null | /usr/bin/tr -d ' ')
        [ "$parent" = "$owner" ] && /bin/kill -KILL "$query" 2>/dev/null || :
    ) >/dev/null 2>&1 &
    timer=$!
    cleanup() {
        stop_child "$query"
        for child in $(/bin/ps -axo pid=,ppid= | /usr/bin/awk -v p="$timer" '$2 == p {print $1}'); do
            parent=$(/bin/ps -p "$child" -o ppid= 2>/dev/null | /usr/bin/tr -d ' ')
            [ "$parent" = "$timer" ] && /bin/kill -TERM "$child" 2>/dev/null || :
        done
        stop_child "$timer"
        wait "$timer" 2>/dev/null || :
    }
    trap cleanup EXIT HUP INT TERM
    set +e
    wait "$query"
    result=$?
    exit "$result"
    """

    public static func readAuthorized(authorize: ((String) -> CommandRunner.Result)? = nil) -> BackgroundStartupReport {
        let result = (authorize ?? { script in
            CommandRunner.run("/usr/bin/osascript", arguments: ["-e", "on run argv\ndo shell script (item 1 of argv) with administrator privileges\nend run", script], timeout: 180, outputLimit: 2_097_152)
        })(authorizationScript)
        return parse(result)
    }
}
