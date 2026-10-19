import AgentCore
import Foundation
import ThermoL10n

/// How the shared operation history reads, for both the CLI and the app.
extension OperationRecord {
    public var title: String {
        switch (feature, action) {
        case ("clean", "trash"): return tr("Cleanup moved files to the Trash")
        case ("clean", "delete"): return tr("Cleanup deleted files")
        case ("clean", "emptyTrash"): return tr("Emptied a Trash batch")
        case ("clean", "whitelistAdd"): return tr("Added to the cleanup whitelist")
        case ("clean", "whitelistRemove"): return tr("Removed from the cleanup whitelist")
        case ("apps", "uninstall"): return tr("Uninstalled an app")
        case ("apps", "removeData"): return tr("Removed associated data; kept the app")
        case ("apps", "remove"): return tr("Removed app leftovers")
        case ("apps", "enable"): return tr("Enabled a startup item")
        case ("apps", "disable"): return tr("Disabled a startup item")
        case ("apps", "update"): return tr("Updated an app")
        case ("apps", "nativeUpdate"): return tr("Native app update")
        case ("apps", "nativeRestore"): return tr("Native app recovery")
        case ("apps", "nativeBackupTrash"): return tr("Moved an update backup to the Trash")
        case ("apps", "nativeUpdatePreparation"): return tr("Native update preparation")
        case ("apps", "nativeUpdateCleanup"): return tr("Native update file cleanup")
        case ("space", "trash"): return tr("Moved hand-picked files to the Trash")
        case ("agents", "fix"): return tr("Fixed an agent problem")
        case ("agents", "uninstall"): return tr("Removed an agent item")
        case ("agents", "disable"): return tr("Disabled an agent item")
        case ("claudeReset", "reset"): return tr("Reset Claude data")
        case ("claudeReset", "restore"): return tr("Restored Claude data")
        case ("privacy", "blockLocation"): return tr("Block default browser location")
        case ("privacy", "restrictWebRTC"): return tr("Restrict WebRTC")
        case ("privacy", "clearMailCookies"): return tr("Clear mail.com cookies")
        case ("privacy", "restoreBrowser"): return tr("Restore last browser change")
        case ("privacy", "clearClaudeEnvironment"): return tr("Remove Claude launchd variables")
        case ("privacy", "flushDNS"): return tr("Flush DNS cache")
        case ("privacy", "setTimezone"): return tr("Changed the system timezone")
        case ("privacy", "restoreTimezone"): return tr("Restore previous timezone")
        case ("tabs", "archive"): return tr("Saved and closed tabs")
        case ("tabs", "restore"): return tr("Reopened saved tabs")
        case ("tabs", "organize"): return tr("Grouped tabs")
        case ("tabs", "undoOrganize"): return tr("Undid tab grouping")
        case ("worktrees", "repair"): return tr("Repaired worktree registrations")
        case ("archive", "archive"): return tr("Archived to another machine")
        case ("archive", "archiveAndRemove"): return tr("Archived to another machine and removed the local copy")
        case ("pulse", "quit"): return tr("Stopped a program")
        case ("pulse", "restart"): return tr("Restarted an app")
        case ("history", "restore"): return tr("Put files back from the Trash")
        case ("power", "lidAwakeOn"): return tr("Turned on staying awake with the lid closed")
        case ("power", "lidAwakeOff"): return tr("Turned off staying awake with the lid closed")
        case ("power", "lidAwakeAutoOff"): return tr("Staying awake with the lid closed turned itself off")
        case ("power", "idleAwakeStart"): return tr("Started keeping the Mac awake")
        case ("power", "idleAwakeStop"), ("power", "idleAwakeEnd"): return tr("Ended keeping the Mac awake")
        case ("power", "idleAwakePause"): return tr("Paused keeping the Mac awake")
        case ("power", "idleAwakeResume"): return tr("Resumed keeping the Mac awake")
        case ("network", "awdlBegin"): return tr("Started an AWDL low-latency session")
        case ("network", "awdlRestore"): return tr("AWDL session ended")
        default: return feature + " · " + action
        }
    }

    public var outcomeText: String {
        switch outcome {
        case "succeeded": return tr("done")
        case "partial": return tr("partly done")
        default: return tr("failed")
        }
    }

    /// Size, honest about what was not measured.
    public var sizeText: String? {
        // Nothing measured: agent fixes, privacy settings, tabs and quits have no size to speak of.
        guard let bytes else { return nil }
        if bytes == 0, bytesIncomplete == true { return tr("Size unavailable") }
        return (bytesIncomplete == true ? tr("at least %1$@", ByteFormat.string(bytes)) : ByteFormat.string(bytes))
    }

    /// Whether `thermo clean restore` / the history page can undo this entry itself.
    public var restorableHere: Bool { undo?.kind == "trashBatch" }

    /// Where and how this change is undone, in words.
    public var undoText: String? {
        guard let undo else {
            switch (feature, action) {
            case ("network", "awdlBegin"): return tr("Stop in Network low latency. A session started in Terminal ends with Ctrl-C.")
            case ("apps", "update"): return tr("Check the installed version in Software → Updates. Thermo cannot automatically roll updates back.")
            case ("privacy", "clearClaudeEnvironment"): return tr("Cannot be undone: the values were never read or saved.")
            case ("clean", "delete"), ("clean", "emptyTrash"): return tr("Deleted for good; nothing to restore.")
            default: return nil
            }
        }
        switch undo.kind {
        case "nativeUpdate": return tr("Inspect and restore in Software → Updates → Other apps → Recovery.")
        case "nativePreparation": return tr("Inspect preserved files in Software → Updates → Other apps → Recovery.")
        case "startup": return tr("Undo in Software → Startup items, or with thermo apps startup %1$@ %2$@.", action == "enable" ? "disable" : "enable", undo.ref)
        case "trashBatch": return tr("Restorable from this history (thermo clean restore %1$@).", undo.ref)
        case "trash": return tr("Put back from the Trash in Finder.")
        case "claudeReset": return tr("Restore from Claude cleanup → Recovery records.")
        case "browserBackup": return action == "clearMailCookies"
            ? tr("Cookie backups are kept privately; restoring them is manual with browsers closed.")
            : tr("Undo with Privacy & network → Restore last browser change.")
        case "timezoneBackup": return tr("Undo with Privacy & network → Restore previous timezone.")
        case "tabArchive": return tr("Reopen from Tab organizer → Saved (thermo tabs restore %1$@).", undo.ref)
        case "tabBatch": return tr("Undo with thermo tabs undo-organize %1$@.", undo.ref)
        case "agentBackup": return tr("Copies of the changed files are in %1$@.", FS.tilde(undo.ref))
        case "worktreeBackup": return tr("Registration backups are in %1$@.", FS.tilde(undo.ref))
        case "archiveManifest": return tr("Restore instructions are in %1$@.", undo.ref)
        default: return nil
        }
    }
}
