import AppKit
import Carbon
import ThermoL10n

/// Spotlight's ⌘Space lives in the per-user symbolic hotkey table (entry 64). Thermo turns that entry off so
/// its search can own ⌘Space, keeping the original entry so it can be put back exactly.
@MainActor struct SpotlightShortcut {
    var commandSpaceTaken: () -> Bool
    var release: () throws -> Void
    var restore: () throws -> Void
    var released: () -> Bool
    /// Another app holding ⌘Space. Raycast is named from its own setting; any other holder is only found by a
    /// trial registration, which is meaningful once Spotlight's entry is off (`probe`).
    var otherHolder: (_ probe: Bool) -> Holder?

    struct Holder: Equatable {
        var name: String
        var app: URL?
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let system = SpotlightShortcut(
        commandSpaceTaken: {
            guard let entry = entry() else { return true }
            let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int] ?? []
            let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int).map { $0 != 0 } ?? true)
            return enabled && parameters.count == 3 && parameters[1] == 49 && parameters[2] == 1 << 20
        },
        release: {
            let original = entry() ?? defaultEntry
            let backup = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
            var next = original; next["enabled"] = false
            // Kept before writing so a change that lands but fails to activate can still be put back.
            UserDefaults.standard.set(backup, forKey: backupKey)
            do { try write(next) } catch {
                if (entry()?["enabled"] as? Bool) != false { UserDefaults.standard.removeObject(forKey: backupKey) }
                throw error
            }
        },
        restore: {
            guard let data = UserDefaults.standard.data(forKey: backupKey) else { return }
            guard let original = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw Failure(message: tr("The saved Spotlight shortcut could not be read."))
            }
            try write(original)
            UserDefaults.standard.removeObject(forKey: backupKey)
        },
        released: { UserDefaults.standard.data(forKey: backupKey) != nil },
        otherHolder: { probe in
            if let raycast = NSRunningApplication.runningApplications(withBundleIdentifier: "com.raycast.macos").first,
               UserDefaults(suiteName: "com.raycast.macos")?.string(forKey: "raycastGlobalHotkey") == "Command-49" {
                return Holder(name: raycast.localizedName ?? "Raycast", app: raycast.bundleURL)
            }
            guard probe else { return nil }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(49, UInt32(cmdKey), EventHotKeyID(signature: 0x54485052, id: 1), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &ref)
            if let ref { UnregisterEventHotKey(ref) }
            return status == OSStatus(eventHotKeyExistsErr) ? Holder(name: tr("another app")) : nil
        })

    private static let backupKey = "dev.thermo.search.spotlightBackup"
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let tableKey = "AppleSymbolicHotKeys" as CFString
    private static let defaultEntry: [String: Any] = ["enabled": true, "value": ["parameters": [65535, 49, 1 << 20], "type": "standard"]]

    private static func table() -> [String: Any] {
        CFPreferencesCopyValue(tableKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }
    private static func entry() -> [String: Any]? { table()["64"] as? [String: Any] }
    private static func write(_ entry: [String: Any]) throws {
        var next = table(); next["64"] = entry
        CFPreferencesSetValue(tableKey, next as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw Failure(message: tr("macOS did not save the keyboard shortcut change."))
        }
        // Makes the running session reread the table so the change applies without logging out.
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        tool.arguments = ["-u"]
        tool.standardOutput = FileHandle.nullDevice; tool.standardError = FileHandle.nullDevice
        do { try tool.run(); tool.waitUntilExit() } catch {
            throw Failure(message: tr("The shortcut was saved but macOS may only apply it after you log out and back in."))
        }
    }
}
