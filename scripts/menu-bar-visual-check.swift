// Isolated, operator-driven macOS 27 visibility acceptance. Compiled by
// verify-menu-bar.py; never linked into the shipped application.
import AppKit
import CMenuBar
import MenuBarCore

@MainActor private final class VisualCheckSession: MenuBarVisibilitySession {
    private let handle: TMMenuBarSession
    init(_ configuration: MenuBarConfiguration) throws {
        handle = try TMMenuBarSession.make(allowedBundles: configuration.allowedBundles)
    }
    func activate(completion: @escaping @MainActor (String?) -> Void) {
        handle.activate { error in
            let message = error?.localizedDescription
            Task { @MainActor in completion(message) }
        }
    }
    func invalidate() -> String? {
        do { try handle.invalidate(); return nil } catch { return error.localizedDescription }
    }
}

@MainActor final class MenuBarVisualCheck: NSWindowController, NSWindowDelegate {
    private struct Fixture {
        let bundle: String
        let label: String
        let section: MenuBarSection
    }
    private let status = NSTextField(wrappingLabelWithString: "尚未开始。测试仅使用同目录的三个临时图标程序。")
    private var fixtures: [Fixture] = []
    private var scopeStarted = false
    private var deadline: Task<Void, Never>?
    private var phase = "idle"
    private var trace: [[String: Any]] = []
    private let own = Bundle.main.bundleIdentifier ?? ""
    private let root = Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
    private lazy var controller: MenuBarSessionController = {
        let controller = MenuBarSessionController { try VisualCheckSession($0) }
        controller.didChange = { [weak self] state in
            guard let self else { return }
            let description: String
            switch state {
            case .visible: description = "已请求恢复全部图标"
            case .applying: description = "正在请求更改显示"
            case .applied: description = "macOS 已接受请求；请检查实际图标"
            case let .failed(error): description = "请求失败：" + error
            }
            self.status.stringValue = self.phase + " · " + description
            self.record(description)
        }
        return controller
    }()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "菜单栏真实显示验收"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "MBV 显示 · MBH 隐藏 · MBA 始终隐藏")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "为避开系统溢出区，会话会暂时隐藏其他第三方菜单栏图标。应用继续运行，持久配置不变。45 秒后自动请求恢复，也可随时按 Escape。系统图标可能受私有接口影响。")
        explanation.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(title); stack.addArrangedSubview(explanation)
        let first = NSStackView(); first.spacing = 8
        for (text, selector) in [("1 显示三个测试图标", #selector(beginVisualCheck)), ("2 收起分组", #selector(collapse)),
                                 ("3 展开隐藏组", #selector(showHidden)), ("4 展开全部测试组", #selector(showAll))] {
            let button = NSButton(title: text, target: self, action: selector)
            first.addArrangedSubview(button)
        }
        stack.addArrangedSubview(first)
        let restore = NSButton(title: "5 结束测试并恢复所有图标", target: self, action: #selector(endTest))
        restore.keyEquivalent = "\u{1b}"
        stack.addArrangedSubview(restore)
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(status)
        let note = NSTextField(wrappingLabelWithString:
            "回调、AX 节点或窗口坐标都不能代替图标画面。每一步均需观察菜单栏；本程序只记录请求，不自动宣称验收通过。")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() { window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowWillClose(_ notification: Notification) { restore() }

    @objc private func beginVisualCheck() { apply(.all, phase: "三个测试图标全部显示") }
    @objc private func collapse() { apply(.collapsed, phase: "仅 MBV 应显示") }
    @objc private func showHidden() { apply(.hidden, phase: "MBV 与 MBH 应显示") }
    @objc private func showAll() { apply(.all, phase: "MBV、MBH、MBA 应显示") }
    @objc private func endTest() { restore() }

    func restore() {
        deadline?.cancel(); deadline = nil
        scopeStarted = false; phase = "结束隔离会话"
        controller.restore()
    }

    private func apply(_ reveal: MenuBarReveal, phase: String) {
        do {
            guard own.hasPrefix("dev.thermo.menubarqa."), TMMenuBarSession.isAvailable() else {
                throw NSError(domain: "MenuBarVisualCheck", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "不是隔离验收 App，或系统接口不可用。"])
            }
            fixtures = try loadFixtures()
            if !scopeStarted {
                scopeStarted = true
                deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                    self?.restore()
                }
            }
            self.phase = phase
            let systemBundles = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter { $0.hasPrefix("com.apple.") }
            // Preserve the installed Thermo icon as a recovery/control item.
            let population = Set(systemBundles + fixtures.map(\.bundle) + [own, "dev.thermo.app"])
            var sections = MenuBarSections()
            for fixture in fixtures { sections.assign(fixture.bundle, to: fixture.section) }
            // Keep a scoped background mask even for .all, so the three test
            // icons can be observed outside overflow. End Test removes it.
            let config = sections.configuration(running: population, ownBundle: own, reveal: reveal)
                ?? MenuBarConfiguration(allowedBundles: population.sorted())
            controller.apply(config)
        } catch {
            restore()
            status.stringValue = error.localizedDescription
            record("拒绝开始：" + error.localizedDescription)
        }
    }

    private func loadFixtures() throws -> [Fixture] {
        try [("Thermo Menu Bar Visible Fixture.app", "MBV", MenuBarSection.visible),
             ("Thermo Menu Bar Fixture.app", "MBH", MenuBarSection.hidden),
             ("Thermo Menu Bar Always Fixture.app", "MBA", MenuBarSection.alwaysHidden)].map { name, label, section in
            let url = root.appendingPathComponent(name).resolvingSymlinksInPath()
            guard url.deletingLastPathComponent() == root, let bundle = Bundle(url: url)?.bundleIdentifier,
                  bundle.hasPrefix("org.example.mbfx."),
                  NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains(where: {
                      !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath() == url
                  }) else {
                throw NSError(domain: "MenuBarVisualCheck", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "请先启动同目录的 " + name])
            }
            return Fixture(bundle: bundle, label: label, section: section)
        }
    }

    private func record(_ result: String) {
        trace.append(["time": Date().timeIntervalSince1970, "phase": phase, "result": result])
        let report: [String: Any] = ["events": trace, "pixelAcceptance": "not automatically asserted",
                                   "fixtureLabels": fixtures.map(\.label), "watchdogSeconds": 45,
                                   "persistentAssignmentsChanged": false]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("visual-check-requests.json"), options: .atomic)
        }
    }
}
