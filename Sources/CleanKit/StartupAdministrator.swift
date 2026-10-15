import AgentCore
import Foundation

extension StartupItems {
    public typealias AdministratorRunner = (String) -> CommandRunner.Result
    static let administratorReceipt = "THERMO_STARTUP_STATE_VERIFIED"

    static func authorizeStartup(_ script: String) -> CommandRunner.Result {
        // Pass the fixed shell program as data, never interpolate it into AppleScript source.
        CommandRunner.run("/usr/bin/osascript", arguments: ["-e", "on run argv\ndo shell script (item 1 of argv) with administrator privileges\nend run", script],
                          timeout: 180, outputLimit: 16_384)
    }

    static func administratorScript(_ enabled: Bool, item: StartupItem, defaultEnabled: Bool, root: String = "/Library/LaunchDaemons") throws -> String {
        guard item.effectiveScope == .systemDaemon, item.blocked == nil, validLabel(item.label),
              (item.path as NSString).deletingLastPathComponent == root,
              item.path.hasSuffix(".plist"), let fingerprint = item.fingerprint, let reviewed = item.enabled else {
            throw Failure(message: "Startup item changed or could not be verified; refresh and review it again")
        }
        let parts = fingerprint.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].allSatisfy({ $0.isNumber || $0 == "-" }), !parts[0].isEmpty,
              !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber), parts[2].count == 64,
              parts[2].allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw Failure(message: "Startup item changed or could not be verified; refresh and review it again")
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        let state = enabled ? "enabled" : "disabled"
        let parser = #"""
        BEGIN { opened=0; closed=0; bad=0; value=fallback }
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        /^[ \t]*$/ { next }
        {
            line=trim($0)
            if (!opened) { if (line=="disabled services = {") { opened=1; next }; bad=1; next }
            if (line=="}") { if (closed) bad=1; closed=1; next }
            if (closed || split(line, fields, "=>")!=2) { bad=1; next }
            key=trim(fields[1]); state=trim(fields[2])
            if (key !~ /^"[^"]+"$/ || state !~ /^(enabled|disabled|true|false)$/ || seen[key]++) { bad=1; next }
            if (key==label) value=(state=="enabled" || state=="false") ? "enabled" : "disabled"
        }
        END { if (!opened || !closed || bad) exit 2; print value }
        """#
        // All commands and roots are fixed. The label is restricted to ASCII launchd identifiers.
        // Root rechecks run after the authorization dialog; no plist is rewritten or job booted out.
        return """
        set -eu
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        [ "$(/usr/bin/id -u)" = 0 ]
        path=\(quote(item.path))
        check_file() {
            [ ! -L /Library ]
            [ ! -L \(quote(root)) ]
            [ ! -L "$path" ]
            [ -f "$path" ]
            [ "$(/usr/bin/stat -f '%u' "$path")" = 0 ]
            mode=$(/usr/bin/stat -f '%p' "$path")
            [ "$((0$mode & 022))" = 0 ]
            [ "$(/usr/bin/stat -f '%d:%i' "$path")" = \(quote(String(parts[0]) + ":" + String(parts[1]))) ]
            [ "$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/shasum -a 256 -- "$path" | /usr/bin/awk '{print $1}')" = \(quote(String(parts[2]))) ]
        }
        read_state() {
            /bin/launchctl print-disabled system | /usr/bin/awk -v label=\(quote("\"" + item.label + "\"")) -v fallback=\(quote(defaultEnabled ? "enabled" : "disabled")) \(quote(parser))
        }
        check_file
        [ "$(read_state)" = \(quote(reviewed ? "enabled" : "disabled")) ]
        check_file
        /bin/launchctl \(enabled ? "enable" : "disable") \(quote("system/" + item.label))
        [ "$(read_state)" = \(quote(state)) ]
        check_file
        /usr/bin/printf '%s\\n' \(quote(administratorReceipt))
        """
    }
}
