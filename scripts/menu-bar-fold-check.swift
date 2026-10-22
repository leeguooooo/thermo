// Isolated public-API overflow experiment, not linked into ThermoApp.
import AppKit
import MenuBarCore

@MainActor final class FoldCheck: NSWindowController, NSWindowDelegate {
    private enum Reveal: String { case all, hidden, collapsed }
    private var reveal: Reveal = .all
    private var owned: [NSStatusItem] = []
    private var hiddenBoundary: NSStatusItem?
    private var alwaysBoundary: NSStatusItem?
    private var hiddenFillers: [NSStatusItem] = []
    private var alwaysFillers: [NSStatusItem] = []
    private var toggle: NSStatusItem?
    private var deadline: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var events: [[String: Any]] = []
    private let status = NSTextField(wrappingLabelWithString: "尚未收起。请检查菜单栏中的 TV、TH、TA。")
    private let root = Bundle.main.bundleURL.deletingLastPathComponent()
    // Diagnostic control: keep spacer hosts registered and visible instead of
    // repeatedly hiding them. This does not change any real application's item.
    private let persistentSpacers = Bundle.main.object(forInfoDictionaryKey: "ThermoMenuBarPersistentSpacers") as? Bool ?? false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "菜单栏公开接口折叠验收"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "TV 显示 · TH 隐藏 · TA 始终隐藏")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(title)
        let note = NSTextField(wrappingLabelWithString:
            "此原型只用公开 NSStatusItem。按住 ⌘ 可在菜单栏中拖动测试图标。收起可能将左侧其他图标也移入系统溢出区；45 秒后自动展开全部，关闭窗口会移除全部测试状态项。不写真实应用分组。")
        stack.addArrangedSubview(note)
        let controls = NSStackView(); controls.spacing = 12
        for (title, action) in [("收起两组", #selector(collapse)), ("展开隐藏组", #selector(showHidden)),
                                ("恢复全部图标", #selector(showAll))] {
            controls.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(controls)
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(status)
        let close = NSButton(title: "结束并移除测试图标", target: self, action: #selector(endCheck))
        close.keyEquivalent = "\u{1b}"; stack.addArrangedSubview(close)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24)
        ])
        // On a fresh macOS 27 namespace new items enter from right to left.
        // All three fixture icons belong to this one process; the experiment
        // therefore also checks per-item folding independent of a bundle API.
        // Compact diagnostic markers let an already crowded notched bar show
        // all three fixtures before any user rearrangement. TV doubles as the
        // recovery toggle, avoiding a sixth visible item in this experiment.
        toggle = item("TV", name: "visible", length: 14)
        toggle?.button?.target = self; toggle?.button?.action = #selector(toggleHidden)
        hiddenFillers = fillers("hidden")
        hiddenBoundary = item("│", name: "hidden.boundary", length: 6)
        _ = item("TH", name: "hidden.fixture", length: 14)
        alwaysFillers = fillers("always")
        alwaysBoundary = item("┃", name: "always.boundary", length: 6)
        _ = item("TA", name: "always.fixture", length: 14)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { if let self { self.apply(self.reveal) } } }
        apply(.all)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func show() { window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowWillClose(_ notification: Notification) { shutdown(); NSApp.terminate(nil) }
    @objc private func collapse() { apply(.collapsed) }
    @objc private func showHidden() { apply(.hidden) }
    @objc private func showAll() { apply(.all) }
    @objc private func toggleHidden() { apply(reveal == .collapsed ? .hidden : .collapsed) }
    @objc private func endCheck() { window?.performClose(nil) }

    private func item(_ title: String, name: String, length: CGFloat) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = "thermo.foldcheck.v27." + name
        item.button?.title = title
        item.button?.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        item.button?.setAccessibilityLabel("Thermo Fold Check " + name)
        owned.append(item)
        return item
    }
    private func fillers(_ group: String) -> [NSStatusItem] {
        (0..<MenuBarOverflowPlan.maximumFillers).map { index in
            let filler = item("", name: group + ".filler.\(index)", length: persistentSpacers ? 1 : 0)
            filler.button?.setAccessibilityElement(false)
            filler.isVisible = persistentSpacers
            return filler
        }
    }
    static func displays() -> [MenuBarOverflowPlan.Display] {
        NSScreen.screens.map { .init(width: Double($0.frame.width), statusWidth: $0.auxiliaryTopRightArea.map { Double($0.width) }) }
    }
    private func setBlock(_ boundary: NSStatusItem?, fillers: [NSStatusItem], folded: Bool, plan: MenuBarOverflowPlan?) {
        let folded = folded && plan != nil
        boundary?.button?.title = folded ? "" : (boundary === hiddenBoundary ? "│" : "┃")
        boundary?.length = folded ? CGFloat(plan!.itemLength) : 6
        for (index, filler) in fillers.enumerated() {
            let active = folded && index < plan!.fillerCount
            filler.length = active ? CGFloat(plan!.itemLength) : (persistentSpacers ? 1 : 0)
            filler.isVisible = active || persistentSpacers
        }
    }
    private func apply(_ requested: Reveal) {
        let displays = Self.displays()
        let plan = MenuBarOverflowPlan.native27(displays: displays)
        let unavailable = requested != .all && plan == nil
        reveal = unavailable ? .all : requested
        setBlock(hiddenBoundary, fillers: hiddenFillers, folded: reveal == .collapsed, plan: plan)
        setBlock(alwaysBoundary, fillers: alwaysFillers, folded: reveal != .all, plan: plan)
        toggle?.button?.toolTip = reveal == .collapsed ? "展开隐藏组" : "收起两组"
        if reveal == .all { deadline?.cancel(); deadline = nil }
        else if deadline == nil {
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                self?.apply(.all)
            }
        }
        status.stringValue = unavailable ? "当前屏幕组合超出原型的状态项数量预算，已展开全部。" :
            "已请求：\(reveal.rawValue)；单项宽度 \(plan?.itemLength ?? 0)，每组补充项 \(plan?.fillerCount ?? 0)。请检查实际菜单栏。"
        events.append(["time": Date().timeIntervalSince1970, "requested": requested.rawValue, "appliedGeometry": reveal.rawValue,
                       "itemLength": plan?.itemLength ?? 0, "fillerCount": plan?.fillerCount ?? 0,
                       "displays": displays.map { ["width": $0.width, "statusWidth": $0.statusWidth] }])
        writeReport()
    }
    func shutdown() {
        guard !owned.isEmpty else { return }
        apply(.all)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        for item in owned.reversed() { NSStatusBar.system.removeStatusItem(item) }
        owned.removeAll()
        events.append(["time": Date().timeIntervalSince1970, "removedAllTestItems": true])
        writeReport()
    }
    private func writeReport() {
        let report: [String: Any] = ["events": events, "pixelAcceptance": "not automatically asserted", "privateVisibilityAPIUsed": false,
                                   "persistentSpacers": persistentSpacers]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("fold-check-requests.json"), options: .atomic)
        }
    }
}

@MainActor final class FoldCheckDelegate: NSObject, NSApplicationDelegate {
    private var check: FoldCheck?
    func applicationDidFinishLaunching(_ notification: Notification) { check = FoldCheck(); check?.show() }
    func applicationWillTerminate(_ notification: Notification) { check?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
      Bundle.main.bundleIdentifier?.hasPrefix("dev.thermo.menubarqa.fold.") == true else { exit(2) }
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { FoldCheckDelegate() }
application.delegate = delegate
withExtendedLifetime(delegate) { application.run() }
