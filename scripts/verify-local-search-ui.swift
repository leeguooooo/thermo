// Production search controller in an owned, private-index QA application. No helper or app-control server.
@testable import ThermoApp
import AppKit
import Carbon
import SearchCore
import ThermoL10n

@MainActor final class SearchReviewDelegate: NSObject, NSApplicationDelegate {
    var controls: NSWindow?
    private var clipboardBackup: [[NSPasteboard.PasteboardType: Data]]?
    private var copiedPath: String?
    @objc func captureClipboard() {
        guard let item = LocalSearchModel.shared.selected,
              let root = Bundle.main.object(forInfoDictionaryKey: "ThermoSearchFixtureRoot") as? String,
              item.path.hasPrefix(root + "/files/") else { return }
        clipboardBackup = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        copiedPath = item.path
        print("QA_CLIPBOARD_CAPTURED"); fflush(stdout)
    }
    @objc func verifyClipboard() {
        guard let clipboardBackup, let copiedPath else { return }
        let valid = NSPasteboard.general.string(forType: .string) == copiedPath
        if valid {
            let items = clipboardBackup.map { values in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            }
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(items)
        }
        self.clipboardBackup = nil; self.copiedPath = nil
        print("QA_CLIPBOARD_COPY_RESTORED \(valid)"); fflush(stdout)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        controls?.makeKeyAndOrderFront(nil)
        showSearch()
        print("QA_LAUNCHED \(NSApp.windows.count) \(LocalSearchPanel.shared.window?.isVisible == true)"); fflush(stdout)
    }
    @objc func showSearch() { LocalSearchPanel.shared.show() }
    @objc func showSettings() { LocalSearchPanel.shared.show(settings: true) }
    @objc func conflictProbe() {
        let shortcut = LocalSearchShortcut.shared
        let previous = shortcut.binding
        let candidate = CleanScreenKeyBinding(keyCode: 79, modifiers: UInt32(cmdKey | optionKey | controlKey), keyLabel: "F18")
        var reference: EventHotKeyRef?
        let reserved = RegisterEventHotKey(candidate.keyCode, candidate.modifiers, .init(signature: 0x5153484b, id: 1), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
        guard reserved == noErr, let reference else { print("QA_CONFLICT_SETUP_FAILED \(reserved)"); fflush(stdout); return }
        shortcut.apply(candidate, persist: false)
        print("QA_CONFLICT_PRESERVED \(shortcut.binding == previous && shortcut.issue != nil)")
        print("QA_CONFLICT_RELEASE \(UnregisterEventHotKey(reference))"); fflush(stdout)
    }
    @objc func compositionProbe() {
        func input(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == tr("Search apps and files") { return field }
            return view.subviews.lazy.compactMap(input).first
        }
        guard let window = LocalSearchPanel.shared.window, let content = window.contentView, let field = input(content) else { print("QA_IME_NO_FIELD"); return }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { print("QA_IME_NO_EDITOR"); return }
        editor.setMarkedText("拼音输入", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let handled = field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        print("QA_IME_COMPOSITION_DEFERRED \(editor.hasMarkedText() && handled == false)"); fflush(stdout)
        editor.unmarkText()
        LocalSearchModel.shared.query = ""
        LocalSearchPanel.shared.show()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSearch(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        LocalSearchShortcut.shared.shutdown(); LocalSearchModel.shared.stop(); print("QA_EXIT"); fflush(stdout)
    }
}

@main struct LocalSearchUIAcceptance {
    @MainActor static func main() throws {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "ThermoSearchFixtureRoot") as? String,
              Bundle.main.bundleIdentifier?.hasPrefix("dev.thermo.searchqa.") == true else { exit(2) }
        let root = URL(fileURLWithPath: SearchPaths.canonical(path))
        guard root.lastPathComponent.hasPrefix("thermo-search-ui-"), FileManager.default.fileExists(atPath: root.appendingPathComponent(".thermo-search-ui-fixture").path) else { exit(3) }
        setenv("THERMO_SEARCH_DATA_DIR", root.appendingPathComponent("index").path, 1)
        _ = freopen(root.appendingPathComponent("trace.log").path, "a", stdout)
        L10n.apply(preference: Bundle.main.object(forInfoDictionaryKey: "ThermoSearchFixtureLanguage") as? String ?? "zh-Hans")
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = SearchReviewDelegate(); app.delegate = delegate
        let menu = NSMenu(), top = NSMenuItem(), submenu = NSMenu()
        for (title, action, key) in [("Open search", #selector(SearchReviewDelegate.showSearch), "f"),
                                      ("Search settings", #selector(SearchReviewDelegate.showSettings), ","),
                                      ("Probe shortcut conflict", #selector(SearchReviewDelegate.conflictProbe), ""),
                                      ("Probe IME composition", #selector(SearchReviewDelegate.compositionProbe), ""),
                                      ("Capture clipboard for copy test", #selector(SearchReviewDelegate.captureClipboard), ""),
                                      ("Verify copy and restore clipboard", #selector(SearchReviewDelegate.verifyClipboard), "")] {
            let item = submenu.addItem(withTitle: title, action: action, keyEquivalent: key); item.target = delegate
        }
        submenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        top.submenu = submenu; menu.addItem(top); app.mainMenu = menu
        let controls = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 360, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        controls.title = "Thermo Search QA controls"
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10
        for (title, action) in [("Open search", #selector(SearchReviewDelegate.showSearch)), ("Search settings", #selector(SearchReviewDelegate.showSettings)), ("Probe shortcut conflict", #selector(SearchReviewDelegate.conflictProbe)), ("Probe IME composition", #selector(SearchReviewDelegate.compositionProbe))] {
            stack.addArrangedSubview(NSButton(title: title, target: delegate, action: action))
        }
        controls.contentView = stack; delegate.controls = controls
        LocalSearchShortcut.shared.activate()
        print("QA_PRIVATE_INDEX \(SearchStore.defaultDirectory.path.hasPrefix(root.path + "/"))")
        print("QA_SHORTCUT \(LocalSearchShortcut.shared.binding?.label ?? "unavailable")"); fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 900) { app.terminate(nil) }
        withExtendedLifetime(delegate) { app.run() }
    }
}
