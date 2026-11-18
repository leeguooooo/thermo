import Foundation
import ThermoL10n

/// Android emulators (`~/.android/avd/<name>.avd` plus `<name>.ini`). Each holds a multi-GB disk image, and
/// one made for a single test is easy to forget. One `review` item per emulator nobody started lately.
enum AndroidEmulators {
    static func home(_ ctx: ScanContext) -> String {
        if let custom = ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"], !custom.isEmpty, ctx.home == NSHomeDirectory() {
            return FS.expand(custom, home: ctx.home)
        }
        return ctx.path("~/.android/avd")
    }

    static func scan(_ ctx: ScanContext, minimumBytes: Int64 = 500_000_000) -> [CleanItem] {
        let root = home(ctx)
        guard FS.isDirectory(root) else { return [] }
        let idleDays = min(ctx.options.olderThanDays, Simulators.simulatorIdleDays)
        let idle = ctx.now.addingTimeInterval(-Double(idleDays) * 86400)
        var out: [CleanItem] = []
        for dir in FS.children(root) where dir.hasSuffix(".avd") && FS.isDirectory(dir) {
            guard ScanCancellation.current?.isCancelled != true else { return out }
            let name = String((dir as NSString).lastPathComponent.dropLast(4))
            let s = FS.size(dir, trackNewest: true)
            guard s.bytes >= minimumBytes else { continue }
            let used = [s.newest, FS.mtime(dir)].compactMap { $0 }.max()
            guard (used ?? .distantPast) < idle else { continue }
            let ini = root + "/" + name + ".ini"
            // While it runs the emulator holds hardware-qemu.ini.lock, userdata-qemu.img.lock and so on;
            // multiinstance.lock stays behind after it quits.
            let running = FS.children(dir).contains { $0.hasSuffix(".lock") && !$0.hasSuffix("/multiinstance.lock") }
            out.append(CleanItem(
                id: "android-avd/\(name)", category: .devCaches,
                title: tr("Idle Android emulator · %1$@", name),
                detail: ctx.tilde(dir) + " · " + (used == nil ? tr("Last emulator use is unavailable")
                    : tr("last used %1$@ days ago", String(Int(ctx.now.timeIntervalSince(used!) / 86400)))),
                safety: .review, bytes: s.bytes, files: s.files, lastUsed: used,
                paths: [dir] + (FS.exists(ini) ? [ini] : []),
                note: tr("deletes the emulator and the apps in it; create it again in Android Studio when needed"),
                blocked: running ? tr("the emulator is running") : nil))
        }
        return out
    }
}
